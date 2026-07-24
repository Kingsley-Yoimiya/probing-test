# shellcheck shell=bash
# 本战役默认环境（source 后用）。落盘身份 yinjinrun.p；kube 借用 weibozhen.p。

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"
unset ALL_PROXY ALL_proxy all_proxy 2>/dev/null || true
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FS_ROOT="$(cd "$CASE_DIR/../.." && pwd)"

# 8 实验 + 2 reserve（reserve 默认只记账）
export PODS_1B8C="${PODS_1B8C:-$(cat /tmp/pods_1b8c64.csv 2>/dev/null || true)}"
export NODES_RESERVE="${NODES_RESERVE:-$(cat /tmp/p1hwb_p3swc_nodes_reserve.txt 2>/dev/null || true)}"
export NNODES="${NNODES:-8}"
export NPROC="${NPROC:-8}"
export SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-7}"
export LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
export LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
export POD_PREFIX="${POD_PREFIX:-yjr-1b8c}"
