# Higress Wasm-Go 插件开发指南

> 基于 ai-load-balancer 插件实战经验总结，帮你从 0 到 1 跑通一个自定义插件。

## 整体流程

```
1. 写代码 → 2. 编译 wasm → 3. 放入 data 目录 → 4. 写 YAML 配置 → 5. 重启生效 → 6. 验证
```

---

## Step 1: 创建插件项目

在 `plugins/wasm-go/` 下新建你的插件目录：

```bash
mkdir -p plugins/wasm-go/my-plugin
cd plugins/wasm-go/my-plugin
```

### 1.1 初始化 go.mod

```go
// go.mod
module my-plugin

go 1.19

require (
    github.com/alibaba/higress/plugins/wasm-go v1.3.5
    github.com/higress-group/proxy-wasm-go-sdk v0.0.0-20240226064518-b3dc4646a35a
    github.com/tidwall/gjson v1.14.4
)
```

> 关键依赖说明：
> - `wasm-go v1.3.5` — Higress 官方 SDK，提供 `wrapper.SetCtx`、Redis 客户端等
> - `proxy-wasm-go-sdk` — 底层 proxy-wasm ABI，提供 `proxywasm.ReplaceHttpRequestHeader` 等
> - `gjson` — 解析插件 JSON 配置

如果需要访问 Redis，额外加：

```
github.com/tidwall/resp v0.1.1
```

### 1.2 编写 main.go

插件的核心结构就三部分：**配置结构体 + 解析配置 + 处理请求**。

```go
package main

import (
    "github.com/alibaba/higress/plugins/wasm-go/pkg/wrapper"
    "github.com/higress-group/proxy-wasm-go-sdk/proxywasm"
    "github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
    "github.com/tidwall/gjson"
)

func main() {
    wrapper.SetCtx(
        "my-plugin",                                    // 插件名，日志前缀
        wrapper.ParseConfigBy(parseConfig),             // 配置解析函数
        wrapper.ProcessRequestHeadersBy(onHttpRequestHeaders), // 请求头处理
    )
}

// ========== 1. 定义配置结构体 ==========
type MyPluginConfig struct {
    SomeField string
}

// ========== 2. 解析配置（启动时调用） ==========
func parseConfig(json gjson.Result, config *MyPluginConfig, log wrapper.Log) error {
    config.SomeField = json.Get("some_field").String()
    log.Infof("my-plugin: config parsed, some_field=%s", config.SomeField)
    return nil
}

// ========== 3. 处理请求（每个请求调用） ==========
func onHttpRequestHeaders(ctx wrapper.HttpContext, config MyPluginConfig, log wrapper.Log) types.Action {
    log.Infof("my-plugin: request received")

    // 读取请求头
    value, _ := proxywasm.GetHttpRequestHeader("x-user-id")
    log.Infof("my-plugin: user=%s", value)

    // 修改请求头
    proxywasm.ReplaceHttpRequestHeader("x-custom-header", config.SomeField)

    return types.ActionContinue // 继续处理请求
}
```

### 可用的处理函数钩子

| 钩子 | 说明 |
|------|------|
| `wrapper.ProcessRequestHeadersBy(fn)` | 处理请求头 |
| `wrapper.ProcessRequestBodyBy(fn)` | 处理请求体 |
| `wrapper.ProcessResponseHeadersBy(fn)` | 处理响应头 |
| `wrapper.ProcessResponseBodyBy(fn)` | 处理响应体 |

### 异步调用（Redis / HTTP）的关键模式

如果你的插件需要调用外部服务（如 Redis），必须用 **Pause + Callback + Resume** 模式：

```go
func onHttpRequestHeaders(ctx wrapper.HttpContext, config MyPluginConfig, log wrapper.Log) types.Action {
    // 发起异步调用
    err := config.RedisClient.Get("some_key", func(status int, response resp.Value) {
        // 回调中处理结果
        log.Infof("got value: %s", response.String())

        // 【重要】处理完必须 Resume，否则请求会一直挂着
        proxywasm.ResumeHttpRequest()
    })

    if err != nil {
        // 调用失败，直接放行
        return types.ActionContinue
    }

    // 【重要】返回 Pause，等待回调
    return types.ActionPause
}
```

