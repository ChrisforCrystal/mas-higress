#!/bin/bash
# Verify AI Load Balancer Logic
# Pre-requisite: Plugin installed and running, mulit-aiagent-route configured

set -e

CONTAINER="higress-ai-gateway"
REDIS_CONTAINER="higress-redis"
GATEWAY_URL="http://localhost:8080"

echo "=== 0. Checking Services ==="
docker exec $REDIS_CONTAINER redis-cli ping
echo "Redis OK"

echo -e "\n=== 1. Setting Mock Metrics in Redis ==="
# Minimax: 10% busy (Should be selected - lowest utilization)
# Qwen: 90% busy
docker exec $REDIS_CONTAINER redis-cli set ai_metric:minimax_1 10
docker exec $REDIS_CONTAINER redis-cli set ai_metric:qwen_1 90
echo "Metrics set: minimax=10, qwen=90"

# Verify keys
echo "Verifying Redis keys:"
docker exec $REDIS_CONTAINER redis-cli mget ai_metric:minimax_1 ai_metric:qwen_1

echo -e "\n=== 2. Sending Request to /muilt path ==="
# Use the mulit-aiagent-route (prefix match /muilt)
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" \
  -X POST "${GATEWAY_URL}/muilt/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "x-user-id: verify-user" \
  -d '{
    "model": "test-model",
    "messages": [{"role": "user", "content": "load balance test"}]
  }'

echo -e "\nSending verbose request for details:"
curl -v -X POST "${GATEWAY_URL}/muilt/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "x-user-id: verify-user" \
  -d '{
    "model": "test-model",
    "messages": [{"role": "user", "content": "load balance test"}]
  }' 2>&1 | head -50

echo -e "\n\n=== 3. Checking Higress Logs ==="
echo "Displaying last 30 lines of AI Load Balancer logs:"
docker logs $CONTAINER 2>&1 | grep -i "ai-load-balancer" | tail -n 30

echo -e "\n=== 4. Expected Result ==="
echo "Expected: Should see 'Selected: minimax-gpu-1' (lowest utilization=10)"
echo "If no plugin logs appear, the plugin may not be loaded or the route is not matched."

echo -e "\n=== 5. Debug: Check plugin loading ==="
docker logs $CONTAINER 2>&1 | grep -i "wasm\|plugin\|load-balancer" | tail -n 20
