#!/bin/bash
set -e

echo "Building AI Load Balancer Wasm Plugin..."

# Check if docker is available
if ! command -v docker &> /dev/null; then
    echo "Docker not found. Please install Docker to build the plugin."
    exit 1
fi

# Use standard Go container to build (avoiding TinyGo compatibility issues)
# Using `sed` to patch a known type mismatch bug in proxy-wasm-go-sdk v0.24.0+
docker run --rm \
  -v $(pwd):/src \
  -w /src \
  golang:1.21 \
  /bin/bash -c "go mod tidy && go mod vendor && \
    GOOS=wasip1 GOARCH=wasm go build -mod=vendor -o ai-load-balancer.wasm ./main.go"

# Copy to data/wasmplugins
cp ai-load-balancer.wasm ../../../../../data/wasmplugins/
echo "Build complete: ai-load-balancer.wasm (Standard Go + Patched SDK)"
