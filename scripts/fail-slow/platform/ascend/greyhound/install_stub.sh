#!/usr/bin/env bash
# 在 Ascend pod（或本机 dry-run）生成最小可加载 libhcclprobe.so。
# 仅 constructor：验证 LD_PRELOAD 路径；无 HCCL 符号拦截、无 Redis。
#
# 用法:
#   bash install_stub.sh [/workspace/probe-bundle/greyhound]
#   FS_GH_STUB_MARKER=/tmp/hcclprobe.stub.loaded bash install_stub.sh
set -euo pipefail

OUT_DIR="${1:-${FS_GREYHOUND_DIR:-/workspace/probe-bundle/greyhound}}"
SO_NAME="${FS_GREYHOUND_SO_NAME:-libhcclprobe.so}"
MARKER_DEFAULT="/tmp/hcclprobe.stub.loaded"
MARKER="${FS_GH_STUB_MARKER:-$MARKER_DEFAULT}"

mkdir -p "$OUT_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 注意：MARKER 路径编译进 .so；换路径需重装 stub。
cat >"$TMP/stub.c" <<C
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

__attribute__((constructor)) static void fs_gh_stub_init(void) {
  const char *marker = "$MARKER";
  fprintf(stderr,
          "[hcclprobe-stub] loaded pid=%d ppid=%d so=libhcclprobe.so "
          "(Ascend Greyhound S0/S1 load-only; no HCCL hooks)\n",
          (int)getpid(), (int)getppid());
  fflush(stderr);
  if (marker && marker[0]) {
    FILE *f = fopen(marker, "w");
    if (f) {
      fprintf(f, "pid=%d\n", (int)getpid());
      fclose(f);
    }
  }
}
C

CXX="${CXX:-g++}"
"$CXX" -shared -fPIC -O2 -o "$OUT_DIR/$SO_NAME" "$TMP/stub.c" -ldl -lpthread
ls -la "$OUT_DIR/$SO_NAME"

# 编排侧可读的小说明（同目录）
cat >"$OUT_DIR/STUB_README.txt" <<EOF
libhcclprobe.so — Greyhound Ascend load-only stub
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
marker_on_load: $MARKER
LD_PRELOAD example:
  export LD_PRELOAD=$OUT_DIR/$SO_NAME\${LD_PRELOAD:+:\$LD_PRELOAD}
EOF

echo "STUB_OK path=$OUT_DIR/$SO_NAME marker=$MARKER"
echo "Next: eval \"\$(bash $(cd "$(dirname "$0")" && pwd)/preload_snippet.sh)\""
