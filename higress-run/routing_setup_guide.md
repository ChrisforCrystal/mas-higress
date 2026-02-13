# AI 路由配置指南 (Header 模式)

本指南说明如何在 Higress 控制台中配置路由规则，以便根据 `ai-load-balancer` 插件设置的 Header 将请求转发到正确的 AI 服务后端。

## 原理说明

1.  **插件阶段**: `ai-load-balancer` 插件运行，根据负载选择服务商，并设置 Header：
    - `x-lb-dispatch: minimax-gpu-1` (如果选择了 Minimax)
    - `x-lb-dispatch: qwen-gpu-1` (如果选择了 Qwen)
2.  **路由阶段**: Higress Ingress (Envoy) 根据这个 Header 将请求转发到对应的 Kubernetes Service 或 DNS 域名。

## 解决配置报错的关键

**注意**：Higress 的 AI 路由可能会保留一些特定 Header（如 `x-higress-llm-model`），直接用于匹配规则可能会报错：
`ValidationException: headerPredicates cannot contain the model routing header.`

**解决方案**：我们需要在插件和路由中使用一个**自定义的中性 Header**（例如 `x-lb-dispatch`）来避开这个限制。

---

## 配置步骤 (Higress 控制台)

### 第一步：修改插件配置

首先，告诉插件将结果写入一个新的 Header。

1.  进入 **插件配置**，找到 `AI-plugin-yellowbaby` (ai-load-balancer)。
2.  点击 **编辑配置**。
3.  将 YAML 中的 `target_header` 修改为 `x-lb-dispatch`：

```yaml
redis:
  service_name: "redis-svc"
  service_port: 6379
redis_key_prefix: "ai_metric:"
# 修改这里：
target_header: "x-lb-dispatch"
providers:
  - name: "minimax-gpu-1"
    key: "minimax_1"
  - name: "qwen-gpu-1"
    key: "qwen_1"
```

4.  **保存**。

### 第二步：配置 Minimax 路由规则

现在配置路由来匹配这个新的 Header。

1.  进入 **路由配置**，找到 `/masgod`。
2.  点击 **编辑**。
3.  添加一条新路由（或修改现有）：
    - **匹配规则**:
      - 路径: `/masgod`
      - Header: Key=`x-lb-dispatch`, Value=`minimax-gpu-1`, 匹配方式=**精确匹配**
    - **目标服务**: `minimax-service` (端口 80)
4.  **保存**。

### 第三步：配置 Qwen 路由规则

1.  添加另一条路由：
    - **匹配规则**:
      - 路径: `/masgod`
      - Header: Key=`x-lb-dispatch`, Value=`qwen-gpu-1`, 匹配方式=**精确匹配**
    - **目标服务**: `qianwen-service` (端口 80)
2.  **保存**。

---

## 验证

配置完成后，Header `x-lb-dispatch` 将作为路由的“指挥棒”，不再与 AI 路由的内部逻辑冲突。

```bash
# 测试
curl -v -X POST http://localhost:8080/masgod/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"dispatch test"}]}'
```
