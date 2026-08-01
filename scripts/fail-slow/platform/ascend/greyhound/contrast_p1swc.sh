#!/usr/bin/env bash
# P1-SW-C contrast: INLINE 2c compile spike + Greyhound collect-min.
# dose=loud (default): n=1024,every=1,fallback_s=0.25；thr=1.3；金标 tip max≈4.63
# dose=quiet:          n=768,every=4,fallback_s=0.1；thr=1.15；金标 tip max≈2.61（Loud 冻结规则只复测）
# dose=masked:         n=768,every=4,fallback_s=0.05；thr=1.05；金标 tip max≈2.61（formal@025116）
# Window [100,300]; mode=gpu_bound; victim local_rank=7.
# Tip narrative: median 常盲；dose_check 以 tip/max 对齐金标，勿只看 median.
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
  RUN="${RUN:-contrast-p1-sw-c-quiet-${TS}}"
  DOSE_N="${INLINE_2C_N:-768}"
  DOSE_EVERY="${INLINE_2C_EVERY:-4}"
  DOSE_FALLBACK_S="${INLINE_2C_FALLBACK_S:-0.1}"
  CASE_REF="${CASE_REF:-20260726_021606-yjr-as-c-p1-sw-c-quiet}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.15}"
  GOLD_TIP_MAX="${GOLD_TIP_MAX:-2.61}"
elif [[ "$DOSE" == "masked" ]]; then
  RUN="${RUN:-contrast-p1-sw-c-masked-${TS}}"
  DOSE_N="${INLINE_2C_N:-768}"
  DOSE_EVERY="${INLINE_2C_EVERY:-4}"
  DOSE_FALLBACK_S="${INLINE_2C_FALLBACK_S:-0.05}"
  CASE_REF="${CASE_REF:-20260726_025116-yjr-as-c-p1-sw-c-masked}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.05}"
  GOLD_TIP_MAX="${GOLD_TIP_MAX:-2.61}"
else
  RUN="${RUN:-contrast-p1-sw-c-${TS}}"
  DOSE_N="${INLINE_2C_N:-1024}"
  DOSE_EVERY="${INLINE_2C_EVERY:-1}"
  DOSE_FALLBACK_S="${INLINE_2C_FALLBACK_S:-0.25}"
  CASE_REF="${CASE_REF:-20260725_121105-yjr-as-c-p1-sw-c-loud}"
  ACCEPT_MIN_RATIO="${ACCEPT_MIN_RATIO:-1.3}"
  GOLD_TIP_MAX="${GOLD_TIP_MAX:-4.63}"
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
# Keep DOSE_* immutable for set -u; only export INLINE_2C_* on C1.
INLINE_2C_N="$DOSE_N"
INLINE_2C_EVERY="$DOSE_EVERY"
INLINE_2C_FALLBACK_S="$DOSE_FALLBACK_S"
MASTER_PORT_C0="${MASTER_PORT_C0:-30390}"
MASTER_PORT_C1="${MASTER_PORT_C1:-30391}"
MASTER_ADDR="${MASTER_ADDR:-}"

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

echo "MASTER_ADDR=$MASTER_ADDR NPROC=$NPROC RUN=$RUN dose=${DOSE} pod=${HOLD_POD} 2c n=${DOSE_N} every=${DOSE_EVERY} fallback_s=${DOSE_FALLBACK_S}"
echo "$RUN" > /tmp/gh_p1swc_run.txt
echo "$DUMP_ROOT" > /tmp/gh_p1swc_dump.txt

# ensure redis
if ! /data/yinjinrun.p-huawei/opt/redis/bin/redis-cli -h 127.0.0.1 -p 16379 ping 2>/dev/null | grep -q PONG; then
  bash /data/yinjinrun.p-huawei/probe-bundle/greyhound/greyhound-src/start_redis.sh || true
fi

