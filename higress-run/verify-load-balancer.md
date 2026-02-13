# AI 负载均衡插件验证指南

本指南概述了手动验证 AI 负载均衡器（基于 Header 路由模式）的步骤，确保流量根据存储在 Redis 中的提供商负载指标正确路由。

## 前置条件

确保以下容器正在运行：

- `higress-ai-gateway`
- `higress-redis`

示例中使用的默认路由是 `/masgod`。如果您的路由不同，请相应调整。

## 步骤 1: 准备环境

### 1. 检查组件状态

验证 Redis 是否可达以及 Higress 是否就绪。

```bash
docker exec higress-redis redis-cli ping
# 预期输出: PONG

docker exec higress-ai-gateway curl -s http://127.0.0.1:15000/ready
# 预期输出: LIVE
```

### 2. 开启 Wasm 日志

查看插件调试输出（提供商指标和选择逻辑）所必需。

```bash
docker exec higress-ai-gateway curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info"
```

---

## 步骤 2: 验证场景 A (正常负载)

### 1. 设置 Mock Redis 数据

模拟 **Minimax** 负载较低 (10) 而 **Qwen** 负载较高 (90) 的场景。

```bash
# 设置指标
docker exec higress-redis redis-cli set ai_metric:minimax_1 10
docker exec higress-redis redis-cli set ai_metric:qwen_1 90

# 验证数据
docker exec higress-redis redis-cli mget ai_metric:minimax_1 ai_metric:qwen_1
# 预期输出: 10, 90
```

### 2. 发送请求

发送带有 `model: "auto"` 的聊天补全请求。

```bash
curl -v -X POST http://localhost:8080/masgod/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"test"}]}'
```

插件应该选择 **Minimax** (负载最低)。

### 3. 验证日志

检查网关日志以确人插件执行情况。

```bash
docker exec higress-ai-gateway grep "ai-load-balancer" /var/log/higress/gateway.log | tail -10
```

**预期输出:**

- `provider=minimax-gpu-1 metric=10`
- `provider=qwen-gpu-1 metric=90`
- `Selected: minimax-gpu-1`

---

## 步骤 3: 验证场景 B (反向压测)

### 1. 反转负载指标

模拟 **Minimax** 过载 (95) 而 **Qwen** 空闲 (5) 的场景。

```bash
docker exec higress-redis redis-cli set ai_metric:minimax_1 95
docker exec higress-redis redis-cli set ai_metric:qwen_1 5
```

### 2. 发送请求

再次发送相同的请求。

```bash
curl -v -X POST http://localhost:8080/masgod/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"auto","messages":[{"role":"user","content":"reverse test"}]}'
```

插件现在应该选择 **Qwen** (负载最低)。

### 3. 验证日志

再次检查日志。

```bash
docker exec higress-ai-gateway grep "ai-load-balancer" /var/log/higress/gateway.log | tail -10
```

**预期输出:**

- `provider=minimax-gpu-1 metric=95`
- `provider=qwen-gpu-1 metric=5`
- `Selected: qwen-gpu-1`

---

## 故障排除

如果未出现日志：

1.  确保您运行了 `logging?wasm=info` 命令。
2.  如果文件日志为空（例如权限问题或日志轮转），请直接检查 `docker logs higress-ai-gateway`。
3.  通过 Higress 控制台验证插件是否已在路由上启用。
