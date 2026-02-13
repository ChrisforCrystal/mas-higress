#!/bin/bash
# ============================================================
# AI Load Balancer 插件验证脚本
# 使用方法: bash verify-load-balancer.sh [路由前缀]
# 示例:     bash verify-load-balancer.sh /masgod
# ============================================================

ROUTE_PREFIX="${1:-/masgod}"
CONTAINER="higress-ai-gateway"
REDIS_CONTAINER="higress-redis"
GATEWAY_URL="http://localhost:8080"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

echo "=========================================="
echo " AI Load Balancer 插件验证"
echo " 路由: ${ROUTE_PREFIX}"
echo "=========================================="

# ===== Step 0: 前置检查 =====
echo -e "\n--- Step 0: 前置检查 ---"

if docker exec $REDIS_CONTAINER redis-cli ping | grep -q PONG; then
    pass "Redis 连接正常"
else
    fail "Redis 无法连接"; exit 1
fi

if docker exec $CONTAINER curl -s http://127.0.0.1:15000/ready | grep -q LIVE; then
    pass "Higress Gateway 就绪"
else
    fail "Higress Gateway 未就绪"; exit 1
fi

# 开启 wasm info 日志
docker exec $CONTAINER curl -s -X POST "http://127.0.0.1:15000/logging?wasm=info" > /dev/null
pass "Wasm 日志级别已设为 info"

# ===== Step 1: 写入 Mock Redis 数据 =====
echo -e "\n--- Step 1: 写入 Mock Redis 数据 ---"

docker exec $REDIS_CONTAINER redis-cli set ai_metric:minimax_1 10 > /dev/null
docker exec $REDIS_CONTAINER redis-cli set ai_metric:qwen_1 90 > /dev/null
info "minimax_1=10 (低负载，应该被选中)"
info "qwen_1=90   (高负载)"

# 验证写入
VALS=$(docker exec $REDIS_CONTAINER redis-cli mget ai_metric:minimax_1 ai_metric:qwen_1)
if echo "$VALS" | grep -q "10"; then
    pass "Redis 数据写入成功"
else
    fail "Redis 数据写入失败"; exit 1
fi

# ===== Step 2: 发送请求 =====
echo -e "\n--- Step 2: 发送请求到 ${ROUTE_PREFIX} ---"

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${GATEWAY_URL}${ROUTE_PREFIX}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"hi"}]}')

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

info "HTTP 状态码: ${HTTP_CODE}"
if [ "$HTTP_CODE" = "000" ]; then
    fail "请求失败，Gateway 无法访问"
    exit 1
fi

# ===== Step 3: 检查插件日志 =====
echo -e "\n--- Step 3: 检查插件执行日志 ---"
sleep 1

LOGS=$(docker exec $CONTAINER grep "ai-load-balancer" /var/log/higress/gateway.log | tail -10)

if echo "$LOGS" | grep -q "onHttpRequestHeaders called"; then
    pass "插件已触发"
else
    fail "插件未触发！检查插件是否正确挂载到路由"
    echo ""
    info "调试: 检查 envoy 中的插件配置..."
    docker exec $CONTAINER curl -s http://127.0.0.1:15000/config_dump 2>/dev/null | \
      python3 -c "
import json, sys
data = json.load(sys.stdin)
for config in data.get('configs', []):
    s = json.dumps(config)
    if 'ai-load-balancer' in s.lower() or 'yellowbaby' in s.lower():
        parsed = json.loads(s)
        for f in parsed.get('ecds_filters', []):
            name = f.get('ecds_filter', {}).get('name', '')
            if 'load-balancer' in name.lower() or 'yellowbaby' in name.lower():
                cfg = f['ecds_filter']['typed_config']['config']
                val = cfg.get('configuration', {}).get('value', '')
                parsed_val = json.loads(val) if val else {}
                has_route = '_match_route_' in json.dumps(parsed_val)
                print(f'  Filter: {name}')
                print(f'  Has route match: {has_route}')
                if has_route:
                    rules = parsed_val.get('_rules_', [])
                    for r in rules:
                        print(f'  Match routes: {r.get(\"_match_route_\", [])}')
" 2>/dev/null
    exit 1
fi

if echo "$LOGS" | grep -q "querying Redis"; then
    pass "Redis 查询已发起"
else
    fail "Redis 查询未发起"
fi

# 提取 Selected 结果
SELECTED=$(echo "$LOGS" | grep "Selected:" | tail -1 | sed 's/.*Selected: //')
if [ -n "$SELECTED" ]; then
    pass "插件选择了: ${SELECTED}"
    if echo "$SELECTED" | grep -q "minimax"; then
        pass "选择正确！minimax 负载最低(10) 被优先选择"
    else
        fail "选择异常，期望 minimax-gpu-1 但得到 ${SELECTED}"
    fi
else
    fail "未找到 Selected 日志"
fi

# ===== Step 4: 反转测试 =====
echo -e "\n--- Step 4: 反转测试（交换负载值） ---"

docker exec $REDIS_CONTAINER redis-cli set ai_metric:minimax_1 95 > /dev/null
docker exec $REDIS_CONTAINER redis-cli set ai_metric:qwen_1 5 > /dev/null
info "minimax_1=95 (高负载)"
info "qwen_1=5     (低负载，应该被选中)"

curl -s -X POST "${GATEWAY_URL}${ROUTE_PREFIX}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"test","messages":[{"role":"user","content":"reverse test"}]}' > /dev/null

sleep 1
SELECTED2=$(docker exec $CONTAINER grep "ai-load-balancer.*Selected:" /var/log/higress/gateway.log | tail -1 | sed 's/.*Selected: //')

if echo "$SELECTED2" | grep -q "qwen"; then
    pass "反转测试通过！qwen 负载最低(5) 被优先选择"
else
    fail "反转测试失败，期望 qwen-gpu-1 但得到 ${SELECTED2}"
fi

# ===== 总结 =====
echo -e "\n=========================================="
echo " 验证完成"
echo "=========================================="
echo ""
info "完整插件日志（最近 10 条）:"
docker exec $CONTAINER grep "ai-load-balancer" /var/log/higress/gateway.log | grep -v "parseConfig\|config parsed" | tail -10
