#!/usr/bin/env bash
# provision_priv_pods.sh — 申请 raw 特权 pod(整机) + 铺代码
#
# 为什么 raw pod 而非 vcjob: vcjob 建不了(无 RBAC, 见 privileged-freq-nic-guide.md);
# privileged 只能走 default ns 的 raw Pod。整机 pin 是铁律(mx-smi 能动整机 8 卡)。
#
# AFS(weight-share=/afs-a3-weight-share, h3c PVC=pvc-rmrnm):
#   生产 vcjob 可挂；raw Pod 显式挂 PVC 实测长期 Pending。本战役默认不挂 AFS，
#   用 deploy_local → pod 本地盘，再 pull_campaign_results.sh 回拉本机 results/。
#
# 用法:
#   source ~/.kube/muxi-h3c.env          # KUBECONFIG=yinjinrun.p + Clash 代理
#   NODES="host-10-12-144-138,host-10-12-144-139" RUN_ID=20260723-27case \
#   bash provision_priv_pods.sh apply         # 起 pod
#   bash provision_priv_pods.sh               # 默认：铺到每台 pod /workspace/probe-bundle
#   bash provision_priv_pods.sh deploy        # 仅当 AFS 真挂上时用
#   bash provision_priv_pods.sh delete        # 用完删 pod(会尝试恢复频率档)
set -uo pipefail

IFS=',' read -r -a NODES <<< "${NODES:?need NODES csv (整机空闲节点)}"
RUN_ID="${RUN_ID:?need RUN_ID}"
KC="${KUBECONFIG:?need KUBECONFIG (yinjinrun.p, 经 muxi-h3c.env)}"
NS="${NS:-default}"
# 默认仍是 maca 底包；统一实验镜像构建后覆盖：
#   IMAGE=registry2.d.pjlab.org.cn/ccr-ailabdev/probing-failslow-metax:<tag>
#   见 scripts/probing-failslow/image/README.md
IMAGE="${IMAGE:-registry2.d.pjlab.org.cn/ccr-deeplink/megatron-lm:0.12.0-maca.ai3.3.0.11-torch2.6-py312-ubuntu22.04-amd64-driver}"
# mohe 默认 secret；若环境实际名称为 muxi-mohe，可直接 PULL_SECRET=muxi-mohe 覆盖。
PULL_SECRET="${PULL_SECRET:-megatronmuxi-test}"
POD_PREFIX="${POD_PREFIX:-yjr-case}"
AFS_ROOT="${AFS_ROOT:-/afs-a3-weight-share/yinjinrun.p}"
AFS_RUN_DIR="$AFS_ROOT/results/$RUN_ID"
HERE="$(cd "$(dirname "$0")" && pwd)"
export KUBECONFIG="$KC"

kx() { kubectl -n "$NS" "$@"; }
pod_name() { echo "${POD_PREFIX}-$(echo "$1" | sed 's/host-10-12-/h/;s/\.//g;s/-//g')"; }

gen_manifest() {   # $1=node
  local node="$1" pod; pod="$(pod_name "$node")"
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  namespace: $NS
  labels:
    lepton.sensetime.com/submitter: yinjinrun.p
    purpose: probing-27case
    run-id: "$RUN_ID"
spec:
  nodeName: $node
  restartPolicy: Never
  imagePullSecrets:
  - name: $PULL_SECRET
  containers:
  - name: t
    image: $IMAGE
    command: ["sleep","172800"]
    securityContext:
      privileged: true
    resources:
      limits:   {metax-tech.com/gpu: "8", cpu: "64", memory: "256Gi", rdma-training/roce: "1"}
      requests: {metax-tech.com/gpu: "8", cpu: "64", memory: "256Gi", rdma-training/roce: "1"}
YAML
}

cmd_apply() {
  echo "起 ${#NODES[@]} 个特权 pod(整机 pin):"
  for node in "${NODES[@]}"; do
    local pod; pod="$(pod_name "$node")"
    gen_manifest "$node" | kx apply -f - && echo "  ✓ $pod → $node"
  done
  echo "等待 Running..."
  for node in "${NODES[@]}"; do
    local pod; pod="$(pod_name "$node")"
    kx wait --for=condition=Ready "pod/$pod" --timeout=180s 2>/dev/null && echo "  Ready: $pod" || echo "  ⏳ $pod 未就绪(可能拉镜像慢, 稍后复查)"
  done
  # remount /sys(privileged 调频前置)
  echo "remount rw /sys:"
  for node in "${NODES[@]}"; do
    local pod; pod="$(pod_name "$node")"
    kx exec "$pod" -- mount -o remount,rw /sys 2>/dev/null && echo "  ✓ $pod" || echo "  ⚠ $pod remount 失败"
  done
  # 打印 pod csv 供后续脚本用
  local csv; csv=$(for n in "${NODES[@]}"; do pod_name "$n"; done | paste -sd, -)
  echo "PODS_CSV=$csv"
  echo "$csv" > "/tmp/pods_${RUN_ID}.csv"
}

