#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PLUGIN_NAME="ai-load-balancer"
# 修改这里指向你的镜像仓库
REGISTRY="localhost:5000"
IMAGE="${REGISTRY}/plugins/${PLUGIN_NAME}:1.0.0"

echo "=== Step 1: 编译 wasm ==="
docker run --rm -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  /bin/bash -c "go mod tidy && tinygo build -o ${PLUGIN_NAME}.wasm -scheduler=none -target=wasi -gc=custom -tags='custommalloc nottinygc_finalizer proxy_wasm_version_0_2_100' main.go"

echo "=== Step 2: 推送 OCI 镜像到 ${IMAGE} ==="
docker run --rm --net=host -v $(pwd):/src -w /src \
  higress-registry.cn-hangzhou.cr.aliyuncs.com/plugins/wasm-go-builder:go1.19-tinygo0.28.1-oras1.0.0 \
  oras push ${IMAGE} \
    --artifact-type application/vnd.oci.image.layer.v1.tar+gzip \
    ./${PLUGIN_NAME}.wasm:application/wasm

echo ""
echo "=== Done ==="
echo "镜像地址: ${IMAGE}"
echo "在 Higress 控制台 → 插件市场 → 添加自定义插件 → 输入: ${IMAGE}"
