#!/usr/bin/env bash
# 无 NPU 本机自检：编 stub → LD_PRELOAD 跑一个空进程，确认 constructor 触发。
# 不证明 HCCL 训练兼容；只证明挂载链路与 .so 可加载。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/greyhound-stub-selftest-$$"
mkdir -p "$OUT"
export FS_GH_STUB_MARKER="$OUT/marker.loaded"
bash "$ROOT/install_stub.sh" "$OUT"
SO="$OUT/libhcclprobe.so"
test -f "$SO"

# 清旧 marker，再 preload 一个无害命令
rm -f "$FS_GH_STUB_MARKER"
# shellcheck disable=SC2094
LD_PRELOAD="$SO" /bin/echo "selftest-child" >/dev/null

if [[ -f "$FS_GH_STUB_MARKER" ]]; then
  echo "SELFTEST_OK marker=$(cat "$FS_GH_STUB_MARKER") so=$SO"
else
  echo "SELFTEST_FAIL: constructor did not write marker" >&2
  exit 1
fi
