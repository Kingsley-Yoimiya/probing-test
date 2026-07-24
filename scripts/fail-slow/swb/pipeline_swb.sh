#!/usr/bin/env bash
# pipeline_swb.sh — SW-B 隔离 pipeline（fork of run_case_pipeline_v4.sh）
#
# 相对 v4 增量:
#   - 训练脚本: train_bench_swb.py → /tmp/tbp.py
#   - LOCAL_CODE 默认 /workspace/probe-bundle/swb（与其它 agent 的 probe-bundle 隔离）
#   - INJECT_KIND=mccl_algo：无 sidecar；向 denv 注入 MCCL_ALGO/PROTO/MIN|MAX_NCHANNELS
#   - INJECT_KIND=rare_shape|2b：无 sidecar；INLINE_INJECT=2b + RARE_SHAPE_*
#   - INJECT_KIND=none：C0 路径
#   - C3/C4/C5 denv stub 保留
#
# 用法(env 驱动):
#   CASE=P2-SW-B INJECT_KIND=mccl_algo INJECT_ARGS="algo=Ring,proto=Simple,min_ch=4,max_ch=4" \
#   PODS="..." NNODES=8 NPROC=8 \
#   LOCAL_CODE=/workspace/probe-bundle/swb \
#   bash pipeline_swb.sh
set -uo pipefail

# ===== 参数 =====
CASE="${CASE:?need CASE}"
INJECT_KIND="${INJECT_KIND:?need INJECT_KIND (mccl_algo|rare_shape|2b|cube|hbm|8a|none|...)}"
INJECT_ARGS="${INJECT_ARGS:-}"
GROUP_ID="${GROUP_ID:-0}"
IFS=',' read -r -a PODS <<< "${PODS:?need PODS csv}"
NNODES="${NNODES:-8}"
NPROC="${NPROC:-8}"
ROUNDS="${ROUNDS:-3}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
SEED="${SEED:-42}"
MODE="${MODE:-gpu_bound}"
MODEL="${MODEL:-gpt2}"
SEQ="${SEQ:-1024}"
BATCH="${BATCH:-8}"
FREQ_LEVEL="${FREQ_LEVEL:-4}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle/swb}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/swb/out}"
RUN_DIR="${RUN_DIR:-${AFS_RUN_DIR:-$LOCAL_OUT}}"
CODE_DIR="${CODE_DIR:-${LOCAL_CODE}}"
RUN_ID="${RUN_ID:-$(basename "$RUN_DIR")}"
LOCAL_FS="${LOCAL_FS:-1}"
NS="${NS:-default}"
PROBING_SPEC="${PROBING_SPEC:-}"
SIDECAR_LOCAL_RANK="${SIDECAR_LOCAL_RANK:-$((NPROC-1))}"
SIDECAR_WARMUP="${SIDECAR_WARMUP:-8}"
INJECT_START_MEASURE_STEP="${INJECT_START_MEASURE_STEP:-100}"
INJECT_STOP_MEASURE_STEP="${INJECT_STOP_MEASURE_STEP:-300}"
IO_STRESS_DIR="${IO_STRESS_DIR:-/workspace/probe-bundle/swb/io_stress}"
CKPT_DIR="${CKPT_DIR:-/workspace/probe-bundle/swb/ckpt}"

HERE_SWB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE_PARENT="$(cd "$HERE_SWB/.." && pwd)"

# POD_EXEC 抽象: 默认 kubectl(raw pod); 设 USE_VCCTL=1 切 vcctl(vcjob pod)
if [ "${USE_VCCTL:-0}" = "1" ]; then
  VCCTL="${VCCTL:-/usr/local/bin/vcctl}"
  pexec()   { "$VCCTL" pod exec    "$1" -- bash -c "$2"; }
  pexec_i() { "$VCCTL" pod exec -i "$1" -- bash -c "$2"; }
  pod_ip()  { "$VCCTL" pod view "$1" 2>/dev/null | grep -oE 'IP[: ]+[0-9.]+' | grep -oE '[0-9.]+' | head -1; }
else
  KC="${KUBECONFIG:?need KUBECONFIG for kubectl}"
  # Mac→API 偶发 EOF：kubectl 自带 request-timeout，避免 clean/fire 永久卡住
  pexec()   { kubectl --request-timeout=60s --kubeconfig="$KC" -n "$NS" exec    "$1" -- bash -c "$2"; }
  pexec_i() { kubectl --request-timeout=90s --kubeconfig="$KC" -n "$NS" exec -i "$1" -- bash -c "$2"; }
  pod_ip()  { kubectl --request-timeout=30s --kubeconfig="$KC" -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null; }
