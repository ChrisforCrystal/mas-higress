# Higress Wasm-Go 插件开发指南

> 基于 ai-load-balancer 插件实战经验总结，从 0 到 1 跑通一个自定义插件。

## 整体流程

```
1. 写代码 → 2. 编译 wasm → 3. 复制到 data 目录 → 4. 控制台添加插件 → 5. 控制台挂载到路由 → 6. 验证
```

---

## Step 1: 创建插件项目

```bash
mkdir -p plugins/wasm-go/my-plugin
cd plugins/wasm-go/my-plugin
```

### 1.1 初始化 go.mod

```go
module my-plugin

go 1.19

require (
    github.com/alibaba/higress/plugins/wasm-go v1.3.5
    github.com/higress-group/proxy-wasm-go-sdk v0.0.0-20240226064518-b3dc4646a35a
    github.com/tidwall/gjson v1.14.4
)
```

依赖说明：
- `wasm-go v1.3.5` — Higress 官方 SDK，提供 `wrapper.SetCtx`、Redis 客户端等
- `proxy-wasm-go-sdk` — 底层 proxy-wasm ABI，提供 `proxywasm.ReplaceHttpRequestHeader` 等
- `gjson` — 解析插件 JSON 配置
- 如需访问 Redis，额外加 `github.com/tidwall/resp v0.1.1`

### 1.2 编写 main.go

插件核心就三部分：**配置结构体 + 解析配置 + 处理请求**。

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
        "my-plugin",                                           // 插件名，日志前缀
        wrapper.ParseConfigBy(parseConfig),                    // 配置解析函数
        wrapper.ProcessRequestHeadersBy(onHttpRequestHeaders), // 请求头处理
    )
}

// ========== 1. 定义配置结构体 ==========
type MyPluginConfig struct {
    SomeField string
}

// ========== 2. 解析配置（启动时 + 配置变更时调用） ==========
func parseConfig(json gjson.Result, config *MyPluginConfig, log wrapper.Log) error {
    config.SomeField = json.Get("some_field").String()
    log.Infof("my-plugin: config parsed, some_field=%s", config.SomeField)
    return nil
}

// ========== 3. 处理请求（每个匹配的请求都会调用） ==========
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

插件需要调用外部服务（如 Redis）时，必须用 **Pause + Callback + Resume** 模式：

```go
func onHttpRequestHeaders(ctx wrapper.HttpContext, config MyPluginConfig, log wrapper.Log) types.Action {
    err := config.RedisClient.Get("some_key", func(status int, response resp.Value) {
        // 回调中处理结果
        log.Infof("got value: %s", response.String())
        // 【重要】处理完必须 Resume，否则请求会一直挂着
        proxywasm.ResumeHttpRequest()
    })

    if err != nil {
        return types.ActionContinue // 调用失败，直接放行
    }
    return types.ActionPause // 【重要】返回 Pause，等待回调
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

echo "=== 编译 wasm ==="
docker run --rm -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  /bin/bash -c "go mod tidy && tinygo build -o ${PLUGIN_NAME}.wasm \
    -scheduler=none -target=wasi -gc=custom \
    -tags='custommalloc nottinygc_finalizer proxy_wasm_version_0_2_100' main.go"

echo "=== 复制到 data/wasmplugins/ ==="
cp ${PLUGIN_NAME}.wasm ../../../data/wasmplugins/${PLUGIN_NAME}.wasm

echo "Done: ${PLUGIN_NAME}.wasm"
```

### 2.2 执行编译

```bash
chmod +x build.sh
./build.sh
```

> 首次构建会拉取 ~1GB 的 builder 镜像，后续编译很快。
> 编译产物自动复制到 `data/wasmplugins/`，容器通过 bind mount 直接可见。

---

## Step 3: 注册外部服务（如需 Redis 等）

如果插件需要访问 Redis 或其他外部服务，在 Higress 控制台 → **服务来源** 中添加：

| 字段 | 值 | 说明 |
|------|-----|------|
| 服务名称 | `redis-svc` | 插件配置中的 `service_name` |
| 服务类型 | `DNS` | |
| 域名 | `host.docker.internal` | Docker 容器访问宿主机 |
| 端口 | `6379` | |

> 这一步注册后，插件代码中通过 `wrapper.NewRedisClusterClient(wrapper.DnsCluster{ServiceName: "redis-svc", ...})` 即可访问。

---

## Step 4: 在控制台添加插件

打开 Higress 控制台（http://localhost:8001）→ **插件配置** → **添加插件**

镜像地址填本地文件路径：

```
file:///data/wasmplugins/my-plugin.wasm
```

填完后点确认，插件就会出现在插件列表中。

### 生产环境：使用 OCI 镜像

本地开发用 `file://` 即可。生产环境建议打包成 OCI 镜像推送到镜像仓库：

```bash
# builder 镜像自带 oras 工具，可以直接推送
REGISTRY="your-registry.com"
IMAGE="${REGISTRY}/plugins/my-plugin:1.0.0"

docker run --rm --net=host -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  oras push ${IMAGE} \
    --artifact-type application/vnd.oci.image.layer.v1.tar+gzip \
    ./my-plugin.wasm:application/wasm
```

然后在控制台镜像地址填：`your-registry.com/plugins/my-plugin:1.0.0`

---

## Step 5: 在控制台挂载插件到路由

这是最关键的一步，也是生产环境的正确姿势。

