#!/usr/bin/env bash
# 打印可 eval 的 Greyhound MetaX LD_PRELOAD 片段。
# 用法: eval "$(bash preload_snippet.sh)"
set -euo pipefail

SO="${FS_GREYHOUND_SO:-/workspace/probe-bundle/greyhound/libmcclprobe.so}"

cat <<EOF
export FS_GREYHOUND_SO='$SO'
if [ -f "\$FS_GREYHOUND_SO" ]; then
  case ":\${LD_PRELOAD:-}:" in
    *:"\$FS_GREYHOUND_SO":*) ;;
    *) export LD_PRELOAD="\$FS_GREYHOUND_SO\${LD_PRELOAD:+:\$LD_PRELOAD}" ;;
  esac
  echo "[greyhound-metax] LD_PRELOAD=\$LD_PRELOAD" >&2
else
  echo "[greyhound-metax] WARN: missing \$FS_GREYHOUND_SO" >&2
fi
EOF
