#!/usr/bin/env bash
# Build the XPUTimer Ascend detection hook with plain g++ (no Bazel).
# Mirror of metax_probe/build_metax_hook.sh.
#
# Prefer running INSIDE an Ascend worker pod (g++ + optional CANN headers).
# The hook declares a minimal ABI itself, so full CANN headers are NOT required
# to compile — same strategy as MetaX.
#
# S0/S1 gate: do NOT treat a successful local compile as S1_LOAD. S1 requires
# LD_PRELOAD against a real torch_npu short train without crash.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/libxpu_timer_ascend.so}"
SRC="${HERE}/xpu_timer_ascend_hook.cc"
CXX="${CXX:-g++}"

if [[ ! -f "$SRC" ]]; then
  echo "[build] missing $SRC" >&2
  exit 2
fi

# Optional: refuse to pretend verified symbols without marker file from pod nm.
if [[ "${XPU_TIMER_REQUIRE_VERIFIED_SYMBOLS:-0}" == "1" ]]; then
  if [[ ! -f "${HERE}/.symbols_verified" ]]; then
    echo "[build] REFUSE: XPU_TIMER_REQUIRE_VERIFIED_SYMBOLS=1 but .symbols_verified missing" >&2
    echo "[build] run scan_symbols_on_pod.sh inside training image first" >&2
    exit 3
  fi
fi

echo "[build] CXX=$CXX -> $OUT (DRAFT symbols; see ../SYMBOL_MAP.md)"
echo "[build] NOTE: compile success ≠ S1_LOAD; need pod preload smoke"

$CXX -std=c++17 -O2 -fPIC -shared \
  -o "$OUT" \
  "$SRC" \
  -ldl -lpthread

echo "[build] done: $OUT"
ls -la "$OUT"
echo "[build] exported interposers (expect Hccl* / optional aclrtLaunchKernel):"
nm -D "$OUT" | grep -E " T (Hccl|aclrtLaunchKernel)" || true