fi

DUTY=$(echo "$INJECT_ARGS" | grep -oE 'duty=[0-9.]+' | cut -d= -f2 || true); DUTY="${DUTY:-0.9}"
SIZE=$(echo "$INJECT_ARGS" | grep -oE 'size=[0-9]+'  | cut -d= -f2 || true); SIZE="${SIZE:-8192}"
FRAC=$(echo "$INJECT_ARGS" | grep -oE 'frac=[0-9.]+' | cut -d= -f2 || true); FRAC="${FRAC:-0.7}"
CPU_LOAD=$(echo "$INJECT_ARGS" | grep -oE 'cpu_load=[0-9.]+' | cut -d= -f2 || true); CPU_LOAD="${CPU_LOAD:-90}"
CPU_N=$(echo "$INJECT_ARGS" | grep -oE 'cpu_n=[0-9]+' | cut -d= -f2 || true)
CPU_FRAC=$(echo "$INJECT_ARGS" | grep -oE 'cpu_frac=[0-9.]+' | cut -d= -f2 || true)
VM_N=$(echo "$INJECT_ARGS" | grep -oE 'vm_n=[0-9]+' | cut -d= -f2 || true); VM_N="${VM_N:-4}"
VM_BYTES=$(echo "$INJECT_ARGS" | grep -oE 'vm_bytes=[0-9]+[KkMmGg]?' | cut -d= -f2 || true); VM_BYTES="${VM_BYTES:-2G}"
# P2-SW-B：MCCL 算法/通道钳制（fabric 报告 Ring/Simple+ch=4 → 81.8→38.2 GB/s）
MCCL_ALGO_V=$(echo "$INJECT_ARGS" | grep -oE 'algo=[A-Za-z0-9_]+' | cut -d= -f2 || true); MCCL_ALGO_V="${MCCL_ALGO_V:-Ring}"
MCCL_PROTO_V=$(echo "$INJECT_ARGS" | grep -oE 'proto=[A-Za-z0-9_]+' | cut -d= -f2 || true); MCCL_PROTO_V="${MCCL_PROTO_V:-Simple}"
MCCL_MIN_CH=$(echo "$INJECT_ARGS" | grep -oE 'min_ch=[0-9]+' | cut -d= -f2 || true); MCCL_MIN_CH="${MCCL_MIN_CH:-4}"
MCCL_MAX_CH=$(echo "$INJECT_ARGS" | grep -oE 'max_ch=[0-9]+' | cut -d= -f2 || true); MCCL_MAX_CH="${MCCL_MAX_CH:-4}"
# P1-SW-B：rare shape
RARE_SEQ_V=$(echo "$INJECT_ARGS" | grep -oE 'rare_seq=[0-9]+' | cut -d= -f2 || true); RARE_SEQ_V="${RARE_SEQ_V:-1536}"
RARE_EVERY_V=$(echo "$INJECT_ARGS" | grep -oE 'every=[0-9]+' | cut -d= -f2 || true); RARE_EVERY_V="${RARE_EVERY_V:-1}"
RARE_FRAC_V=$(echo "$INJECT_ARGS" | grep -oE 'frac=[0-9.]+' | cut -d= -f2 || true)
echo "  inject_parse DUTY=$DUTY SIZE=$SIZE FRAC=$FRAC CPU_LOAD=$CPU_LOAD MCCL=$MCCL_ALGO_V/$MCCL_PROTO_V ch=${MCCL_MIN_CH}-${MCCL_MAX_CH} rare_seq=$RARE_SEQ_V every=$RARE_EVERY_V"

MASTER="${PODS[0]}"
MASTER_IP="$(pod_ip "$MASTER")"
[ -z "$MASTER_IP" ] && { echo "FATAL: cannot resolve master IP for $MASTER"; exit 2; }
BASE_PORT=$(( 30000 + GROUP_ID * 100 ))
OUT_BASE="$RUN_DIR/$CASE"

echo "╔══════════════════════════════════════════════╗"
echo "║ swb case=$CASE grp=$GROUP_ID inject=$INJECT_KIND mode=$MODE"
echo "║ pods=${PODS[*]} NNODES=$NNODES NPROC=$NPROC world=$((NNODES*NPROC))"
echo "║ master=$MASTER($MASTER_IP) base_port=$BASE_PORT rounds=$ROUNDS"
echo "║ iters=$ITERS warmup=$WARMUP sidecar_warmup=$SIDECAR_WARMUP victim=L$SIDECAR_LOCAL_RANK"
echo "║ code=$CODE_DIR out=$OUT_BASE local_fs=$LOCAL_FS run_id=$RUN_ID"
echo "╚══════════════════════════════════════════════╝"
if [ "$ITERS" -lt 350 ] 2>/dev/null; then
  echo "WARN: ITERS=$ITERS < 350；注入窗 [100,300] 不完整" >&2
