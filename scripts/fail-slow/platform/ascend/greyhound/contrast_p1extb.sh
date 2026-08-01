#!/usr/bin/env bash
# P1-EXT-B contrast: INLINE HBM + Greyhound collect-min.
# dose=loud (default): mb=512,copies=48；thr=1.6；金标≈2.02
# dose=quiet:          mb=256,copies=16；thr=1.15；金标≈1.161（Loud 冻结规则只复测）
# dose=masked:         mb=192,copies=10；thr=1.05；金标≈1.070（Loud 冻结规则只复测）
# Window [100,300]; mode=gpu_bound; victim local_rank=7.
# LD_PRELOAD = cyclecounter stub : libhcclprobe.so
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Hold pod 默认今晚 GH 池 yysong-worker-2（勿用 master / grj）。
set -euo pipefail

DOSE="${DOSE:-loud}"
HOLD_POD="${HOLD_POD:-yysong-worker-2}"
SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
if [[ "$DOSE" == "quiet" ]]; then
  RUN="${RUN:-contrast-p1-ext-b-quiet-${TS}}"
  HBM_MB="${HBM_MB:-256}"
  HBM_COPIES="${HBM_COPIES:-16}"
  CASE_REF="${CASE_REF:-20260726_033758-yjr-as-c-p1-ext-b-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.161}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30390}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30391}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p1-ext-b-masked-${TS}}"
  HBM_MB="${HBM_MB:-192}"
  HBM_COPIES="${HBM_COPIES:-10}"
  CASE_REF="${CASE_REF:-20260726_040309-yjr-as-c-p1-ext-b-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-1.070}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30392}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30393}"
else
  RUN="${RUN:-contrast-p1-ext-b-${TS}}"
  HBM_MB="${HBM_MB:-512}"
  HBM_COPIES="${HBM_COPIES:-48}"
  CASE_REF="${CASE_REF:-20260725_014350-yjr-as-c-p1-ext-b-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.6}"
  GOLD_STEP_RATIO="${GOLD_STEP_RATIO:-2.02}"
  MASTER_PORT_C0="${MASTER_PORT_C0:-30390}"
  MASTER_PORT_C1="${MASTER_PORT_C1:-30391}"
fi
# Prefer AFS results when writable (hold pod may lack /data write); fallback /data
if [[ -z "${DUMP_ROOT:-}" ]]; then
  if [[ -d /afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais ]]; then
    DUMP_ROOT="/afs-a3-weight-share/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN"
  else
    DUMP_ROOT="/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN"
  fi
fi
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
VICTIM_LOCAL="${VICTIM_LOCAL:-7}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30390}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30391}"
MASTER_ADDR="${MASTER_ADDR:-}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

# Volcano 壳常注入 MASTER_ADDR=yysong-master-0；单 pod 对照必须用本机 / 127.0.0.1
if [[ -z "${MASTER_ADDR:-}" || "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=$(ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  MASTER_ADDR=${MASTER_ADDR:-127.0.0.1}
fi
# 硬约束：Loop 要求 MASTER_ADDR=127.0.0.1（单机 16 卡）
MASTER_ADDR="${FORCE_MASTER_ADDR:-127.0.0.1}"

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }

# only kill OUR leftovers on this hold pod
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
pkill -9 -f '[t]rain_bench_probe_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"
echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD} hbm=${HBM_MB}MB×${HBM_COPIES}"
echo "$RUN" > /tmp/gh_p1extb_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p1extb_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P1-EXT-B
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-gh
mode: gpu_bound
inject_kind: inline_hbm
inject_args: "inline_hbm_mb=${HBM_MB},inline_hbm_copies=${HBM_COPIES}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
victim_local_rank: ${VICTIM_LOCAL}
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: Greyhound
label_prefix: yjr-as-b-gh
preload: ${STUB}:${SO}
redis: 127.0.0.1:16379
fairness: collect_seq_real_per_rank + C0_fp_control
script: platform/ascend/greyhound/contrast_p1extb.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_step_ratio: ${GOLD_STEP_RATIO}
master_addr: ${MASTER_ADDR}
EOF

