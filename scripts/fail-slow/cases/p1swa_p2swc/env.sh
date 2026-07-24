# P1-SW-A / P2-SW-C 战役环境（source 本文件）
# 访问：weibozhen.p；落盘：yinjinrun.p

unset ALL_PROXY all_proxy
export https_proxy="${https_proxy:-http://127.0.0.1:7897}"
export http_proxy="${http_proxy:-http://127.0.0.1:7897}"
export NO_PROXY=127.0.0.1,localhost
export no_proxy=127.0.0.1,localhost

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-h3c-test-weibozhen.yaml}"
export NS="${NS:-default}"
export POD_PREFIX="${POD_PREFIX:-yjr-p1swa}"

# 64 卡 hold（20260724_173001-p1swa-hold64）；探索可用前 2 台
export HOLD_RUN_ID="${HOLD_RUN_ID:-$(cat /tmp/p1swa_run_id.txt 2>/dev/null || echo 20260724_173001-p1swa-hold64)}"
export PODS_ALL="${PODS_ALL:-$(cat /tmp/p1swa_pods.txt 2>/dev/null || echo yjr-p1swa-h144198,yjr-p1swa-h144201,yjr-p1swa-h144203,yjr-p1swa-h144206,yjr-p1swa-h144207,yjr-p1swa-h14469,yjr-p1swa-h14480,yjr-p1swa-h14484)}"
export PODS_PILOT="${PODS_PILOT:-yjr-p1swa-h144198,yjr-p1swa-h144201}"
export NODES_ALL="${NODES_ALL:-$(cat /tmp/p1swa_nodes.txt 2>/dev/null || true)}"

export NNODES="${NNODES:-2}"
export NPROC="${NPROC:-8}"
export LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
export LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