fi

# 无 sidecar 的内联注入（与 8a/hbm inline 同路径）
is_inline_kind() {
  case "$INJECT_KIND" in
    mccl_algo|rare_shape|2b|8a|inline_8a) return 0 ;;
    hbm) [ "${USE_INLINE_HBM:-1}" = "1" ] && return 0 || return 1 ;;
    none) return 0 ;;  # 无注入动作
    *) return 1 ;;
  esac
}

# ===== helpers =====
clean_group() {
  local p0=$BASE_PORT p1=$((BASE_PORT+1)) p2=$((BASE_PORT+2))
  # 串行：并行 kubectl 遇 EOF 时 wait 可能拖死 Mac 编排
  for ((n=0; n<NNODES; n++)); do
    pexec "${PODS[$n]}" "pkill -9 -f '[t]rain_bench_swb' 2>/dev/null || true; pkill -9 -f '[t]rain_bench_probe' 2>/dev/null || true; pkill -9 -f '/tmp/[t]bp.py' 2>/dev/null || true; pkill -9 -f '[t]orchrun' 2>/dev/null || true; pkill -9 -f '[s]idecar_inject' 2>/dev/null || true; pkill -9 -x stress-ng 2>/dev/null || true; pkill -9 -f 'fio.*io_stress' 2>/dev/null || true; pkill -9 -f '[i]b_write_bw' 2>/dev/null || true; rm -rf /dev/shm/nccl* /dev/shm/mccl* /dev/shm/torch_* /dev/shm/probing /dev/shm/__KMP* 2>/dev/null || true; find /dev/shm -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; fuser -k ${p0}/tcp ${p1}/tcp ${p2}/tcp 2>/dev/null || true; exit 0" 2>/dev/null \
      || echo "  WARN: clean ${PODS[$n]}"
  done
  sleep 2
  return 0
}

freq_set() {
  pexec "$MASTER" "mount -o remount,rw /sys 2>/dev/null; for i in \$(seq 0 $((NPROC-1))); do mx-smi -i \$i --set-dpm-max xcore,$1 >/dev/null 2>&1; done; echo FREQ_SET_$1" 2>/dev/null
}
freq_restore() {
  pexec "$MASTER" "for i in \$(seq 0 $((NPROC-1))); do mx-smi -i \$i --set-dpm-max xcore,9 >/dev/null 2>&1; done; echo FREQ_RESTORED" 2>/dev/null
}

