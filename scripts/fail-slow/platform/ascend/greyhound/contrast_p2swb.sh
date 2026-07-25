#!/usr/bin/env bash
# P2-SW-B Loud contrast on yysong-worker-1: HCCL algo/buff clamp + Greyhound collect-min.
# Frozen dose (dose_recipes calibrated):
#   algo=ring,stress_mb=512,buffsize=8
# C0/C1 both open HCCL_STRESS_MB; only C1 clamps HCCL_ALGO+HCCL_BUFFSIZE.
# Main evidence = comm_ms (Probing gold C1/C0_comm=1.82; step≈1.13 not FAIL).
# Verdict: collect_seq 真实 per-rank + Rbeast + C0 假阳性对照（不改对手阈值）。
# Do NOT inherit hold-job MASTER_ADDR (often yysong-master-0.yysong).
set -euo pipefail

SO="${SO:-/data/yinjinrun.p-huawei/probe-bundle/greyhound/libhcclprobe.so}"
STUB="${STUB:-/data/yinjinrun.p-huawei/opt/rbeast-fix/libbuiltin_readcyclecounter.so}"
TBP="${TBP:-/data/yinjinrun.p-huawei/probe-bundle/train_bench_probe_npu.py}"
TS="$(date +%Y%m%d_%H%M%S)"
RUN="${RUN:-contrast-p2-sw-b-${TS}}"
DUMP_ROOT="${DUMP_ROOT:-/data/yinjinrun.p-huawei/results/ascend-ais/baseline/greyhound/$RUN}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
INJECT_START="${INJECT_START:-100}"
INJECT_STOP="${INJECT_STOP:-300}"
DOSE_ALGO="${HCCL_ALGO_V:-ring}"
DOSE_STRESS_MB="${HCCL_STRESS_MB:-512}"
DOSE_BUFFSIZE="${HCCL_BUFFSIZE_V:-8}"
MASTER_PORT_C0="${MASTER_PORT_C0:-30400}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30401}"
# 单 pod 对照：强制本机环回，禁止继承 hold-job MASTER_ADDR=yysong-master-0
MASTER_ADDR="${MASTER_ADDR:-127.0.0.1}"
CASE_REF="${CASE_REF:-20260725_122911-yjr-as-c-p2-sw-b-loud}"
ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"

source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
# Ascend/driver：kubectl exec 非 login 时常缺 LD；与 run_s1s2_worker1 对齐
set +u
for f in \
  /usr/local/Ascend/ascend-toolkit/set_env.sh \
  /usr/local/Ascend/cann-8.5.0/set_env.sh \
  /usr/local/Ascend/nnal/atb/set_env.sh
do
  [[ -f "$f" ]] && source "$f" || true
done
set -u
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=${HOST_BOUND_MATMUL:-768}
export CKPT_DIR="${CKPT_DIR:-/data/yinjinrun.p-huawei/probe-bundle/ckpt}"
export PROBING=0
export LD_LIBRARY_PATH="/tmp/stress_bundle:/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64:/usr/local/Ascend/driver/lib64/driver:/usr/local/Ascend/driver/lib64:${LD_LIBRARY_PATH:-}"
unset PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true

# 若外部误传 master DNS，强制改回本机
if [[ "$MASTER_ADDR" == *master* || "$MASTER_ADDR" == *yysong-master* ]]; then
  MASTER_ADDR=127.0.0.1
fi

test -f "$SO" || { echo "missing $SO"; exit 2; }
test -f "$STUB" || { echo "missing cyclecounter stub $STUB"; exit 2; }
test -f "$TBP" || { echo "missing $TBP"; exit 2; }

# only kill OUR leftovers on worker-1
pkill -9 -x stress-ng 2>/dev/null || true
pkill -9 -f '[t]bp_npu.py' 2>/dev/null || true
pkill -9 -f '[t]orchrun.*tbp_npu' 2>/dev/null || true
sleep 1

mkdir -p "$DUMP_ROOT" "$CKPT_DIR"

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN algo=${DOSE_ALGO} stress_mb=${DOSE_STRESS_MB} buffsize=${DOSE_BUFFSIZE}"
echo "$RUN" > /tmp/gh_p2swb_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p2swb_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P2-SW-B
dose: loud
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: yysong-worker-1
pool: pool-gh
mode: gpu_bound
inject_kind: hccl_algo
inject_args: "algo=${DOSE_ALGO},stress_mb=${DOSE_STRESS_MB},buffsize=${DOSE_BUFFSIZE}"
inject_window_measure: [${INJECT_START}, ${INJECT_STOP}]
host_bound_matmul: 768
seed: 42
iters: $ITERS
warmup: $WARMUP
tool: Greyhound
label_prefix: yjr-as-b-gh
preload: ${STUB}:${SO}
redis: 127.0.0.1:16379
fairness: collect_seq_real_per_rank + C0_fp_control
script: platform/ascend/greyhound/contrast_p2swb.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
dose_note: "主证 comm_ms（金标 C1/C0_comm=1.82）；step≈1.13 不 FAIL；dose_check 优先 comm"
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
        INLINE_2A_CHUNKS INLINE_2A_STALL_MB INLINE_2A_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_GC_EVERY INLINE_GC_STALL_S \
        RARE_SHAPE_SEQ RARE_SHAPE_EVERY RARE_SHAPE_FRAC \
        HCCL_ALGO HCCL_BUFFSIZE 2>/dev/null || true
  # Both arms: large AllReduce stress. Only C1: clamp HCCL_ALGO + buffsize.
  export HCCL_STRESS_MB="$DOSE_STRESS_MB"
  if [[ "$do_inject" == "1" ]]; then
    export HCCL_ALGO="level0:NA;level1:${DOSE_ALGO}"
    export HCCL_BUFFSIZE="$DOSE_BUFFSIZE"
  fi

  echo "========== $arm port=$port inject=$do_inject algo=${DOSE_ALGO} stress_mb=${DOSE_STRESS_MB} buffsize=${DOSE_BUFFSIZE} =========="
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
        echo "  measure step ${INJECT_START} (${e}s) — hccl_algo clamp active from process start"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
    {
      echo "INLINE_INJECT kind=hccl_algo"
      echo "SIDECAR_START kind=hccl_algo"
      echo "HCCL_ALGO=level0:NA;level1=${DOSE_ALGO}"
      echo "HCCL_STRESS_MB=${DOSE_STRESS_MB}"
      echo "HCCL_BUFFSIZE=${DOSE_BUFFSIZE}"
    } >"$out/injection.log"
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
DOSE_DESC="hccl_algo algo=${DOSE_ALGO} stress_mb=${DOSE_STRESS_MB} buffsize=${DOSE_BUFFSIZE}; window [${INJECT_START},${INJECT_STOP}]"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P2-SW-B \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod yysong-worker-1 \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"

# Primary dose_check = comm_ms (step weak rise must not solely fail dose)
COMM_PY="${COMM_PY:-$SCRIPT_DIR/dose_check_comm_p2swb.py}"
if [[ -f "$COMM_PY" ]]; then
  /root/miniconda3/envs/llm_test/bin/python3 "$COMM_PY" \
    --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
    --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
    --window-start "$INJECT_START" \
    --window-stop "$INJECT_STOP" \
    --accept-min-ratio "$ACCEPT_MIN_RATIO" \
    --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json" \
    --verdict "$DUMP_ROOT/CONTRAST_VERDICT.md" || true
fi

echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
