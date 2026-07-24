#!/usr/bin/env bash
# run_campaign.sh — 27-case 多组并行调度(flock work-queue)+ 两阶段规模
#
# 阶段①(sweep): 把节点切成 G 组(每组 NNODES 台), 各组从 flock 队列领 case 跑完领下一个。
# 阶段②(scale): 由 run_campaign.sh --scale 单独跑关键 case 大规模(见文末)。
#
# 前置: 节点已 preflight 全绿(preflight_case_pods.sh), 代码已铺 AFS(deploy)。
#
# 用法:
#   RUN_ID=20260723-27case NODES="p0,p1,...,p11" NNODES=2 \
#   AFS_RUN_DIR=/afs-a3-weight-share/yinjinrun.p/results/$RUN_ID \
#   KUBECONFIG=~/.kube/config-vc-c550-h3c-test.yaml \
#   bash run_campaign.sh
set -uo pipefail

RUN_ID="${RUN_ID:?need RUN_ID}"
IFS=',' read -r -a NODES <<< "${NODES:?need NODES csv}"
NNODES="${NNODES:-2}"
NPROC="${NPROC:-8}"
ROUNDS="${ROUNDS:-3}"
AFS_RUN_DIR="${AFS_RUN_DIR:?need AFS_RUN_DIR}"
KC="${KUBECONFIG:?need KUBECONFIG}"
# 本轮 sweep 跑哪些 config; 对手 .so 未编译前默认 C0/C1/C2(baseline/inject/probing)
SWEEP_CONFIGS="${SWEEP_CONFIGS:-C0_baseline,C1_inject_none,C2_probing}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/campaign-$RUN_ID}"
mkdir -p "$WORK"
export KUBECONFIG="$KC"

# ===== case registry =====
# 格式: case_id|inject_kind|mode|inject_args|note
# inject_kind: cube|hbm|1b|1c|2b|2c|2ext|3c|freq|stress_cpu|stress_vm|stress_io|none|internal|mccl
# mode: gpu_bound|host_bound
# note: 真注入优先; N/A 类仍入表但标注(编排会跳过实注入, 仅采检测端证据/对照)
CASE_REGISTRY=$(cat <<'REG'
P1-HW-A|freq|gpu_bound|level=4|privileged 降频 xcore,4
P1-HW-B|freq|gpu_bound|level=2|privileged 间歇节流(分段)
P1-HW-C|freq|gpu_bound|level=mc|privileged 显存降频(mc 档)
P1-SW-A|internal|gpu_bound||allocator 碎片(需训练内注入, 本轮占位)
P1-SW-B|internal|gpu_bound||rare-shape 重编译(训练内)
P1-SW-C|internal|gpu_bound||次优 kernel(训练内)
P1-EXT-A|cube|gpu_bound|duty=0.5|✅ 已验证(pilot 预热后 +214%)
P1-EXT-B|hbm|gpu_bound|duty=0.6|✅ 已验证 +70%
P1-EXT-C|1c|gpu_bound|frac=0.7|显存容量压力
P2-HW-A|none|gpu_bound||N/A: tc 对 RoCE 无效 → 见 P2-EXT-A + rdma statistic
P2-HW-B|none|gpu_bound||N/A: netem 无效 → rdma statistic retrans/seq_err 检测端
P2-HW-C|freq|gpu_bound|level=pci|privileged set-pci-speed
P2-SW-A|mccl|gpu_bound||MCCL fallback transport(env)
P2-SW-B|mccl|gpu_bound||MCCL algo/proto 选错(env)
P2-SW-C|mccl|gpu_bound||MCCL collective 延迟 shim
P2-EXT-A|2ext|gpu_bound||✅ ib_write_bw 打满共享链路(高保真)
P2-EXT-B|2ext|gpu_bound||checkpoint 突发上传(打流变体)
P2-EXT-C|2ext|gpu_bound||incast(多源打流, ground truth 缺交换机)
P3-HW-A|freq|host_bound|level=cpu|privileged cpufreq(host_bound)
P3-HW-B|stress_vm|host_bound||内存 BW 退化(host_bound)
P3-HW-C|freq|gpu_bound|level=ecc|set-ecc-state 代理
P3-SW-A|8a|host_bound||✅ GC 压力(修部署+host_bound)
P3-SW-B|8b|host_bound||dataloader 泄漏(host_bound)
P3-SW-C|8c|host_bound||GIL/日志阻塞(host_bound)
P3-EXT-A|stress_cpu|host_bound||✅ CPU 核抢占(host_bound 才有效)
P3-EXT-B|stress_vm|host_bound||内存压力/swap(host_bound)
P3-EXT-C|stress_io|host_bound||磁盘 IO 争用(host_bound)
REG
)

# ===== 建队列(过滤纯 N/A 的实注入; 仍保留供采检测端, 但标 SKIP_INJECT) =====
QUEUE="$WORK/queue.txt"
: > "$QUEUE"
while IFS='|' read -r cid kind mode args note; do
  [ -z "$cid" ] && continue
  echo "$cid|$kind|$mode|$args|$note" >> "$QUEUE"
