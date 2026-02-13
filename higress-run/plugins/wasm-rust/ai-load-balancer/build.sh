#!/bin/bash
set -e

echo "Building AI Load Balancer (Rust) Wasm Plugin..."

# Build using Docker with Rust toolchain
docker run --rm \
  -v $(pwd):/src \
  -w /src \
  rust:1.76-slim \
  /bin/bash -c "apt-get update && apt-get install -y git && rustup target add wasm32-wasi && cargo build --target wasm32-wasi --release"

# Copy artifact
mkdir -p ../../../data/wasmplugins
cp target/wasm32-wasi/release/ai_load_balancer.wasm ../../../data/wasmplugins/ai-load-balancer-rust.wasm

echo "Build complete: ai-load-balancer-rust.wasm"
