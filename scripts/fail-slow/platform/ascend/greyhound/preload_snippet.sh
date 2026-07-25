#!/usr/bin/env bash
# 打印可 eval 的 Greyhound Ascend LD_PRELOAD 片段，并解释挂载方式。
# 用法:
#   eval "$(bash preload_snippet.sh)"
#   bash preload_snippet.sh --explain
set -euo pipefail

SO="${FS_GREYHOUND_SO:-/workspace/probe-bundle/greyhound/libhcclprobe.so}"
EXPLAIN=0
if [[ "${1:-}" == "--explain" ]]; then
  EXPLAIN=1
fi

if [[ "$EXPLAIN" -eq 1 ]]; then
  cat <<EOF
# Greyhound Ascend · LD_PRELOAD 说明
#
# 1) 在目标 pod 内先编 stub:
#      bash platform/ascend/greyhound/install_stub.sh /workspace/probe-bundle/greyhound
# 2) 训练启动前（每个 rank）:
#      eval "\$(bash platform/ascend/greyhound/preload_snippet.sh)"
#    等价于把 \$FS_GREYHOUND_SO 插到 LD_PRELOAD 最前。
# 3) 编排也可直接用 config_denv_ascend.sh 的 C3_greyhound 分支。
# 4) S1 验收: stderr 出现 [hcclprobe-stub] loaded；或存在
#      \$FS_GH_STUB_MARKER（默认 /tmp/hcclprobe.stub.loaded）
# 5) 本 stub 不 hook HCCL；S2 真 probe 才会拦截集合通信符号。
# 当前 SO 路径: $SO
EOF
  exit 0
fi

# stdout 仅给 eval 用
cat <<EOF
export FS_GREYHOUND_SO='$SO'
if [ -f "\$FS_GREYHOUND_SO" ]; then
  case ":\${LD_PRELOAD:-}:" in
    *:"\$FS_GREYHOUND_SO":*) ;;
    *) export LD_PRELOAD="\$FS_GREYHOUND_SO\${LD_PRELOAD:+:\$LD_PRELOAD}" ;;
  esac
  echo "[greyhound] LD_PRELOAD=\$LD_PRELOAD" >&2
else
  echo "[greyhound] WARN: missing \$FS_GREYHOUND_SO (run install_stub.sh first)" >&2
fi
EOF