done <<< "$CASE_REGISTRY"
TOTAL=$(wc -l < "$QUEUE" | tr -d ' ')
echo "queue: $TOTAL cases → $QUEUE"

# ===== 分组: 每组 NNODES 台 =====
NNODES_AVAIL=${#NODES[@]}
G=$(( NNODES_AVAIL / NNODES ))
[ "$G" -lt 1 ] && { echo "FATAL: 节点数 $NNODES_AVAIL < 组规模 $NNODES"; exit 2; }
echo "groups: $G 组 × $NNODES 台 = $((G*NNODES)) 台在用(共 $NNODES_AVAIL 台)"

# 读全部 case 到数组(round-robin 预分配, 无需 flock — macOS 无 flock)
CASES=()
while IFS= read -r line; do [ -n "$line" ] && CASES+=("$line"); done < "$QUEUE"

# 一个 group-worker: 处理预分配给本组的 case 列表(经 stdin 传入, 每行一个)
group_worker() {
  local gid="$1"; shift
  local group_nodes=("$@")
  local pods_csv; pods_csv=$(IFS=,; echo "${group_nodes[*]}")
  # 先把整个 case 列表读进数组, 避免内层命令(kubectl/bash)吞掉 stdin
  local mylist=() line
  while IFS= read -r line; do [ -n "$line" ] && mylist+=("$line"); done
  for line in "${mylist[@]}"; do
    IFS='|' read -r cid kind mode args note <<< "$line"
    local glog="$WORK/${cid}.g${gid}.log"
    echo "[$(date +%H:%M:%S)] grp$gid ← $cid ($kind/$mode) $note"
    if [ "$kind" = "internal" ] || [ "$kind" = "mccl" ]; then
      # 本轮占位: 训练内注入/mccl shim 待单独实现, 先只跑 C0/C2 对照采检测端
      echo "  (placeholder inject=$kind, 跑 C0/C2 对照)" > "$glog"
      CASE="$cid" INJECT_KIND=none INJECT_ARGS="$args" GROUP_ID="$gid" \
        PODS="$pods_csv" NNODES="$NNODES" NPROC="$NPROC" ROUNDS="$ROUNDS" MODE="$mode" \
        CONFIGS_ONLY="C0_baseline,C2_probing" \
        CODE_DIR="${CODE_DIR:-$AFS_RUN_DIR/code}" LOCAL_FS="${LOCAL_FS:-0}" \
        AFS_RUN_DIR="$AFS_RUN_DIR" KUBECONFIG="$KC" \
        bash "$HERE/run_case_pipeline_v4.sh" >>"$glog" 2>&1 </dev/null || echo "  grp$gid $cid ERR"
    else
      CASE="$cid" INJECT_KIND="$kind" INJECT_ARGS="$args" GROUP_ID="$gid" \
        PODS="$pods_csv" NNODES="$NNODES" NPROC="$NPROC" ROUNDS="$ROUNDS" MODE="$mode" \
        CONFIGS_ONLY="$SWEEP_CONFIGS" \
        CODE_DIR="${CODE_DIR:-$AFS_RUN_DIR/code}" LOCAL_FS="${LOCAL_FS:-0}" \
        AFS_RUN_DIR="$AFS_RUN_DIR" KUBECONFIG="$KC" \
        bash "$HERE/run_case_pipeline_v4.sh" >"$glog" 2>&1 </dev/null || echo "  grp$gid $cid ERR"
    fi
    # 写完成 marker(供回拉判定); LOCAL_FS 时落各 pod 本地, 否则 AFS
    kubectl --kubeconfig="$KC" -n default exec "${group_nodes[0]}" -- \
      bash -c "touch '$AFS_RUN_DIR/$cid/.case_done'" </dev/null 2>/dev/null || true
    echo "[$(date +%H:%M:%S)] grp$gid ✓ $cid"
  done
  echo "[$(date +%H:%M:%S)] grp$gid drained"
}

# ===== round-robin 预分配 case 给 G 组, 各组并行处理自己的列表 =====
echo "═══ sweep 阶段: $G 组并行, round-robin 预分配 $TOTAL case ═══"
pids=()
for ((g=0; g<G; g++)); do
  slice=("${NODES[@]:$((g*NNODES)):$NNODES}")
  # 本组的 case: 索引 g, g+G, g+2G, ...
  group_list=""
  for ((idx=g; idx<${#CASES[@]}; idx+=G)); do
    group_list+="${CASES[$idx]}"$'\n'
  done
  n_assigned=$(printf '%s' "$group_list" | grep -c . || echo 0)
  echo "  grp$g (${slice[*]}) ← $n_assigned case"
  printf '%s' "$group_list" | group_worker "$g" "${slice[@]}" &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p"; done

echo "═══ sweep 完成 ═══"
echo "结果在各 pod 本地/AFS: $AFS_RUN_DIR/<case>/  → 回拉见 pull_campaign_results.sh"