cmd_deploy() {
  local first; first="$(pod_name "${NODES[0]}")"
  echo "铺代码到 AFS: $AFS_RUN_DIR/code (经 $first 单副本)"
  kx exec "$first" -- bash -c "mkdir -p '$AFS_RUN_DIR/code/pydeps'"
  for f in train_bench_probe.py sidecar_inject.py sidecar_inject_v2.py collect.py; do
    echo "  ↑ $f"
    kx exec -i "$first" -- bash -c "cat > '$AFS_RUN_DIR/code/$f'" < "$HERE/$f"
    # sha 校验
    local local_sha remote_sha
    local_sha=$(shasum -a 256 "$HERE/$f" | awk '{print $1}')
    remote_sha=$(kx exec "$first" -- sha256sum "$AFS_RUN_DIR/code/$f" 2>/dev/null | awk '{print $1}')
    [ "$local_sha" = "$remote_sha" ] && echo "    ✓ sha ok" || echo "    ❌ sha MISMATCH ($f)"
  done
  echo "  pip install probing → pydeps"
  kx exec "$first" -- bash -c "/opt/conda/bin/pip install --target='$AFS_RUN_DIR/code/pydeps' probing -q 2>&1 | tail -2" || echo "  ⚠ probing 安装需复查"
  echo "  安装 stress-ng/perftest(各 pod, 用于 host/EXT 注入)"
  for node in "${NODES[@]}"; do
    local pod; pod="$(pod_name "$node")"
    kx exec "$pod" -- bash -c 'command -v stress-ng >/dev/null 2>&1 || (apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q stress-ng perftest 2>/dev/null); echo done' >/dev/null 2>&1 &
  done
  wait
  echo "deploy 完成. AFS_RUN_DIR=$AFS_RUN_DIR"
}

# 退路: 铺到每台 pod 本地(AFS 未挂时用)。CODE 落 /workspace/probe-bundle
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
deploy_local_one() {
  local pod="$1"
  kx exec "$pod" -- bash -c "mkdir -p '$LOCAL_CODE'/pydeps '$LOCAL_CODE'/out" 2>/dev/null
  local ok=1
  for f in train_bench_probe.py sidecar_inject.py sidecar_inject_v2.py collect.py; do
    kx exec -i "$pod" -- bash -c "cat > '$LOCAL_CODE/$f'" < "$HERE/$f" 2>/dev/null
    local ls rs; ls=$(shasum -a 256 "$HERE/$f" | awk '{print $1}')
    rs=$(kx exec "$pod" -- sha256sum "$LOCAL_CODE/$f" 2>/dev/null | awk '{print $1}')
    [ "$ls" = "$rs" ] || { ok=0; echo "  ❌ $pod $f sha MISMATCH"; }
  done
  # probing 本地装 + stress/perftest
  kx exec "$pod" -- bash -c "/opt/conda/bin/pip install --target='$LOCAL_CODE/pydeps' probing -q 2>/dev/null; command -v stress-ng >/dev/null 2>&1 || (apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q stress-ng perftest 2>/dev/null); true" >/dev/null 2>&1
  [ "$ok" = "1" ] && echo "  ✅ $pod local deploy ok"
}
cmd_deploy_local() {
  echo "铺代码到每台 pod 本地: $LOCAL_CODE (${#NODES[@]} 台并行)"
  for node in "${NODES[@]}"; do deploy_local_one "$(pod_name "$node")" & done
  wait
  echo "deploy_local 完成. LOCAL_CODE=$LOCAL_CODE (每台 pod 本地)"
}

cmd_delete() {
  echo "🔴 删 pod 前请确认已恢复频率档(xcore,9)!"
  for node in "${NODES[@]}"; do
    local pod; pod="$(pod_name "$node")"
    # 保险: 删前恢复档
    kx exec "$pod" -- bash -c 'for i in $(seq 0 7); do mx-smi -i $i --set-dpm-max xcore,9 >/dev/null 2>&1; done' 2>/dev/null || true
    kx delete pod "$pod" --wait=false 2>/dev/null && echo "  🗑 $pod"
  done
}

case "${1:-deploy_local}" in
  apply)  cmd_apply ;;
  deploy) cmd_deploy ;;
  deploy_local) cmd_deploy_local ;;
  delete) cmd_delete ;;
  *) echo "用法: $0 {apply|deploy|deploy_local|delete}"; exit 1 ;;
esac