1. 进入 **路由配置** 页面
2. 找到目标路由，点击 **策略**
3. 找到你的插件，点击 **开启**
4. 填写插件配置（YAML 格式），例如：

```yaml
redis:
  service_name: "redis-svc"
  service_port: 6379
  timeout: 2000
redis_key_prefix: "ai_metric:"
target_header: "x-selected-provider"
providers:
  - name: "minimax-gpu-1"
    key: "minimax_1"
  - name: "qwen-gpu-1"
    key: "qwen_1"
```

5. 保存，**即时生效**，不需要重启

> 通过控制台挂载到路由，Higress 会自动处理路由名映射，插件只对该路由生效。
> 不同路由可以挂载同一个插件但使用不同的配置。

---

## Step 6: 验证

### 6.1 开启 wasm 日志

envoy 默认日志级别是 `warning`，看不到插件的 `info` 日志，需要手动开：

```bash
docker exec higress-ai-gateway \
  curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info"
```

### 6.2 发请求

```bash
# 替换 /your-route-path 为你的路由前缀
curl -v -X POST http://localhost:8080/your-route-path/v1/chat/completions \
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

### 6.4 确认插件配置已推送到 envoy

```bash
docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/config_dump | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    s = json.dumps(config)
    if 'my-plugin' in s:
        parsed = json.loads(s)
        for f in parsed.get('ecds_filters', []):
            cfg = f['ecds_filter']['typed_config']['config']
            val = cfg.get('configuration', {}).get('value', '')
            print(json.dumps(json.loads(val), indent=2))
        break
"
```

---

## 开发迭代流程

日常改代码后的迭代流程非常简单：

```bash
# 1. 改代码
vim main.go

# 2. 重新编译（自动复制到 data/wasmplugins/）
./build.sh

# 3. 重启 higress 加载新 wasm
docker restart higress-ai-gateway

# 4. 等待就绪后验证
sleep 15
docker exec higress-ai-gateway curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info"
curl -X POST http://localhost:8080/your-route/v1/chat/completions ...
docker exec higress-ai-gateway grep "my-plugin" /var/log/higress/gateway.log | tail -10
```

> 路由和插件配置在控制台里配好后就持久化了，重启不丢失。只需要重新编译 + 重启即可。

---

## 快速参考：目录结构

```
higress-run/
├── data/
│   ├── wasmplugins/
│   │   └── my-plugin.wasm          # 编译产物（build.sh 自动复制）
│   └── mcpbridges/
│       └── default.yaml            # 外部服务注册（Redis 等）
├── plugins/
│   └── wasm-go/
│       └── my-plugin/              # 插件源码
│           ├── main.go
│           ├── go.mod
│           ├── go.sum
│           └── build.sh
└── PLUGIN-DEV-GUIDE.md
```

> 插件的 YAML 配置不需要手动管理，全部由 Higress 控制台自动生成和维护。

---

## 快速参考：常用调试命令

```bash
# 查看插件日志
docker exec higress-ai-gateway grep "my-plugin" /var/log/higress/gateway.log | tail -20

# 查看 access log（确认路由匹配 + 上游选择）
docker exec higress-ai-gateway tail -5 /var/log/proxy/access.log

# 查看 controller 推送记录
docker exec higress-ai-gateway grep "WasmPlugin" /var/log/higress/controller.log | tail -5

# 开启 debug 日志
docker exec higress-ai-gateway curl -s -X POST "http://127.0.0.1:15000/logging?wasm=debug"

# 导出 envoy 完整配置（排查问题用）
docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/config_dump > config_dump.json

# Mock Redis 数据（测试用）
docker exec higress-redis redis-cli set ai_metric:minimax_1 10
docker exec higress-redis redis-cli set ai_metric:qwen_1 90
```

---

## 附录 A：Redis 访问完整示例

```go
type MyPluginConfig struct {
    RedisClient wrapper.RedisClient
}

func parseConfig(json gjson.Result, config *MyPluginConfig, log wrapper.Log) error {
    serviceName := json.Get("redis.service_name").String()
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

func onHttpRequestHeaders(ctx wrapper.HttpContext, config MyPluginConfig, log wrapper.Log) types.Action {
    config.RedisClient.Get("my_key", func(status int, response resp.Value) {
        log.Infof("redis value: %s", response.String())
        proxywasm.ResumeHttpRequest()
    })
    return types.ActionPause
}
```

路由策略中的配置：

```yaml
redis:
  service_name: "redis-svc"
  service_port: 6379
  timeout: 2000
```

---

## 附录 B：踩坑记录

### 1. 不要手动编辑容器内的 YAML 配置文件

Higress controller 管理 `/data/wasmplugins/*.yaml`，手动改会被覆盖。
所有插件配置通过**控制台操作**，这是唯一正确的方式。

### 2. envoy 默认日志级别是 warning

插件的 `log.Infof()` 看不到输出。每次重启后都需要手动开启：

```bash
docker exec higress-ai-gateway curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info"
```

### 3. 改完代码必须重启容器

wasm 文件是启动时加载的，`build.sh` 编译后需要 `docker restart higress-ai-gateway` 才能生效。
但控制台上的**配置变更是即时生效的**，不需要重启。

### 4. 异步调用必须 Pause + Resume

调用 Redis/HTTP 等外部服务时，忘记 `return types.ActionPause` 会导致请求在回调执行前就已经转发走了；
忘记 `proxywasm.ResumeHttpRequest()` 会导致请求永远挂起。