cat >"$DUMP_ROOT/manifest.yaml" <<EOF
case_id: P1-SW-C
dose: ${DOSE}
phase: contrast
run_id: $RUN
case_ref: $CASE_REF
world_size: $NPROC
pod: ${HOLD_POD}
pool: pool-gh
mode: gpu_bound
inject_kind: inline_2c
inject_args: "n=${DOSE_N},every=${DOSE_EVERY},fallback_s=${DOSE_FALLBACK_S}"
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
script: platform/ascend/greyhound/contrast_p1swc.sh
accept_min_ratio: ${ACCEPT_MIN_RATIO}
gold_tip_max: ${GOLD_TIP_MAX}
tip_note: "Probing tip max=${GOLD_TIP_MAX} median blind; dose_check must use tip/max (not median alone)"
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
        INLINE_2A_CHUNKS INLINE_2A_STALL_MB INLINE_2A_STALL_S INLINE_HBM_MB INLINE_HBM_COPIES \
        INLINE_CUBE_SIZE INLINE_CUBE_MM INLINE_GC_EVERY INLINE_GC_STALL_S \
        RARE_SHAPE_SEQ RARE_SHAPE_EVERY RARE_SHAPE_FRAC \
        INLINE_2C_N INLINE_2C_EVERY INLINE_2C_FALLBACK_S 2>/dev/null || true
  if [[ "$do_inject" == "1" ]]; then
    export INLINE_INJECT=2c
    export INLINE_VICTIM_LOCAL_RANK="$VICTIM_LOCAL"
    export INLINE_INJECT_START="$INJECT_START"
    export INLINE_INJECT_STOP="$INJECT_STOP"
    export INLINE_2C_N="$DOSE_N"
    export INLINE_2C_EVERY="$DOSE_EVERY"
    export INLINE_2C_FALLBACK_S="$DOSE_FALLBACK_S"
  fi

  echo "========== $arm port=$port inject=$do_inject 2c n=${DOSE_N} every=${DOSE_EVERY} fallback_s=${DOSE_FALLBACK_S} =========="
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
        echo "  measure step ${INJECT_START} (${e}s) — inline 2c compile spike active"
        break
      fi
      if [[ -f "$out/node_0.fail" ]]; then echo "FAIL before inject"; tail -80 "$out/node_0.log"; return 1; fi
      if [[ -f "$out/node_0.done" ]]; then echo "FAIL train ended before inject start"; return 1; fi
      sleep 1; e=$((e + 1))
    done
    if [[ ! -f "$out/ranks/step_${INJECT_START}.marker" ]]; then
      echo "FAIL never reached inject start"; return 1
    fi
    grep -E "INLINE_2C|SIDECAR|SPIKE_OK" "$out/node_0.log" 2>/dev/null | head -40 >"$out/injection.log" || true
    echo "SIDECAR_START kind=inline_2c n=${DOSE_N} every=${DOSE_EVERY} fallback_s=${DOSE_FALLBACK_S} victim=${VICTIM_LOCAL}" >>"$out/injection.log"
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
DOSE_DESC="INLINE 2c n=${DOSE_N} every=${DOSE_EVERY} fallback_s=${DOSE_FALLBACK_S} victim=${VICTIM_LOCAL}; window [${INJECT_START},${INJECT_STOP}]; gold tip max≈${GOLD_TIP_MAX}"
LD_PRELOAD="${STUB}${LD_PRELOAD:+:$LD_PRELOAD}" \
  /root/miniconda3/envs/llm_test/bin/python3 "$SCRIPT_DIR/s4_verdict.py" \
  --dump-root "$DUMP_ROOT" \
  --inject-start "$INJECT_START" \
  --inject-stop "$INJECT_STOP" \
  --accept-min-ratio "$ACCEPT_MIN_RATIO" \
  --case-id P1-SW-C \
  --case-ref "$CASE_REF" \
  --dose-desc "$DOSE_DESC" \
  --dose "$DOSE" \
  --tool greyhound \
  --run-id "$RUN" \
  --pod "$HOLD_POD" \
  --out "$DUMP_ROOT/CONTRAST_VERDICT.md" \
  --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json"

# Tip / max dose_check appendix (P1-SW-C: median often blind; align gold tip max)
TIP_PY="${TIP_PY:-$SCRIPT_DIR/tip_dose_check_p1swc.py}"
if [[ -f "$TIP_PY" ]]; then
  /root/miniconda3/envs/llm_test/bin/python3 "$TIP_PY" \
    --ranks-c0 "$DUMP_ROOT/C0_baseline/ranks" \
    --ranks-c1 "$DUMP_ROOT/C1_inject_none/ranks" \
    --victim-local "$VICTIM_LOCAL" \
    --window-start "$INJECT_START" \
    --window-stop "$INJECT_STOP" \
    --accept-min-max-ratio 2.5 \
    --accept-min-med-ratio "$ACCEPT_MIN_RATIO" \
    --gold-tip-max "${GOLD_TIP_MAX:-4.63}" \
    --summary "$DUMP_ROOT/CONTRAST_SUMMARY.json" \
    --verdict "$DUMP_ROOT/CONTRAST_VERDICT.md" || true
fi

echo "CONTRAST_DONE RUN=$RUN DUMP=$DUMP_ROOT"