---

## Step 2: 编译 wasm

### 2.1 创建 build.sh

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PLUGIN_NAME="my-plugin"

echo "Building Go Wasm plugin..."
docker run --rm -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  /bin/bash -c "go mod tidy && tinygo build -o ${PLUGIN_NAME}.wasm \
    -scheduler=none -target=wasi -gc=custom \
    -tags='custommalloc nottinygc_finalizer proxy_wasm_version_0_2_100' main.go"

echo "Copying to data/wasmplugins/..."
cp ${PLUGIN_NAME}.wasm ../../../data/wasmplugins/${PLUGIN_NAME}.wasm

echo "Done: ${PLUGIN_NAME}.wasm"
```

### 2.2 执行编译

```bash
chmod +x build.sh
./build.sh
```

> 首次构建会拉取 ~1GB 的 builder 镜像，后续编译很快。

---

## Step 3: 注册外部服务（如需 Redis 等）

如果插件需要访问 Redis 或其他外部服务，必须在 McpBridge 中注册。

在 Higress 控制台 → **服务来源** 中添加，或直接编辑容器内配置：

```bash
docker exec higress-ai-gateway vi /data/mcpbridges/default.yaml
```

在 `spec.registries` 下添加：

```yaml
- domain: host.docker.internal   # Docker 容器访问宿主机
  name: redis-svc                # 插件配置中引用的 service_name
  port: 6379
  type: dns
```

> `host.docker.internal` 是 Docker 容器访问宿主机的固定域名，用于连接宿主机上的 Redis。

---

## Step 4: 写插件配置（最关键的一步）

**直接在容器内创建 WasmPlugin YAML：**

```bash
docker exec higress-ai-gateway bash -c 'cat > /data/wasmplugins/my-plugin.yaml << '\''EOF'\''
apiVersion: extensions.higress.io/v1alpha1
kind: WasmPlugin
metadata:
  name: my-plugin
  namespace: higress-system
  labels:
    higress.io/resource-definer: higress
    higress.io/wasm-plugin-built-in: "true"
    higress.io/wasm-plugin-name: my-plugin
    higress.io/wasm-plugin-version: 1.0.0
spec:
  priority: 200
  phase: AUTHN
  failStrategy: FAIL_OPEN
  url: file:///data/wasmplugins/my-plugin.wasm
  defaultConfig:
    some_field: "hello"
  defaultConfigDisable: false
EOF'
```

### 配置字段说明

| 字段 | 说明 |
|------|------|
| `priority` | 数字越大越先执行 |
| `phase` | `AUTHN`（认证阶段）/ `AUTHZ`（鉴权）/ `STATS`（统计） |
| `failStrategy` | `FAIL_OPEN`（插件出错则放行）/ `FAIL_CLOSE`（出错则拒绝） |
| `url` | `file:///data/wasmplugins/xxx.wasm` — 本地文件路径 |
| `defaultConfig` | 插件的 JSON 配置，对应 `parseConfig` 收到的内容 |
| `defaultConfigDisable` | **必须为 `false` 才全局生效** |

### 踩坑警告

> **不要通过 Higress 控制台的 `matchRules` 绑定路由！**
>
> 控制台会将路由名包装为 `_match_route_`，但实际 envoy 路由名带有 `ai-route-` 前缀和 `.internal` 后缀，
> 导致匹配不上，插件不执行。**直接用 `defaultConfigDisable: false` 全局生效最省心。**

### 另一个坑：不要只改宿主机文件

> `data/` 目录虽然是 bind mount，但 Higress controller 启动时会用内部状态覆盖文件。
> 所以**修改配置必须直接改容器内文件**，或通过控制台 API 操作。

---

## Step 5: 重启使配置生效

```bash
# 方式一：重启容器（推荐，确保完全 reload）
docker restart higress-ai-gateway

# 等待就绪
sleep 15
docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/ready
```

