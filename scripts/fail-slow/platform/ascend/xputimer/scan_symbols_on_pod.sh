#!/usr/bin/env bash
# Scan torch_npu / HCCL / ACL exports inside an Ascend training pod.
# Writes evidence under $OUT_DIR and touches .symbols_verified on success.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-${XPU_TIMER_DUMP_DIR:-/tmp/xpu_timer_ascend_nm}}"
mkdir -p "$OUT_DIR"

HCCL_SO="${HCCL_SO:-/usr/local/Ascend/ascend-toolkit/latest/lib64/libhccl.so}"
ACL_SO="${ACL_SO:-/usr/local/Ascend/ascend-toolkit/latest/lib64/libascendcl.so}"
TORCH_NPU_SO="${TORCH_NPU_SO:-$(python3 - <<'PY'
import pathlib
try:
  import torch_npu
  p = pathlib.Path(torch_npu.__file__).parent
except Exception:
  p = pathlib.Path()
cands = list(p.rglob("libtorch_npu.so"))
print(cands[0] if cands else "")
PY
)}"

OUT="$OUT_DIR/nm_pod.txt"
{
  echo "# host=$(hostname 2>/dev/null || true) date=$(date -Iseconds)"
  echo "# HCCL=$HCCL_SO"
  echo "# ACL=$ACL_SO"
  echo "# TORCH_NPU=$TORCH_NPU_SO"
  echo
  echo "=== libhccl T Hccl* ==="
  nm -D "$HCCL_SO" 2>/dev/null | grep -E ' T Hccl' | head -80 || true
  echo
  echo "=== libascendcl T aclrt* ==="
  nm -D "$ACL_SO" 2>/dev/null | grep -E ' T aclrt(LaunchKernel|RecordEvent|CreateEvent|QueryEvent|EventElapsedTime|DestroyEvent)' | head -40 || true
  echo
  echo "=== libtorch_npu U Hccl|aclrt|LaunchKernel ==="
  nm -D "$TORCH_NPU_SO" 2>/dev/null | grep -E ' U (Hccl|aclrt)' | head -80 || true
  echo
  echo "=== aclrtLaunchKernel in torch_npu? ==="
  nm -D "$TORCH_NPU_SO" 2>/dev/null | grep -i LaunchKernel || echo NONE
} | tee "$OUT"

# Gate: at least one U HcclAllReduce from torch
if grep -q ' U HcclAllReduce' "$OUT"; then
  touch "$HERE/.symbols_verified"
  echo "[scan] OK -> $HERE/.symbols_verified"
  exit 0
fi
echo "[scan] FAIL: no U HcclAllReduce in torch_npu" >&2
exit 4