fire_training() {   # $1=port $2=out_dir $3=detect_env $4=round
  # Mac→集群 kubectl 并发易 EOF：写 launcher / 点火串行+重试，并核查 torchrun 齐了再返回
  local port="$1" out="$2" denv="$3" rnd="$4"
  local n tries pod
  write_launcher() {
    local n="$1"
    local launcher
    launcher=$(cat <<LAUNCHER
#!/usr/bin/env bash
export PATH=/opt/conda/bin:\${PATH:-/usr/bin}
export PYTHONUNBUFFERED=1
export NCCL_SOCKET_IFNAME=eth0 MCCL_SOCKET_IFNAME=eth0 GLOO_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export MCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
export NCCL_IB_GID_INDEX=5 MCCL_IB_GID_INDEX=5 MCCL_IB_TC=128
export MCCL_ENABLE_VSWITCH=1
export NCCL_DEBUG=WARN MCCL_DEBUG=WARN
export PYTHONPATH=$CODE_DIR/pydeps:\${PYTHONPATH:-}
export CKPT_DIR=$CKPT_DIR
unset PROBING PROBING_TORCH_PROFILING PROBING_GPU 2>/dev/null || true
${denv}
SP_SITE=/opt/conda/lib/python3.12/site-packages
if [ "\${PROBING:-0}" = "0" ] || [ -z "\${PROBING:-}" ]; then
  if [ -f "\$SP_SITE/probing.pth" ]; then mv -f "\$SP_SITE/probing.pth" "\$SP_SITE/probing.pth.off_c0"; fi
else
  if [ -f "\$SP_SITE/probing.pth.off_c0" ] && [ ! -f "\$SP_SITE/probing.pth" ]; then mv -f "\$SP_SITE/probing.pth.off_c0" "\$SP_SITE/probing.pth"; fi
fi
rm -f '$out/node_${n}.done' '$out/node_${n}.fail'
rm -rf '$out/ranks'
mkdir -p '$out/ranks'
cp -f '$CODE_DIR/train_bench_swb.py' /tmp/tbp.py
/opt/conda/bin/torchrun --nnodes=$NNODES --nproc_per_node=$NPROC --node_rank=$n \\
  --master_addr=$MASTER_IP --master_port=$port \\
  /tmp/tbp.py --iters=$ITERS --warmup=$WARMUP --seed=$SEED --mode=$MODE --model=$MODEL --seq=$SEQ --batch=$BATCH \\
  --flush-every=${FLUSH_EVERY:-5} --ckpt-every=${CKPT_EVERY:-100} \\
  --io-payload='${IO_PAYLOAD:-}' --io-read-kb=${IO_READ_KB:-0} \\
  --run-id=$RUN_ID --group=$GROUP_ID --config='$(basename "$out")' --round=$rnd \\
  --out-dir='$out/ranks' > '$out/node_${n}.log' 2>&1
rc=\$?
if [ \$rc -eq 0 ]; then touch '$out/node_${n}.done'; else echo \$rc > '$out/node_${n}.fail'; fi
LAUNCHER
)
    tries=0
    while [ $tries -lt 4 ]; do
      if printf '%s' "$launcher" | pexec_i "${PODS[$n]}" "cat > /tmp/run_${GROUP_ID}.sh && chmod +x /tmp/run_${GROUP_ID}.sh" 2>/dev/null; then
        return 0
      fi
      tries=$((tries+1)); sleep 1
    done
    echo "  WARN: write launcher failed node=$n pod=${PODS[$n]}"
    return 1
  }
  for ((n=0; n<NNODES; n++)); do write_launcher "$n" || true; done

  fire_one() {
    local n="$1"
    pexec "${PODS[$n]}" "setsid nohup bash /tmp/run_${GROUP_ID}.sh </dev/null >/dev/null 2>&1 & echo ok; exit 0" 2>/dev/null
  }
  # 串行点火（有界；避免 8 路 kubectl 同时 EOF）
  for ((n=0; n<NNODES; n++)); do fire_one "$n" || true; sleep 0.3; done

  # 核查并补点：仅在「未完成且无 torchrun」时重发，避免短跑结束后误二次点火
  local round miss up done_or_live
  sleep 2
  for round in 1 2 3; do
    miss=0; up=0; done_or_live=0
    for ((n=0; n<NNODES; n++)); do
      pod="${PODS[$n]}"
      if pexec "$pod" "test -f '$out/node_${n}.done' -o -f '$out/node_${n}.fail'" 2>/dev/null; then
        done_or_live=$((done_or_live+1)); continue
      fi
      if pexec "$pod" "pgrep -f '[t]orchrun' >/dev/null" 2>/dev/null; then
        up=$((up+1)); done_or_live=$((done_or_live+1)); continue
      fi
      echo "  retry fire node=$n pod=$pod (round $round)"
      write_launcher "$n" || true
      fire_one "$n" || true
      miss=$((miss+1))
    done
    echo "  fire_check r$round: live_or_done=$done_or_live/$NNODES miss_fired=$miss"
    [ "$miss" = "0" ] && break
    sleep 2
  done
  return 0
}

wait_warmup() {
  local out="$1" e=0
  while [ $e -lt 180 ]; do
    if pexec "$MASTER" "test -f '$out/ranks/warmup_done'" 2>/dev/null; then echo "  warmup ok(${e}s)"; return 0; fi
    sleep 5; e=$((e+5))
  done
  echo "  warmup timeout"; return 0
}

wait_measure_step() {
  local out="$1" target="$2" e=0
  while [ "$e" -lt 1800 ]; do
    if pexec "$MASTER" "test -f '$out/ranks/step_${target}.marker'" 2>/dev/null; then
      echo "  measure step $target reached (${e}s)"
      return 0
    fi
    if pexec "$MASTER" "ls '$out'/node_*.fail >/dev/null 2>&1" 2>/dev/null; then
      echo "  measure step $target aborted: training fail marker"
      return 1
    fi
    sleep 5; e=$((e+5))
  done
  echo "  measure step $target timeout"
  return 1
}

