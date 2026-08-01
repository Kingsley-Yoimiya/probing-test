#!/usr/bin/env bash
# 编 MetaX Greyhound collect-min libmcclprobe.so（mccl* 拦截 + JSONL dump）。
# 用法:
#   bash install_collect_min.sh [/workspace/probe-bundle/greyhound]
set -euo pipefail

OUT_DIR="${1:-${FS_GREYHOUND_DIR:-/workspace/probe-bundle/greyhound}}"
SO_NAME="${FS_GREYHOUND_SO_NAME:-libmcclprobe.so}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="${SRC_DIR}/collect_min.c"

mkdir -p "$OUT_DIR"
CC="${CC:-gcc}"
"$CC" -shared -fPIC -O2 -o "$OUT_DIR/$SO_NAME" "$SRC" -ldl -lpthread
ls -la "$OUT_DIR/$SO_NAME"
if ! nm -D "$OUT_DIR/$SO_NAME" | grep -E ' T mcclAllReduce$'; then
  echo "FATAL: mcclAllReduce not exported as C symbol (mangled?). Use gcc." >&2
  nm -D "$OUT_DIR/$SO_NAME" | grep -i mccl | head -20 >&2 || true
  exit 2
fi
nm -D "$OUT_DIR/$SO_NAME" | grep -E ' T mccl(AllReduce|Broadcast|AllGather|ReduceScatter|Send|Recv)$' || true

cat >"$OUT_DIR/COLLECT_MIN_README.txt" <<EOF
libmcclprobe.so — Greyhound MetaX collect-min
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
source: collect_min.c
dump: \$GREYHOUND_DUMP (default /tmp/mcclprobe.collect.jsonl)
LD_PRELOAD example:
  export GREYHOUND_DUMP=$OUT_DIR/events.jsonl
  export GREYHOUND_DEBUG=1
  export LD_PRELOAD=$OUT_DIR/$SO_NAME\${LD_PRELOAD:+:\$LD_PRELOAD}
EOF

echo "COLLECT_MIN_OK path=$OUT_DIR/$SO_NAME"
