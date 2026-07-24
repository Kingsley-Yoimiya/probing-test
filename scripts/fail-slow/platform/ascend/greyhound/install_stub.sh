#!/usr/bin/env bash
# 在 Ascend pod 内生成最小可加载 .so（无探测逻辑）。
set -euo pipefail
OUT_DIR="${1:-/workspace/probe-bundle/greyhound}"
mkdir -p "$OUT_DIR"
TMP=$(mktemp -d)
cat >"$TMP/stub.c" <<'C'
__attribute__((constructor)) static void fs_gh_stub_init(void) {
  /* Ascend Greyhound stub: load-only */
}
C
g++ -shared -fPIC -o "$OUT_DIR/libhcclprobe.so" "$TMP/stub.c"
rm -rf "$TMP"
ls -la "$OUT_DIR/libhcclprobe.so"
