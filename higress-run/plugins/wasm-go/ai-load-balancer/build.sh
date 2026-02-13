#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Go Wasm plugin..."
docker run --rm -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  /bin/bash -c "go mod tidy && tinygo build -o ai-load-balancer.wasm -scheduler=none -target=wasi -gc=custom -tags='custommalloc nottinygc_finalizer proxy_wasm_version_0_2_100' main.go"

echo "Copying artifact to data/wasmplugins/..."
cp ai-load-balancer.wasm ../../../data/wasmplugins/ai-load-balancer-go.wasm

echo "Build complete: ai-load-balancer-go.wasm"