start_sidecar() {
  local v="${PODS[0]}"
  case "$INJECT_KIND" in
    cube|hbm)
      pexec "$v" "rm -f '$out/injection.log'; MACA_VISIBLE_DEVICES=$SIDECAR_LOCAL_RANK PYTHONUNBUFFERED=1 env -u CUDA_VISIBLE_DEVICES nohup /opt/conda/bin/python3.12 -u '$CODE_DIR/sidecar_inject.py' --kind '$INJECT_KIND' --duty '$DUTY' --warmup-seconds '$SIDECAR_WARMUP' --seconds 1800 --size '$SIZE' >'$out/injection.log' 2>&1 & echo SC=\$!" 2>/dev/null ;;
    1b|1c|2c|3c|5b|8b|8c)
      # 注意：2b 在本 pipeline 走 INLINE rare_shape，不走 sidecar_v2
      pexec "$v" "MACA_VISIBLE_DEVICES=$((NPROC-1)) env -u CUDA_VISIBLE_DEVICES nohup /opt/conda/bin/python3.12 $CODE_DIR/sidecar_inject_v2.py --case $INJECT_KIND --seconds 600 --frac $FRAC >/tmp/sc_${GROUP_ID}.log 2>&1 & echo SC=\$!" 2>/dev/null ;;
    stress_cpu)
      local ncpu="${CPU_N}" cl="${CPU_LOAD:-90}"
      if [ -z "$ncpu" ] && [ -n "$CPU_FRAC" ]; then
        local np
        np=$(pexec "$v" "nproc" 2>/dev/null | tr -d '[:space:]')
        ncpu=$(awk -v f="$CPU_FRAC" -v n="${np:-16}" 'BEGIN{v=int(n*f+0.5); if(v<1)v=1; print v}')
      fi
      if [ -z "$ncpu" ]; then
        pexec "$v" "nohup stress-ng --cpu \$(nproc) --cpu-load $cl --timeout 600s >'$out/injection.log' 2>&1 & echo SC=\$!" 2>/dev/null
      else
        pexec "$v" "nohup stress-ng --cpu $ncpu --cpu-load $cl --timeout 600s >'$out/injection.log' 2>&1 & echo SC=\$!" 2>/dev/null
      fi
      ;;
    stress_vm)
      pexec "$v" "nohup stress-ng --vm $VM_N --vm-bytes $VM_BYTES --vm-keep --page-in --timeout 600s >'$out/injection.log' 2>&1 & echo SC=\$!; echo SIDECAR_START stress_vm_n=${VM_N}_bytes=${VM_BYTES}" 2>/dev/null ;;
    stress_io)
      pexec "$v" "mkdir -p '$IO_STRESS_DIR'; nohup fio --name=io_stress --rw=randrw --bs=4k --size=4G --numjobs=16 --iodepth=64 --time_based --runtime=600 --directory='$IO_STRESS_DIR' --group_reporting >'$out/injection.log' 2>&1 & echo SC=\$!; echo SIDECAR_START fio_loud_nj16" 2>/dev/null ;;
    mccl_algo|rare_shape|2b|8a|inline_8a|none) : ;;
    *) echo "  WARN: unknown INJECT_KIND=$INJECT_KIND" ;;
  esac
}

wait_sidecar_start() {
  local out="$1" v="${PODS[0]}" e=0
  local budget=$(( SIDECAR_WARMUP + 30 ))
  while [ "$e" -lt "$budget" ]; do
    if pexec "$v" "grep -q 'SIDECAR_START' '$out/injection.log' 2>/dev/null" 2>/dev/null; then
      echo "  sidecar START ok(${e}s)"
      return 0
    fi
    if pexec "$v" "ls '$out'/node_*.fail >/dev/null 2>&1" 2>/dev/null; then
      echo "  sidecar START aborted: training fail"
      return 1
    fi
    if ! pexec "$v" "pgrep -f '[s]idecar_inject.py' >/dev/null" 2>/dev/null; then
      echo "  sidecar START failed: process gone without SIDECAR_START"
      pexec "$v" "tail -n 40 '$out/injection.log' 2>/dev/null" 2>/dev/null || true
      return 1
    fi
    sleep 2; e=$((e+2))
  done
  echo "  sidecar START timeout(${e}s)"
  pexec "$v" "tail -n 40 '$out/injection.log' 2>/dev/null" 2>/dev/null || true
  return 1
}

is_gpu_sidecar() {
  case "$INJECT_KIND" in
    cube|hbm|1b|1c|2c|3c|5b) return 0 ;;
    *) return 1 ;;
  esac
}
stop_sidecar() {
  pexec "${PODS[0]}" 'pkill -TERM -f "[s]idecar_inject" 2>/dev/null || true; sleep 1; pkill -9 -f "[s]idecar_inject" 2>/dev/null || true; pkill -TERM stress-ng 2>/dev/null || true; sleep 1; pkill -9 stress-ng 2>/dev/null || true; pkill -9 -f "[s]tress-ng" 2>/dev/null || true; pkill -f "fio.*io_stress" 2>/dev/null || true; pkill -f "[i]b_write_bw" 2>/dev/null || true; exit 0' 2>/dev/null || true
  return 0
}

