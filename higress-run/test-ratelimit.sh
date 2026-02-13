#!/bin/bash

echo "Testing Header-based AI Token Ratelimit..."
echo "Limit is 50 tokens/min for user-123"

# Request 1 (Success expected)
echo "Sending request 1..."
curl -v -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-user-id: user-123" \
  -d '{
    "model": "MiniMax-M2.1",
    "messages": [{"role": "user", "content": "介绍一下杭州"}]
  }'

echo -e "\n\nWaiting 2 seconds..."
sleep 2

# Request 2 (Should fail if token usage > 50)
echo "Sending request 2 (expecting 429 if limit reached)..."
curl -v -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-user-id: user-123" \
  -d '{
    "model": "MiniMax-M2.1",
    "messages": [{"role": "user", "content": "介绍一下杭州"}]
  }'
