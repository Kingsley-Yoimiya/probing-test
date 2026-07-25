#!/usr/bin/env bash
# 编 Ascend Greyhound collect-min libhcclprobe.so（HCCL 符号拦截 + JSONL dump）。
# 用法:
#   bash install_collect_min.sh [/data/yinjinrun.p-huawei/probe-bundle/greyhound]
set -euo pipefail

OUT_DIR="${1:-${FS_GREYHOUND_DIR:-/data/yinjinrun.p-huawei/probe-bundle/greyhound}}"
SO_NAME="${FS_GREYHOUND_SO_NAME:-libhcclprobe.so}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC_DIR}/collect_min.c"

mkdir -p "$OUT_DIR"
CXX="${CC:-${CXX:-gcc}}"
# 必须用 C 链接名导出 Hccl*；勿用会 mangle 的纯 g++ 且无 extern "C"
"$CXX" -shared -fPIC -O2 -o "$OUT_DIR/$SO_NAME" "$SRC" -ldl -lpthread
ls -la "$OUT_DIR/$SO_NAME"
if ! nm -D "$OUT_DIR/$SO_NAME" | grep -E ' T HcclAllReduce$'; then
  echo "FATAL: HcclAllReduce not exported as C symbol (mangled?). Use gcc or extern C." >&2
  nm -D "$OUT_DIR/$SO_NAME" | grep -i Hccl | head -20 >&2 || true
  exit 2
fi
nm -D "$OUT_DIR/$SO_NAME" | grep -E ' T Hccl(AllReduce|Broadcast|AllGather|ReduceScatter|Send|Recv)$' || true

cat >"$OUT_DIR/COLLECT_MIN_README.txt" <<EOF
libhcclprobe.so — Greyhound Ascend collect-min
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
source: collect_min.c
dump: \$GREYHOUND_DUMP (default /tmp/hcclprobe.collect.jsonl)
LD_PRELOAD example:
  export GREYHOUND_DUMP=$OUT_DIR/events.jsonl
  export GREYHOUND_DEBUG=1
  export LD_PRELOAD=$OUT_DIR/$SO_NAME\${LD_PRELOAD:+:\$LD_PRELOAD}
EOF

echo "COLLECT_MIN_OK path=$OUT_DIR/$SO_NAME"