wait_done() {
  local out="$1" stop_on_marker="${2:-0}" stopped=0 e=0
  while [ $e -lt 900 ]; do
    local d=0 f=0
    if [ "$stop_on_marker" = "1" ] && [ "$stopped" = "0" ] &&
      pexec "$MASTER" "test -f '$out/ranks/step_${INJECT_STOP_MEASURE_STEP}.marker'" 2>/dev/null; then
      stop_sidecar
      stopped=1
      echo "  injection stopped at measure step $INJECT_STOP_MEASURE_STEP"
    fi
    if [ "${LOCAL_FS:-0}" = "1" ]; then
      n=0
      while [ "$n" -lt "$NNODES" ]; do
        if pexec "${PODS[$n]}" "test -f '$out/node_${n}.done'" >/dev/null 2>&1; then
          d=$((d + 1))
        elif pexec "${PODS[$n]}" "test -f '$out/node_${n}.fail'" >/dev/null 2>&1; then
          f=$((f + 1))
        fi
        n=$((n + 1))
      done
    else
      d=$(pexec "$MASTER" "ls '$out'/node_*.done 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \n')
      f=$(pexec "$MASTER" "ls '$out'/node_*.fail 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \n')
    fi
    if [ "${d:-0}" -ge "$NNODES" ] 2>/dev/null; then
      echo "  done markers $d/$NNODES (${e}s)"
      return 0
    fi
    if [ "${f:-0}" != "0" ] && [ "${f:-0}" != "" ]; then
      echo "  FAIL marker seen (f=$f)"
      return 1
    fi
    if [ $((e % 30)) -eq 0 ]; then
      echo "  waiting done… d=${d:-0}/$NNODES t=${e}s"
    fi
    sleep 5; e=$((e+5))
  done
  echo "  TIMEOUT(${e}s) d=${d:-0}/$NNODES"; return 1
}

# ===== configs =====
CONFIGS=("C0_baseline" "C1_inject_none" "C2_probing" "C3_greyhound" "C4_xputimer" "C5_flight_recorder")
config_denv() {
  case "$1" in
    C0_baseline|C1_inject_none) echo "unset PROBING PROBING_TORCH_PROFILING PROBING_GPU; export PROBING=0;" ;;
    C2_probing)
      if [ -n "${PROBING_SPEC:-}" ]; then
        echo "export PROBING=2; export PROBING_TORCH_PROFILING='$PROBING_SPEC'; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      else
        echo "export PROBING=2; unset PROBING_TORCH_PROFILING; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      fi
      ;;
    C3_greyhound) echo "export LD_PRELOAD=$CODE_DIR/greyhound/libmcclprobe.so;" ;;
    C4_xputimer)  echo "export LD_PRELOAD=$CODE_DIR/xputimer/libxpu_timer_metax.so;" ;;
    C5_flight_recorder)
      echo "unset PROBING PROBING_TORCH_PROFILING; export PROBING=0; export TORCH_NCCL_TRACE_BUFFER_SIZE=\${TORCH_NCCL_TRACE_BUFFER_SIZE:-1048576}; export TORCH_NCCL_DUMP_ON_TIMEOUT=1;"
      ;;
    *) echo "" ;;
  esac
}
config_has_inject() {
  case "$1" in
    C0_baseline) echo "no" ;;
    *) echo "yes" ;;
  esac
}

if [ -n "${CONFIGS_ONLY:-}" ]; then IFS=',' read -r -a CONFIGS <<< "$CONFIGS_ONLY"; fi

# ===== main loop =====
IS_FREQ=0; [ "$INJECT_KIND" = "freq" ] && IS_FREQ=1
port=$BASE_PORT
pipe_rc=0
for r in $(seq 1 "$ROUNDS"); do
  echo ""; echo "══ Round $r/$ROUNDS ══"
  for cfg in "${CONFIGS[@]}"; do
    port=$((port+1))
    out="$OUT_BASE/round_${r}/${cfg}"
    echo "── [$cfg] r=$r port=$port ──"
    clean_group
    # 清陈旧 done/fail：否则 fire_check / wait_done 会把上次失败轮当成已完成而跳过点火
    for ((n=0; n<NNODES; n++)); do
      pexec "${PODS[$n]}" "rm -f '$out/node_${n}.done' '$out/node_${n}.fail'; rm -rf '$out/ranks'; mkdir -p '$out/ranks'" 2>/dev/null \
        || echo "  WARN: wipe stale markers ${PODS[$n]}"
    done
    denv="$(config_denv "$cfg")"; inj="$(config_has_inject "$cfg")"

    # P3-SW-A：进程内联 8a
    if [ "$inj" = "yes" ] && { [ "$INJECT_KIND" = "8a" ] || [ "$INJECT_KIND" = "inline_8a" ]; }; then
      denv="${denv}
