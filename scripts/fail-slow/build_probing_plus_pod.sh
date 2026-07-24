#!/usr/bin/env bash
# 在当前 pod 内构建 Probing_plus wheel（含 gpu+cuda+kmsg）并装到 pydeps。
# 用法: bash build_probing_plus_pod.sh
set -euo pipefail

SRC="${SRC:-/workspace/probe-bundle/probing-src}"
PYDEPS="${PYDEPS:-/workspace/probe-bundle/pydeps}"
PY="${PY:-/opt/conda/bin/python3.12}"
LOG="${LOG:-/tmp/probing_plus_build.log}"

cd "$SRC"
mkdir -p web/dist
[ -f web/dist/index.html ] || echo '<!doctype html><title>probing</title>' > web/dist/index.html

export https_proxy="${https_proxy:-}"
export http_proxy="${http_proxy:-}"
# rustup
if ! command -v rustc >/dev/null 2>&1; then
  echo "[build] installing rustup…" | tee -a "$LOG"
  wget -q https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init -O /tmp/rustup-init
  chmod +x /tmp/rustup-init
  /tmp/rustup-init -y --default-toolchain stable >>"$LOG" 2>&1
fi
# shellcheck disable=SC1090
source "$HOME/.cargo/env"
rustc --version | tee -a "$LOG"

"$PY" -m pip install -q -U pip maturin build wheel toml 2>&1 | tee -a "$LOG"

export MATURIN_FEATURES="extension-module,gpu,gpu-cuda,kmsg"
echo "[build] maturin features=$MATURIN_FEATURES" | tee -a "$LOG"

# skip heavy shims if they fail — core wheel is enough for gpu.utilization
set +e
cargo build -p probing-nccl-profiler-cdylib --release >>"$LOG" 2>&1
NCCL_RC=$?
set -e
if [ "$NCCL_RC" -eq 0 ]; then
  mkdir -p python/probing/libs
  cp -f target/release/libprobing_nccl_profiler.so python/probing/libs/ || true
fi

rm -rf python/probing/bundled_skills
cp -R skills python/probing/bundled_skills
rm -rf python/probing/bundled_web
cp -R web/dist python/probing/bundled_web

mkdir -p dist
"$PY" -m maturin build --release \
  --features "$MATURIN_FEATURES" \
  --out dist 2>&1 | tee -a "$LOG"

WH=$(ls -1 dist/probing-*.whl | head -1)
test -n "$WH"
echo "[build] wheel=$WH" | tee -a "$LOG"

mkdir -p "$PYDEPS"
"$PY" -m pip install --target="$PYDEPS" --force-reinstall --no-deps "$WH" 2>&1 | tee -a "$LOG"
# also expose CLI
mkdir -p "$PYDEPS/bin"
# probing entry may land in pydeps/bin via pip scripts
ls -lh "$PYDEPS/probing/_core"*.so 2>/dev/null || ls -lh "$PYDEPS/probing/"*_core* 2>/dev/null || true
PROBING=0 PYTHONPATH="$PYDEPS" "$PY" -c "import probing; from pathlib import Path; p=Path(probing.__file__).parent; print('ok', probing.__file__); import os; print('so', list(p.glob('_core*')))"

echo "[build] DONE wheel installed to $PYDEPS" | tee -a "$LOG"
echo "$WH"
