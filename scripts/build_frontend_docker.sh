#!/usr/bin/env bash
# 在 Docker 内构建 Probing Web UI（解决宿主机 glibc 过旧 / 无 libssl-dev 问题）
set -eo pipefail

ROOT="/home/yjr/probing-test/probing"
IMAGE="${PROBING_FRONTEND_IMAGE:-ubuntu:24.04}"
DX_VER="${DX_VERSION:-0.7.9}"

echo "[frontend-docker] image=$IMAGE dx=$DX_VER"

docker run --rm \
  -v "$ROOT:/probing" \
  -w /probing \
  "$IMAGE" \
  bash -lc "
    set -eo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates build-essential pkg-config libssl-dev \
      git python3 wget > /dev/null

    # Rust toolchain
    if ! command -v cargo >/dev/null 2>&1; then
      curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    fi
    source \"\$HOME/.cargo/env\"
    rustup target add wasm32-unknown-unknown

    # dioxus-cli
    if ! command -v dx >/dev/null 2>&1; then
      curl -sSL -o /tmp/dx.tgz \
        \"https://github.com/DioxusLabs/dioxus/releases/download/v${DX_VER}/dx-x86_64-unknown-linux-gnu.tar.gz\"
      tar xzf /tmp/dx.tgz -C /usr/local/bin
      chmod +x /usr/local/bin/dx
    fi
    dx --version

    cd /probing
    make frontend
    test -f web/dist/index.html
    test -f python/probing/bundled_web/index.html
    echo '[frontend-docker] OK'
    du -sh web/dist python/probing/bundled_web
  "

echo "[frontend-docker] 完成: $ROOT/web/dist"