### 验证配置已加载

```bash
# 检查 envoy 是否加载了你的插件配置
docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/config_dump | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    s = json.dumps(config)
    if 'my-plugin' in s:
        print('Plugin loaded!')
        parsed = json.loads(s)
        for f in parsed.get('ecds_filters', []):
            cfg = f['ecds_filter']['typed_config']['config']
            val = cfg.get('configuration', {}).get('value', '')
            print(json.dumps(json.loads(val), indent=2))
        break
else:
    print('Plugin NOT found in envoy config!')
"
```

---

## Step 6: 测试验证

### 6.1 开启 wasm 日志

envoy 默认日志级别是 `warning`，看不到插件的 `info` 日志。需要手动开：

```bash
docker exec higress-ai-gateway \
  curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info"
```

### 6.2 发请求

```bash
curl -v -X POST http://localhost:8080/muilt/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"hello"}]}'
```

### 6.3 看插件日志

```bash
docker exec higress-ai-gateway \
  grep "my-plugin" /var/log/higress/gateway.log | tail -20
```

正常输出示例：

```
wasm log: [my-plugin] my-plugin: config parsed, some_field=hello
wasm log: [my-plugin] my-plugin: request received
```

---

## 快速参考：完整目录结构

```
higress-run/
├── docker-compose.yml
├── data/
│   ├── wasmplugins/
│   │   ├── my-plugin.yaml          # WasmPlugin 配置
│   │   └── my-plugin.wasm          # 编译产物
│   ├── mcpbridges/
│   │   └── default.yaml            # 外部服务注册（Redis 等）
│   └── ingresses/                  # 路由配置（控制台自动管理）
├── plugins/
│   └── wasm-go/
│       └── my-plugin/              # 插件源码
│           ├── main.go
│           ├── go.mod
│           ├── go.sum
│           └── build.sh
└── verify-my-plugin.sh             # 验证脚本
```

---

## 快速参考：常用调试命令

```bash
# 查看插件是否加载
docker exec higress-ai-gateway grep "my-plugin" /var/log/higress/gateway.log

# 查看 access log（确认路由匹配）
docker exec higress-ai-gateway tail -5 /var/log/proxy/access.log

# 查看 controller 是否推送了插件配置
docker exec higress-ai-gateway grep "WasmPlugin" /var/log/higress/controller.log | tail -5

# 开启 debug 级别日志
docker exec higress-ai-gateway curl -s -X POST "http://127.0.0.1:15000/logging?wasm=debug"

# 查看 envoy 完整配置
docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/config_dump > config_dump.json
```

---

## 附录：Redis 访问示例

以 ai-load-balancer 插件为例，展示如何在插件中访问 Redis：

```go
// 配置结构体中声明 RedisClient
type MyPluginConfig struct {
    RedisClient wrapper.RedisClient
}

// parseConfig 中初始化
func parseConfig(json gjson.Result, config *MyPluginConfig, log wrapper.Log) error {
    serviceName := json.Get("redis.service_name").String() // 对应 McpBridge 中的 name

    config.RedisClient = wrapper.NewRedisClusterClient(wrapper.DnsCluster{
        ServiceName: serviceName,
        Domain:      serviceName,
        Port:        json.Get("redis.service_port").Int(),
    })
    config.RedisClient.Init(
        json.Get("redis.username").String(),
        json.Get("redis.password").String(),
        json.Get("redis.timeout").Int(),
    )
    return nil
}

// 请求处理中使用
func onHttpRequestHeaders(ctx wrapper.HttpContext, config MyPluginConfig, log wrapper.Log) types.Action {
    config.RedisClient.Get("my_key", func(status int, response resp.Value) {
        log.Infof("redis value: %s", response.String())
        proxywasm.ResumeHttpRequest()
    })
    return types.ActionPause
}
```

对应的 WasmPlugin 配置：

```yaml
defaultConfig:
  redis:
    service_name: "redis-svc"   # 必须和 McpBridge 中注册的 name 一致
    service_port: 6379
    timeout: 2000
```