export INLINE_INJECT=8a;
export INLINE_VICTIM_LOCAL_RANK=$SIDECAR_LOCAL_RANK;
export INLINE_INJECT_START=$INJECT_START_MEASURE_STEP;
export INLINE_INJECT_STOP=$INJECT_STOP_MEASURE_STEP;
export INLINE_GC_EVERY=${INLINE_GC_EVERY:-1};
export INLINE_GC_STALL_S=${INLINE_GC_STALL_S:-0.25};"
    fi
    # P1-EXT-B inline hbm
    USE_INLINE_HBM="${USE_INLINE_HBM:-1}"
    if [ "$inj" = "yes" ] && [ "$INJECT_KIND" = "hbm" ] && [ "$USE_INLINE_HBM" = "1" ]; then
      denv="${denv}
export INLINE_INJECT=hbm;
export INLINE_VICTIM_LOCAL_RANK=$SIDECAR_LOCAL_RANK;
export INLINE_INJECT_START=$INJECT_START_MEASURE_STEP;
export INLINE_INJECT_STOP=$INJECT_STOP_MEASURE_STEP;
export INLINE_HBM_MB=${INLINE_HBM_MB:-512};
export INLINE_HBM_COPIES=${INLINE_HBM_COPIES:-48};"
    fi
    # P2-SW-B：C0/C1/C2 同开 MCCL_STRESS_MB（大 AllReduce 负载），仅 inject 侧钳通道
    if [ "$INJECT_KIND" = "mccl_algo" ]; then
      MCCL_STRESS_MB_V="${MCCL_STRESS_MB:-512}"
      denv="${denv}
export MCCL_STRESS_MB=$MCCL_STRESS_MB_V;"
    fi
    if [ "$inj" = "yes" ] && [ "$INJECT_KIND" = "mccl_algo" ]; then
      denv="${denv}
export MCCL_ALGO=$MCCL_ALGO_V;
export MCCL_PROTO=$MCCL_PROTO_V;
export MCCL_MIN_NCHANNELS=$MCCL_MIN_CH;
export MCCL_MAX_NCHANNELS=$MCCL_MAX_CH;"
    fi
    # P1-SW-B：rare shape / 2b
    if [ "$inj" = "yes" ] && { [ "$INJECT_KIND" = "rare_shape" ] || [ "$INJECT_KIND" = "2b" ]; }; then
      denv="${denv}
export INLINE_INJECT=2b;
export INLINE_VICTIM_LOCAL_RANK=$SIDECAR_LOCAL_RANK;
export INLINE_INJECT_START=$INJECT_START_MEASURE_STEP;
export INLINE_INJECT_STOP=$INJECT_STOP_MEASURE_STEP;
export RARE_SHAPE_SEQ=$RARE_SEQ_V;
export RARE_SHAPE_EVERY=$RARE_EVERY_V;"
      if [ -n "${RARE_FRAC_V:-}" ]; then
        denv="${denv}
