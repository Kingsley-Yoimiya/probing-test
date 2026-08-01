#!/usr/bin/env bash
# P2-EXT-A：C0=无注入；C1=邻居 RoCE 持续打流（OUTLINE 6A）
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(cd "$HERE/../.." && pwd)"

CASE_ID="${CASE_ID:?need CASE_ID}"
RUN_ID="${RUN_ID:?need RUN_ID}"
PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
NNODES="${NNODES:-8}"
NPROC="${NPROC:-8}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
ROUNDS="${ROUNDS:-1}"
SEED="${SEED:-42}"
MODEL="${MODEL:-gpt2}"
MODE="${MODE:-gpu_bound}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/Users/yinjinrun/Codespace/myportal/results/muxi-mohe/$RUN_ID}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
ACCEPT_SCRIPT="${ACCEPT_SCRIPT:-$PARENT/accept_loud.py}"
NEIGHBOR_POD="${NEIGHBOR_POD:-yjr-fs-h14410}"
CASE="P2-EXT-A"
INJECT_KIND="none"

export ITERS WARMUP

run_pipeline() {
  local config="$1" group_id="$2"
  echo "========== $CASE / $config (GROUP_ID=$group_id) =========="
  CASE="$CASE" INJECT_KIND="none" INJECT_ARGS="" \
    RUN_ID="$RUN_ID" RUN_DIR="$LOCAL_OUT" LOCAL_CODE="$LOCAL_CODE" LOCAL_OUT="$LOCAL_OUT" \
    PODS="$PODS" NNODES="$NNODES" NPROC="$NPROC" ITERS="$ITERS" WARMUP="$WARMUP" \
    ROUNDS="$ROUNDS" SEED="$SEED" MODEL="$MODEL" MODE="$MODE" LOCAL_FS=1 \
    GROUP_ID="$group_id" CONFIGS_ONLY="$config" KUBECONFIG="$KUBECONFIG" NS="$NS" \
    SIDECAR_WARMUP=8 \
    bash "$PARENT/run_case_pipeline_v4.sh"
}

pull_results() {
  IFS=',' read -r -a POD_ARRAY <<< "$PODS"
  DEST="$LOCAL_RESULT_ROOT/$CASE"
  mkdir -p "$DEST/by_pod"
  for pod in "${POD_ARRAY[@]}"; do
    pod_dest="$DEST/by_pod/$pod"
    mkdir -p "$pod_dest"
    echo "↓ $pod:$LOCAL_OUT/$CASE → $pod_dest"
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$pod" -- \
      bash -c "tar -C '$LOCAL_OUT/$CASE' -cf - ." > "$pod_dest/.pull.tar" || true
    tar -C "$pod_dest" -xf "$pod_dest/.pull.tar" 2>/dev/null || true
    rm -f "$pod_dest/.pull.tar"
  done
}

