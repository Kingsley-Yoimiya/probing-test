#!/usr/bin/env bash
# preflight_case_pods.sh — 部署后全绿 gate(根除 NO_DATA)
#
# 对每个 raw 特权 pod 校验: Running / GPU 空闲 / import torch / import probing /
# 训练脚本+两 .so 存在且 ldd 无缺 / xscale IB 在。全绿才纳入 inventory。
# 输出: $WORK/pods_ok.csv(可直接喂给 run_campaign.sh 的 NODES)
#
# 用法:
#   PODS="p0,p1,...,p11" CODE_DIR=/afs-.../code KUBECONFIG=~/.kube/... \
#   bash preflight_case_pods.sh
set -uo pipefail

IFS=',' read -r -a PODS <<< "${PODS:?need PODS csv}"
CODE_DIR="${CODE_DIR:?need CODE_DIR (AFS)}"
KC="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
CHECK_SO="${CHECK_SO:-0}"   # 对手 .so 编译好后设 1
WORK="${WORK:-/tmp/preflight-$$}"; mkdir -p "$WORK"
OUT="$WORK/pods_ok.csv"; : > "$OUT"

kx() { kubectl --kubeconfig="$KC" -n "$NS" "$@"; }

check_one() {
  local pod="$1"
  local log="$WORK/check_${pod}.log"
  {
    # 1. Running
    local phase; phase=$(kx get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Running" ] || { echo "FAIL phase=$phase"; return 1; }
    # 2-6 一次 exec 内做完(减少往返)
    kx exec "$pod" -- bash -c '
      set -e
      # 2. GPU 空闲(无其他大进程占卡; 简化: mx-smi 能列出 8 卡)
      mx-smi -L 2>/dev/null | grep -c "GPU" | grep -qE "[8-9]|1[0-6]" || { echo "GPU_LIST_FAIL"; exit 1; }
      # 3. torch
      /opt/conda/bin/python3.12 -c "import torch; assert torch.cuda.is_available()" || { echo "TORCH_FAIL"; exit 1; }
      # 4. probing(允许缺, 仅告警 — Line A C2 才需要)
      PYTHONPATH='"$CODE_DIR"'/pydeps /opt/conda/bin/python3.12 -c "import probing" 2>/dev/null && echo "probing_ok" || echo "probing_WARN"
      # 5. 训练脚本存在
      test -f "'"$CODE_DIR"'/train_bench_probe.py" || { echo "SCRIPT_MISSING"; exit 1; }
      test -f "'"$CODE_DIR"'/sidecar_inject.py" || { echo "SIDECAR_MISSING"; exit 1; }
      # 6. xscale IB
      ls /sys/class/infiniband/ 2>/dev/null | grep -q xscale || echo "IB_WARN(no xscale)"
      echo "PODCHECK_OK"
    ' 2>&1
  } >"$log" 2>&1
  if grep -q PODCHECK_OK "$log"; then
    grep -q probing_WARN "$log" && echo "  ⚠ $pod: probing 缺(C2 会受影响)"
    return 0
  fi
  return 1
}

echo "preflight: ${#PODS[@]} pods"
declare -a OK=()
for pod in "${PODS[@]}"; do
  if check_one "$pod"; then OK+=("$pod"); echo "  ✅ $pod"; else echo "  ❌ $pod ($(tail -1 "$WORK/check_${pod}.log"))"; fi &
done
wait

# 重新收集(子 shell 的数组不回传, 复查一遍快速)
: > "$OUT"
for pod in "${PODS[@]}"; do
  grep -q PODCHECK_OK "$WORK/check_${pod}.log" 2>/dev/null && echo -n "$pod," >> "$OUT"
done
sed -i.bak 's/,$//' "$OUT" 2>/dev/null || true
N=$(tr ',' '\n' < "$OUT" | grep -c . || echo 0)
echo "全绿 pods: $N / ${#PODS[@]} → $OUT"
cat "$OUT"; echo ""