run_arm() {
  local arm="$1" port="$2" do_inject="$3"
  local out="$DUMP_ROOT/$arm"
  mkdir -p "$out/ranks" "$out/greyhound"
  export GREYHOUND_DUMP="$out/greyhound/hcclprobe.collect.jsonl"
  export GREYHOUND_STUB_MARKER="$out/greyhound/hcclprobe.loaded"
  export GREYHOUND_DEBUG=1
  export GREYHOUND_HCCL_SO=/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64/libhccl.so
  : >"$GREYHOUND_DUMP"

  unset INLINE_INJECT INLINE_VICTIM_LOCAL_RANK INLINE_INJECT_START INLINE_INJECT_STOP \
        INLINE_HBM_MB INLINE_HBM_COPIES INLINE_CUBE_SIZE INLINE_CUBE_MM 2>/dev/null || true
  if [[ "$do_inject" == "1" ]]; then
    export INLINE_INJECT=hbm
    export INLINE_VICTIM_LOCAL_RANK="$VICTIM_LOCAL"
    export INLINE_INJECT_START="$INJECT_START"
    export INLINE_INJECT_STOP="$INJECT_STOP"
    export INLINE_HBM_MB="$HBM_MB"
    export INLINE_HBM_COPIES="$HBM_COPIES"
  fi

  echo "========== $arm port=$port inject=$do_inject hbm=${HBM_MB}MB×${HBM_COPIES} =========="
  rm -f "$out/node_0.done" "$out/node_0.fail" "$out/ranks"/step_*.marker "$out/ranks"/warmup_done
  rm -f "$out/ranks"/rank_*.jsonl
  (
    LD_PRELOAD="${STUB}:${SO}${LD_PRELOAD:+:$LD_PRELOAD}" \
    /root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node="$NPROC" --node_rank=0 \
      --master_addr="$MASTER_ADDR" --master_port="$port" \
      "$TBP" --iters="$ITERS" --warmup="$WARMUP" --seed=42 --mode=gpu_bound \
      --model=gpt2 --seq=1024 --batch=8 --flush-every=5 --ckpt-every=100 \
      --run-id="$RUN" --group="$arm" --config="$arm" --round=1 \
      --out-dir="$out/ranks" >"$out/node_0.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then touch "$out/node_0.done"; else echo $rc >"$out/node_0.fail"; fi
  ) &
  local train_pid=$!

  local e=0
  while [[ $e -lt 360 ]]; do
    if [[ -f "$out/ranks/warmup_done" || -f "$out/ranks/step_1.marker" || -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "  warmup ok (${e}s)"; break
    fi
    if [[ -f "$out/node_0.fail" ]]; then echo "FAIL warmup"; tail -80 "$out/node_0.log"; return 1; fi
    if [[ -f "$out/node_0.done" ]]; then echo "  train finished during warmup wait"; break; fi
    sleep 1; e=$((e + 1))
  done
  if [[ ! -f "$out/ranks/warmup_done" && ! -f "$out/ranks/step_1.marker" && ! -f "$out/ranks/step_${INJECT_START}.marker" && ! -f "$out/node_0.done" ]]; then
    echo "FAIL warmup timeout"; tail -80 "$out/node_0.log"; return 1
  fi

  if [[ "$do_inject" == "1" ]]; then
    e=0
    while [[ $e -lt 2400 ]]; do
      if [[ -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
        echo "  measure step ${INJECT_START} (${e}s) — inline hbm active"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
    grep -E "INLINE_HBM|SIDECAR" "$out/node_0.log" 2>/dev/null | head -20 >"$out/injection.log" || true
    echo "SIDECAR_START kind=inline_hbm mb=${HBM_MB} copies=${HBM_COPIES} victim=${VICTIM_LOCAL}" >>"$out/injection.log"
    PHYS=$(echo "${ASCEND_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15}" | cut -d, -f$((VICTIM_LOCAL+1)))
    npu-smi info -t usages -i "${PHYS:-0}" 2>/dev/null | head -40 >"$out/npu_smi_util_inject.txt" \
      || npu-smi info 2>/dev/null | head -80 >"$out/npu_smi_util_inject.txt" || true
  fi

  e=0
  while [[ $e -lt 2400 ]]; do
    if [[ -f "$out/node_0.done" ]]; then
      echo "  done (${e}s) dump_lines=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')"
      wait "$train_pid" || true
      return 0
    fi
    if [[ -f "$out/node_0.fail" ]]; then
      echo "  FAIL"; tail -100 "$out/node_0.log" || true
      wait "$train_pid" || true
      return 1
    fi
    sleep 5; e=$((e + 5))
    if (( e % 30 == 0 )); then
      echo "  waiting… t=${e}s dump=$(wc -l <"$GREYHOUND_DUMP" 2>/dev/null | tr -d ' ')"
    fi
  done
  echo "TIMEOUT"; tail -80 "$out/node_0.log" || true
  kill "$train_pid" 2>/dev/null || true
  return 1
}

run_arm C0_baseline "$MASTER_PORT_C0" 0
run_arm C1_inject_none "$MASTER_PORT_C1" 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="/data/yinjinrun.p-huawei/opt/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export GREYHOUND_RBEAST_STUB="${STUB}"
DOSE_DESC="INLINE hbm mb=${HBM_MB} copies=${HBM_COPIES} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]; gold≈${GOLD_STEP_RATIO}"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P1-EXT-B \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --dose "$DOSE" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod "$HOLD_POD" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"
echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
