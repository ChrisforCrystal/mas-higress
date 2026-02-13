# AI 负载均衡与模型改写研发指南

本指南介绍如何通过 Higress Wasm 插件实现动态的 AI 负载均衡，并自动将请求体中的通用模型名（如 `auto`）改写为后端服务真实的模型名称。

## 1. 核心原理：对称关联

实现流量精准路由和模型正确识别的关键在于 **“插件输出”** 与 **“路由条件”** 的对称一致性。

1.  **插件决策**：插件从 Redis 获取指标，决定请求该发给哪个服务（例如 `qianwen`）。
2.  **路由 Header (Symmetry)**：插件设置一个特定的 Header（如 `x-selected-provider: qianwen`）。
3.  **路由匹配**：在 Ingress 的 `destination` 注解中，配置规则匹配该 Header，从而将流量导向对应的服务集群。
4.  **模型改写 (Mapping)**：插件根据选中的服务，将 Body 中的 `model` 字段替换为该服务实际支持的模型名（如 `qwen3-max-preview`）。

---

## 2. 插件配置 (Simplified YAML)

在 Higress 控制台页面上，只需配置最基础的映射关系。插件代码会自动根据 `name` 字段与路由 Header 进行适配。

```yaml
providers:
  - name: "minmax"             # 路由关联名
    key: "minimax_1"           # Redis 指标 Key
    model: "MiniMax-M2.1"      # 目标改写模型
  - name: "qianwen"
    key: "qwen_1"
    model: "qwen3-max-preview"
redis:
  service_name: "redis-svc"
  service_port: 6379
  timeout: 2000
redis_key_prefix: "ai_metric:"
target_header: "x-selected-provider"
```

---

## 3. 路由配置 (Ingress Setup)

在 `/masgod` 路由的注解中，建立基于 Header 的转发逻辑。确保这里的 `if` 条件值与插件配置中的 `name` 完全一致。

**关键注解配置：**
```yaml
metadata:
  annotations:
    higress.io/destination: |-
      llm-minmax.internal.dns:443 if x-selected-provider == minmax
      llm-qianwen.internal.dns:443 if x-selected-provider == qianwen
```

---

## 4. 插件实现细节

### A. 异步上下文同步
在 Wasm 异步回调（如 Redis `MGet`）中，必须通过以下方式确保状态能传递到 Body 处理阶段：
*   **Header 染色**：在异步回调中通过 `proxywasm.ReplaceHttpRequestHeader` 设置一个临时 Header（如 `x-rewrite-model`）。
*   **Body 读取**：在 `onHttpRequestBody` 阶段读取该 Header，获取目标模型名。

### B. 模型改写逻辑
使用 `sjson` 库对 Body 进行非侵入式改写，确保 JSON 格式标准、紧凑，避免后端服务解析失败。

```go
newBody, err := sjson.SetBytes(body, "model", targetModel)
if err == nil {
    proxywasm.ReplaceHttpRequestBody(newBody)
}
```

---

## 5. 标准研发与运维流程

整个研发闭环非常简洁，分为“逻辑开发”和“配置关联”两部分：

### A. 初始部署流程
1.  **编写/修改代码**：在 `main.go` 中定义业务逻辑。
2.  **编译插件**：执行 `build.sh` 生成 `.wasm` 文件。
3.  **分发插件**：将 Wasm 文件放置到网关可访问的目录（如 `/data/wasmplugins/`）。
4.  **关联路由**：在控制台页面配置路由 Ingress，设置基于 Header 的 `destination` 转发规则（实现“对暗号”）。

### B. 运维与更新说明
*   **配置更新 (热更新)**：
    *   如果你只是想修改指标 Key、更换目标模型名、或者调整负载均衡权重，**只需在页面上修改 YAML 配置**。
    *   Higress 会实时监听配置变化并**热加载**到插件中，无需重启，秒级生效。
*   **逻辑更新 (重新部署)**：
    *   如果你修改了 `main.go` 里的 Go 代码（例如改变了 Header 的名称或增加了复杂的计算逻辑），则需要**重新编译并替换 Wasm 文件**。
    *   Higress 会检测到文件 MD5 的变化并自动重新加载插件。在某些环境下，执行 `docker-compose restart` 可以确保加载最彻底。

---

## 6. 验证流程 (验证改写与分流)

1.  **指标操控**：
    ```bash
    # 让插件选择千问 (设置千问为低负载)
    docker exec higress-redis redis-cli SET ai_metric:minimax_1 90
    docker exec higress-redis redis-cli SET ai_metric:qwen_1 10
    ```

2.  **发送测试**：
    ```bash
    curl -X POST http://localhost:8080/masgod/v1/chat/completions 
      -H "Content-Type: application/json" 
      -d '{"model":"auto","messages":[{"role":"user","content":"你好"}]}'
    ```

3.  **结果检查**：
    *   响应成功返回：证明路由转发正确。
    *   响应内容中 `"model": "qwen3-max-preview"`：证明模型改写正确。