accept_both() {
  # step_ms（accept_loud）+ comm_ms 手算；P2 主证偏 comm
  python3 "$ACCEPT_SCRIPT" \
    --result-root "$LOCAL_RESULT_ROOT" \
    --case "$CASE" \
    --min-ratio "$ACCEPT_MIN_RATIO" \
    --configs C0_baseline,C1_inject_none \
    --write-md "$LOCAL_RESULT_ROOT/acceptance_${CASE}_step.md" || true
  python3 - <<PY
import json, statistics
from pathlib import Path
root = Path("$LOCAL_RESULT_ROOT") / "$CASE"
lo, hi = 100, 300

def med(cfg, key):
    hits = sorted(root.glob(f"by_pod/*/round_1/{cfg}/ranks/rank_0000.jsonl"))
    if not hits:
        return None
    xs=[]
    for line in hits[0].open():
        line=line.strip()
        if not line: continue
        o=json.loads(line)
        s=o.get("step")
        if s is None or not (lo <= int(s) <= hi): continue
        if key in o: xs.append(float(o[key]))
    return statistics.median(xs) if xs else None

rows=[]
for key in ("step_ms","comm_ms"):
    c0,c1=med("C0_baseline",key), med("C1_inject_none",key)
    ratio=(c1/c0) if (c0 and c1 and c0>0) else None
    rows.append((key,c0,c1,ratio))
    print(f"{key}: C0={c0} C1={c1} ratio={ratio}")
md=["# Acceptance P2-EXT-A (step+comm)", f"- thr≥{float('$ACCEPT_MIN_RATIO')}", ""]
md.append("| metric | C0 | C1 | C1/C0 |")
md.append("|---|---:|---:|---:|")
ok=False
for key,c0,c1,ratio in rows:
    md.append(f"| {key} | {c0} | {c1} | {ratio} |")
    if ratio is not None and ratio >= float("$ACCEPT_MIN_RATIO"):
        ok=True
verdict="PASS" if ok else "FAIL"
md.append(f"\nverdict: **{verdict}** (PASS if step OR comm ≥ thr)")
Path("$LOCAL_RESULT_ROOT/ACCEPT_LOUD.md").write_text("\n".join(md)+"\n")
Path("$LOCAL_RESULT_ROOT/BITE_VERDICT.md").write_text(verdict+"\n")
print("VERDICT", verdict)
raise SystemExit(0 if ok else 1)
PY
}

IFS=',' read -r -a RUN_CFGS <<< "${ABC_CONFIGS:-C0_baseline,C1_inject_none}"
abc_rc=0
flood_on=0
cleanup() {
  if [ "$flood_on" = "1" ]; then
    KUBECONFIG="$KUBECONFIG" NS="$NS" NEIGHBOR_POD="$NEIGHBOR_POD" \
      bash "$HERE/neighbor_flood.sh" stop || true
    flood_on=0
  fi
}
trap cleanup EXIT

for cfg in "${RUN_CFGS[@]}"; do
  case "$cfg" in
    C0_baseline) gid=0 ;;
    C1_inject_none) gid=1 ;;
    *) gid=0 ;;
  esac
  if [ "$cfg" = "C1_inject_none" ]; then
    # 注入日志落在 C1 out 目录（pipeline 创建前先占位到常见路径；pipeline 后补写）
    INJECT_LOG="$LOCAL_OUT/$CASE/round_1/C1_inject_none/injection.log"
    # 先起邻居打流，再跑训练（持续压力覆盖 warmup+measure）
    echo ">> start neighbor RoCE flood"
    KUBECONFIG="$KUBECONFIG" NS="$NS" NEIGHBOR_POD="$NEIGHBOR_POD" \
      INJECT_LOG="" \
      bash "$HERE/neighbor_flood.sh" start
    flood_on=1
    run_pipeline "$cfg" "$gid" || abc_rc=1
    # 补写 injection.log 到 master 结果目录
    master=$(echo "$PODS" | cut -d, -f1)
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$master" -- bash -c "
      mkdir -p '$LOCAL_OUT/$CASE/round_1/C1_inject_none'
      {
        echo 'SIDECAR_WARMUP kind=2ext_neighbor'
        echo 'SIDECAR_START kind=2ext_neighbor neighbor=$NEIGHBOR_POD'
        echo 'SIDECAR_2EXT_START ib_write_bw RoCEv2 continuous flood qp=4 size=1MiB links=4'
      } > '$LOCAL_OUT/$CASE/round_1/C1_inject_none/injection.log'
    " || true
    KUBECONFIG="$KUBECONFIG" NS="$NS" NEIGHBOR_POD="$NEIGHBOR_POD" \
      bash "$HERE/neighbor_flood.sh" stop || true
    flood_on=0
  else
    run_pipeline "$cfg" "$gid" || abc_rc=1
  fi
done

pull_results
accept_both || abc_rc=1
exit "$abc_rc"