export RARE_SHAPE_FRAC=$RARE_FRAC_V;"
      fi
    fi

    if [ "$IS_FREQ" = "1" ] && [ "$inj" = "yes" ]; then
      freq_set "$FREQ_LEVEL"
      fire_training "$port" "$out" "$denv" "$r"; echo "  fired(freq=$FREQ_LEVEL)"
      wait_warmup "$out"
    else
      fire_training "$port" "$out" "$denv" "$r"; echo "  fired"
      wait_warmup "$out"
      if [ "$inj" = "yes" ] && [ "$INJECT_KIND" = "mccl_algo" ]; then
        echo "  mccl_algo armed (algo=$MCCL_ALGO_V proto=$MCCL_PROTO_V ch=${MCCL_MIN_CH}-${MCCL_MAX_CH})"
        pexec "$MASTER" "printf '%s\n' 'INLINE_INJECT kind=mccl_algo' 'SIDECAR_START kind=mccl_algo' \"MCCL_ALGO=$MCCL_ALGO_V\" \"MCCL_PROTO=$MCCL_PROTO_V\" \"MCCL_MIN_NCHANNELS=$MCCL_MIN_CH\" \"MCCL_MAX_NCHANNELS=$MCCL_MAX_CH\" >'$out/injection.log'" 2>/dev/null || true
      elif [ "$inj" = "yes" ] && { [ "$INJECT_KIND" = "rare_shape" ] || [ "$INJECT_KIND" = "2b" ]; }; then
        echo "  rare_shape/2b armed (seq=$RARE_SEQ_V every=$RARE_EVERY_V victim=L$SIDECAR_LOCAL_RANK)"
        pexec "$MASTER" "printf '%s\n' 'INLINE_INJECT kind=2b' 'SIDECAR_START kind=rare_shape' \"RARE_SHAPE_SEQ=$RARE_SEQ_V\" \"RARE_SHAPE_EVERY=$RARE_EVERY_V\" \"INLINE_VICTIM_LOCAL_RANK=$SIDECAR_LOCAL_RANK\" >'$out/injection.log'" 2>/dev/null || true
      elif [ "$inj" = "yes" ] && [ "$INJECT_KIND" = "hbm" ] && [ "${USE_INLINE_HBM:-1}" = "1" ]; then
        echo "  inline_hbm armed (victim local_rank=$SIDECAR_LOCAL_RANK mb=${INLINE_HBM_MB:-256})"
        pexec "${PODS[0]}" "printf '%s\n' 'SIDECAR_WARMUP kind=inline_hbm' 'SIDECAR_START kind=inline_hbm' >'$out/injection.log'" 2>/dev/null || true
      elif [ "$inj" = "yes" ] && [ "$INJECT_KIND" != "none" ] && ! is_inline_kind; then
        if wait_measure_step "$out" "$INJECT_START_MEASURE_STEP"; then
          start_sidecar; echo "  sidecar($INJECT_KIND) up on local_rank=$SIDECAR_LOCAL_RANK"
          if is_gpu_sidecar; then
            if ! wait_sidecar_start "$out"; then
              echo "  FAILED: GPU sidecar did not reach SIDECAR_START"
              pipe_rc=1
              stop_sidecar
            fi
          fi
        else
          echo "  injection skipped: start marker unavailable"
        fi
      elif [ "$inj" = "yes" ] && { [ "$INJECT_KIND" = "8a" ] || [ "$INJECT_KIND" = "inline_8a" ]; }; then
        echo "  inline_8a armed (victim local_rank=$SIDECAR_LOCAL_RANK)"
      fi
    fi

    if [ "$cfg" = "C2_probing" ] && [ "${DUMP_PROBING_SQL:-1}" = "1" ]; then
      DUMP_WAIT_S="${DUMP_WAIT_S:-45}"
      echo "  waiting ${DUMP_WAIT_S}s into inject window for SQL dump …"
      sleep "$DUMP_WAIT_S"
      if pexec "$MASTER" "pgrep -f '/tmp/tbp.py' >/dev/null" 2>/dev/null; then
        echo "  dumping Probing SQL …"
        DUMP_SRC=""
        if [ -f "$HERE_PARENT/dump_probing_sql.sh" ]; then
          DUMP_SRC="$HERE_PARENT/dump_probing_sql.sh"
        elif [ -f "$HERE_SWB/dump_probing_sql.sh" ]; then
          DUMP_SRC="$HERE_SWB/dump_probing_sql.sh"
        fi
        if [ -n "$DUMP_SRC" ]; then
          pexec_i "$MASTER" "cat > '$CODE_DIR/dump_probing_sql.sh' && chmod +x '$CODE_DIR/dump_probing_sql.sh'" \
            < "$DUMP_SRC" 2>/dev/null || true
        fi
        pexec "$MASTER" \
          "OUT_DIR='$out' CASE='$CASE' CODE_DIR='$CODE_DIR' VICTIM_LOCAL_RANK='$SIDECAR_LOCAL_RANK' \
           bash '$CODE_DIR/dump_probing_sql.sh' >'$out/probing_dump.log' 2>&1; exit 0" 2>/dev/null || true
        echo "  SQL dump attempted → $out/probing/"
      else
        echo "  SQL dump skipped: training not running"
      fi
    fi

    # 内联 / mccl_algo / rare_shape：无外部 sidecar，stop_flag=0
    if [ "$inj" = "yes" ] && [ "$INJECT_KIND" != "none" ] && ! is_inline_kind; then
      stop_flag=1
    else
      stop_flag=0
    fi
    if wait_done "$out" "$stop_flag"; then
      echo "  COMPLETE"
    else
      echo "  FAILED"
      pipe_rc=1
    fi
    stop_sidecar
    if [ "$IS_FREQ" = "1" ]; then freq_restore; fi
  done
done
echo ""; echo "╚═ swb DONE case=$CASE grp=$GROUP_ID rc=$pipe_rc ═╝"
exit "$pipe_rc"
