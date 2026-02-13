# AI 负载均衡与模型动态改写插件 (AI-Load-Balancer)

本项目是一个基于 Higress Wasm Go SDK 开发的高性能网关插件。它实现了**基于实时负载的智能服务商选择**，并自动完成**请求体模型字段（Model）的精准改写**。

---

## 一、 架构设计核心 (The "Triad" Architecture)

本插件的设计遵循“逻辑与物理分离”的原则，由决策、路由、转换三个层级协同工作：

### 1. 决策层 (Decision Layer - Wasm Plugin)
*   **实时监控**：插件异步调用 Redis 获取各 AI 服务商的当前负载指标。
*   **智能选路**：根据最小负载算法选出最优 Provider（如 `minmax` 或 `qianwen`）。
*   **信号产出**：
    *   **路由信号**：向请求头注入 `x-selected-provider`。
    *   **改写信号**：通过 Header 染色注入 `x-rewrite-target-model`。

### 2. 路由层 (Routing Layer - Envoy Engine)
*   **强制重路由 (Clear Route Cache)**：插件修改 Header 后，显式触发 Envoy 清除路由缓存并重新匹配。
*   **对称关联**：利用 Higress 路由规则，将 Header 信号映射到真实的后端 Service 集群。
*   **规避回环**：采用“逻辑排他匹配”，插件仅挂载在总路由，专用路由不挂载插件，物理截断死循环。

### 3. 转换层 (Transformation Layer - JSON Rewriter)
*   **非侵入式改写**：在 Body 处理阶段，使用 `sjson` 库将通用模型名（如 `auto`）动态替换为服务商真实要求的标识符（如 `qwen3-max-preview`）。

---

## 二、 三大技术突破点 (Key Technical Highlights)

1.  **Header 染色 (Header Coloring)**：解决了 Wasm 异步回调中 HttpContext 状态丢失的顽疾。将模型名“染色”在请求头上随波逐流，确保 100% 状态拾取。
2.  **路由重选 (Re-routing)**：通过 `proxywasm.SetProperty` 强行打破 Envoy 的路由匹配记忆，实现“指哪打哪”的精准转发。
3.  **防回环漏斗设计**：通过在 UI 层面区分“决策路由”与“投递路由”，实现了高效且安全的流量闭环。

---

## 三、 标准研发流程

### 1. 插件部署
```bash
# 编译并分发 Wasm 文件
cd plugins/wasm-go/ai-load-balancer
bash build.sh
# 强制覆盖容器内文件 (解决挂载延迟)
docker cp ai-load-balancer.wasm higress-ai-gateway:/data/wasmplugins/ai-load-balancer-go.wasm
```

### 2. UI 路由关联
在 Higress 控制台配置路由（如 `/masgod`）：
*   **总路由**：路径 `/masgod`，启用本插件，配置 50/50 分流作为兜底。
*   **专用路由 1**：路径 `/masgod`，设置 Header 匹配 `x-selected-provider == qianwen`，指向千问服务，**不启用插件**。
*   **专用路由 2**：路径 `/masgod`，设置 Header 匹配 `x-selected-provider == minmax`，指向 MiniMax 服务，**不启用插件**。

### 3. YAML 配置标准
在插件策略中填入以下最简配置：
```yaml
providers:
- name: "minmax"             # 匹配路由 Header 的值
  key: "minimax_1"           # Redis Key
  model: "MiniMax-M2.1"      # 改写后的真名
- name: "qianwen"
  key: "qwen_1"
  model: "qwen3-max-preview"
redis:
  service_name: "redis-svc"
  service_port: 6379
```

---

## 四、 验证指南 (Colleague's Checklist)

### 场景 A：验证转发至“通义千问”
1.  **操控负载**：
    ```bash
    docker exec higress-redis redis-cli SET ai_metric:minimax_1 90
    docker exec higress-redis redis-cli SET ai_metric:qwen_1 10
    ```
2.  **发送请求**：
    ```bash
    curl -X POST http://localhost:8080/masgod/v1/chat/completions 
      -H "Content-Type: application/json" 
      -d '{"model":"auto","messages":[{"role":"user","content":"你好"}]}'
    ```
3.  **预期结果**：响应内容来自千问，且字段 `"model":"qwen3-max-preview"`。

### 场景 B：验证转发至“MiniMax”
1.  **反转负载**：
    ```bash
    docker exec higress-redis redis-cli SET ai_metric:minimax_1 10
    docker exec higress-redis redis-cli SET ai_metric:qwen_1 90
    ```
2.  **再次请求**，预期收到 MiniMax 的回复，模型名为 `"model":"MiniMax-M2.1"`。

---

## 五、 维护与扩展
*   **增加服务商**：只需在 UI 增加一行 Provider 配置 + 在路由增加一个 Header 匹配分流即可。
*   **热更新**：修改 YAML 配置秒级生效，修改代码需重新编译并执行 `docker cp`。
