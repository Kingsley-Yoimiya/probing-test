#!/usr/bin/env bash
# 把 pod 内 /dev/shm 扩到足够大（默认 32G）。
# 当前 mohe 实验 pod 默认只有 Docker/containerd 的 64Mi，8 卡 MCCL 极易打满 → SIGBUS。
#
# 用法：
#   PODS=yjr-fs-h14410,yjr-fs-h14411 KUBECONFIG=... bash ensure_shm.sh
#   SHM_SIZE=64G bash ensure_shm.sh
#
# 两种落地：
# 1) 已有 privileged pod：mount -o remount,size=…（本脚本默认）
# 2) 新建 pod：挂 emptyDir medium=Memory（见 image/pod-shm-snippet.yaml）
set -euo pipefail
# 注意：务必在开训前执行；训练中途 remount 会使已 mmap 的进程 SIGBUS/消失。

PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
SHM_SIZE="${SHM_SIZE:-32G}"
export KUBECONFIG

IFS=',' read -r -a ARR <<< "$PODS"
for pod in "${ARR[@]}"; do
  echo "== $pod: ensure /dev/shm >= $SHM_SIZE =="
  kubectl -n "$NS" exec "$pod" -- bash -c "
    set -e
    cur=\$(df -B1 /dev/shm | awk 'NR==2{print \$2}')
    echo \"current_bytes=\$cur\"
    # 已够大则跳过（阈值约 8Gi）
    if [ \"\${cur:-0}\" -ge 8589934592 ]; then
      df -h /dev/shm | tail -1
      echo already_ok
      exit 0
    fi
    if ! mount -o remount,size=$SHM_SIZE /dev/shm 2>/tmp/shm_remount.err; then
      echo \"remount failed: \$(cat /tmp/shm_remount.err)\"
      echo 'fallback: bind new tmpfs over /dev/shm (停训练后再跑更安全)'
      mkdir -p /dev/shm
      mount -t tmpfs -o size=$SHM_SIZE tmpfs /dev/shm
    fi
    df -h /dev/shm | tail -1
  "
done
echo "ensure_shm done size=$SHM_SIZE"
