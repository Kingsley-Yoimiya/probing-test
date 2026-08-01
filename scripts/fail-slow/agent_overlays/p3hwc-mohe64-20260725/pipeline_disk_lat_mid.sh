#!/usr/bin/env bash
# pipeline_disk_lat_mid.sh — P3-HW-C / OUTLINE 7C：本地盘读延迟（dm-delay mid）
#
# ≠ run_campaign ecc；≠ P3-EXT-B stress_io（邻居 fio 争用曾 GAVE_UP）
# 真路径：loop + dm-delay 挂载数据目录；C0=0ms，C1 measure100 后 reload delay_ms
# host_bound + IO_PAYLOAD on delayed FS；DL_WORKERS=0 让读延迟进 data_ms/step_ms
set -uo pipefail

# ===== 参数 =====
CASE="${CASE:?need CASE}"
INJECT_KIND="${INJECT_KIND:?need INJECT_KIND (disk_lat|...)}"
INJECT_ARGS="${INJECT_ARGS:-}"
GROUP_ID="${GROUP_ID:-0}"
IFS=',' read -r -a PODS <<< "${PODS:?need PODS csv}"
NNODES="${NNODES:-2}"
NPROC="${NPROC:-8}"
ROUNDS="${ROUNDS:-3}"
ITERS="${ITERS:-500}"
WARMUP="${WARMUP:-50}"
SEED="${SEED:-42}"
MODE="${MODE:-host_bound}"
MODEL="${MODEL:-gpt2}"
SEQ="${SEQ:-1024}"
BATCH="${BATCH:-8}"
# 盘延迟：ms；Loud 默认 50（单次 pread 加 ~50ms；batch=8 → ~400ms/step）
DISK_DELAY_MS="${DISK_DELAY_MS:-50}"
DISK_DELAY_IMG_MB="${DISK_DELAY_IMG_MB:-512}"
DISK_DELAY_NAME="${DISK_DELAY_NAME:-p3hwc_delay}"
DISK_DELAY_MNT="${DISK_DELAY_MNT:-/mnt/p3hwc_data}"
DISK_DELAY_IMG="${DISK_DELAY_IMG:-/tmp/p3hwc_delay.img}"
IO_PAYLOAD="${IO_PAYLOAD:-$DISK_DELAY_MNT/payload.bin}"
IO_READ_KB="${IO_READ_KB:-1024}"
DL_WORKERS="${DL_WORKERS:-0}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"
LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
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
IO_STRESS_DIR="${IO_STRESS_DIR:-/workspace/probe-bundle/io_stress}"
CKPT_DIR="${CKPT_DIR:-/workspace/probe-bundle/ckpt}"

# POD_EXEC 抽象: 默认 kubectl(raw pod); 设 USE_VCCTL=1 切 vcctl(vcjob pod)
if [ "${USE_VCCTL:-0}" = "1" ]; then
  VCCTL="${VCCTL:-/usr/local/bin/vcctl}"
  pexec()   { "$VCCTL" pod exec    "$1" -- bash -c "$2"; }
  pexec_i() { "$VCCTL" pod exec -i "$1" -- bash -c "$2"; }
  pod_ip()  { "$VCCTL" pod view "$1" 2>/dev/null | grep -oE 'IP[: ]+[0-9.]+' | grep -oE '[0-9.]+' | head -1; }
else
  KC="${KUBECONFIG:?need KUBECONFIG for kubectl}"
  pexec()   { kubectl --kubeconfig="$KC" -n "$NS" exec    "$1" -- bash -c "$2"; }
  pexec_i() { kubectl --kubeconfig="$KC" -n "$NS" exec -i "$1" -- bash -c "$2"; }
  pod_ip()  { kubectl --kubeconfig="$KC" -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}' 2>/dev/null; }
fi

DUTY=$(echo "$INJECT_ARGS" | grep -oE 'duty=[0-9.]+' | cut -d= -f2 || true); DUTY="${DUTY:-0.9}"
SIZE=$(echo "$INJECT_ARGS" | grep -oE 'size=[0-9]+'  | cut -d= -f2 || true); SIZE="${SIZE:-8192}"
FRAC=$(echo "$INJECT_ARGS" | grep -oE 'frac=[0-9.]+' | cut -d= -f2 || true); FRAC="${FRAC:-0.7}"
CPU_LOAD=$(echo "$INJECT_ARGS" | grep -oE 'cpu_load=[0-9.]+' | cut -d= -f2 || true); CPU_LOAD="${CPU_LOAD:-90}"
CPU_N=$(echo "$INJECT_ARGS" | grep -oE 'cpu_n=[0-9]+' | cut -d= -f2 || true)
CPU_FRAC=$(echo "$INJECT_ARGS" | grep -oE 'cpu_frac=[0-9.]+' | cut -d= -f2 || true)
VM_N=$(echo "$INJECT_ARGS" | grep -oE 'vm_n=[0-9]+' | cut -d= -f2 || true); VM_N="${VM_N:-4}"
VM_BYTES=$(echo "$INJECT_ARGS" | grep -oE 'vm_bytes=[0-9]+[KkMmGg]?' | cut -d= -f2 || true); VM_BYTES="${VM_BYTES:-2G}"
# P3-HW-C：delay_ms= from INJECT_ARGS
_dms=$(echo "$INJECT_ARGS" | grep -oE 'delay_ms=[0-9]+' | cut -d= -f2 || true)
[ -n "$_dms" ] && DISK_DELAY_MS="$_dms"
echo "  inject_parse DISK_DELAY_MS=$DISK_DELAY_MS IO_PAYLOAD=$IO_PAYLOAD IO_READ_KB=$IO_READ_KB DL_WORKERS=$DL_WORKERS"

MASTER="${PODS[0]}"
MASTER_IP="$(pod_ip "$MASTER")"
[ -z "$MASTER_IP" ] && { echo "FATAL: cannot resolve master IP for $MASTER"; exit 2; }
# 多组端口隔离: 每组 100 端口块
BASE_PORT=$(( 30000 + GROUP_ID * 100 ))
OUT_BASE="$RUN_DIR/$CASE"

echo "╔══════════════════════════════════════════════╗"
echo "║ v4 case=$CASE grp=$GROUP_ID inject=$INJECT_KIND mode=$MODE"
echo "║ pods=${PODS[*]} NNODES=$NNODES NPROC=$NPROC world=$((NNODES*NPROC))"
echo "║ master=$MASTER($MASTER_IP) base_port=$BASE_PORT rounds=$ROUNDS"
echo "║ iters=$ITERS warmup=$WARMUP sidecar_warmup=$SIDECAR_WARMUP victim=L$SIDECAR_LOCAL_RANK"
echo "║ code=$CODE_DIR out=$OUT_BASE local_fs=$LOCAL_FS run_id=$RUN_ID"
echo "╚══════════════════════════════════════════════╝"
# 短冒烟 ITERS<350 时 inject 窗 [100,300] 不完整，且 SIDECAR_WARMUP 易未结束 → 假阴性
if [ "$ITERS" -lt 350 ] 2>/dev/null; then
  echo "WARN: ITERS=$ITERS < 350；P1 cube/hbm 咬合验收需 ITERS>=500" >&2
fi

# ===== helpers =====
clean_group() {
  # kubectl exec + pkill 常返回 137；在 set -e 下必须吞掉，否则战役会在 fire 前静默退出
  # 同时释放本组端口块，避免 EADDRINUSE（上轮残留 store）
  # pkill -f 模式用 [x]foo 避免匹配到本 bash -c 命令行自身
  local p0=$BASE_PORT p1=$((BASE_PORT+1)) p2=$((BASE_PORT+2))
  for ((n=0; n<NNODES; n++)); do
    pexec "${PODS[$n]}" "pkill -9 -f '[t]rain_bench_probe' 2>/dev/null || true; pkill -9 -f '/tmp/[t]bp.py' 2>/dev/null || true; pkill -9 -f '[t]orchrun' 2>/dev/null || true; pkill -9 -f '[s]idecar_inject' 2>/dev/null || true; pkill -9 -x stress-ng 2>/dev/null || true; pkill -9 -f 'fio.*io_stress' 2>/dev/null || true; pkill -9 -f '[i]b_write_bw' 2>/dev/null || true; rm -rf /dev/shm/nccl* /dev/shm/mccl* /dev/shm/torch_* /dev/shm/probing /dev/shm/__KMP* 2>/dev/null || true; find /dev/shm -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true; fuser -k ${p0}/tcp ${p1}/tcp ${p2}/tcp 2>/dev/null || true; sleep 1; exit 0" 2>/dev/null &
  done
  wait || true
  sleep 5
  return 0
}

# dm-delay：loop + delay target + ext4 @ DISK_DELAY_MNT（OUTLINE 7C）
disk_lat_setup() {  # ensure mount @ 0ms with payload; all pods for path consistency
  local mb="$DISK_DELAY_IMG_MB" img="$DISK_DELAY_IMG" mnt="$DISK_DELAY_MNT" dm="$DISK_DELAY_NAME"
  local pay="${IO_PAYLOAD}"
  for ((n=0; n<NNODES; n++)); do
    pexec "${PODS[$n]}" "
      set +e
      mkdir -p '$mnt'
      # already mounted?
      if mountpoint -q '$mnt' 2>/dev/null && [ -f '$pay' ]; then
        # force 0ms baseline
        LOOP=\$(losetup -j '$img' 2>/dev/null | cut -d: -f1 | head -1)
        if [ -n \"\$LOOP\" ]; then
          SEC=\$(blockdev --getsz \"\$LOOP\")
          echo \"0 \$SEC delay \$LOOP 0 0\" | dmsetup reload '$dm' 2>/dev/null
          dmsetup resume '$dm' 2>/dev/null
        fi
        echo DISK_LAT_SETUP_OK already pod=${PODS[$n]}
        exit 0
      fi
      # cleanup stale
      fuser -km '$mnt' 2>/dev/null || true
      umount -l '$mnt' 2>/dev/null || true
      dmsetup remove '$dm' 2>/dev/null || dmsetup remove -f '$dm' 2>/dev/null || true
      LOOP_OLD=\$(losetup -j '$img' 2>/dev/null | cut -d: -f1 | head -1)
      [ -n \"\$LOOP_OLD\" ] && losetup -d \"\$LOOP_OLD\" 2>/dev/null || true
      rm -f '$img'
      dd if=/dev/zero of='$img' bs=1M count=$mb status=none
      LOOP=\$(losetup -f --show '$img') || { echo DISK_LAT_SETUP_FAIL losetup; exit 0; }
      SEC=\$(blockdev --getsz \"\$LOOP\")
      echo \"0 \$SEC delay \$LOOP 0 0\" | dmsetup create '$dm' || { echo DISK_LAT_SETUP_FAIL dmcreate; exit 0; }
      dmsetup mknodes 2>/dev/null || true
      if [ ! -b /dev/mapper/$dm ]; then
        MAJMIN=\$(dmsetup info -c --noheadings -o major,minor '$dm')
        maj=\${MAJMIN%%:*}; min=\${MAJMIN##*:}
        mknod /dev/mapper/$dm b \"\$maj\" \"\$min\" 2>/dev/null || true
      fi
      mkfs.ext4 -F /dev/mapper/$dm >/tmp/p3hwc_mkfs.log 2>&1 || { echo DISK_LAT_SETUP_FAIL mkfs; exit 0; }
      mount /dev/mapper/$dm '$mnt' || { echo DISK_LAT_SETUP_FAIL mount; exit 0; }
      # 256MiB payload（>= IO_READ）；urandom 防全零压缩
      dd if=/dev/urandom of='$pay' bs=1M count=256 status=none
      sync
      echo DISK_LAT_SETUP_OK loop=\$LOOP sec=\$SEC pay='$pay'
      exit 0
    " 2>/dev/null &
  done
  wait || true
  # verify master（kubectl 瞬时 EOF 时重试）
  local tries=0
  while [ "$tries" -lt 8 ]; do
    if pexec "$MASTER" "mountpoint -q '$DISK_DELAY_MNT' && test -f '$IO_PAYLOAD' && echo READY" 2>/dev/null | grep -q READY; then
      echo "  disk_lat setup OK on master ($DISK_DELAY_MNT)"
      return 0
    fi
    tries=$((tries + 1))
    echo "  disk_lat setup verify retry $tries …"
    sleep 3
  done
  echo "  FATAL: disk_lat setup failed on master after retries"
  return 1
}

disk_lat_set() {  # $1=delay_ms — reload dm-delay on MASTER only (rank0 host)
  local dms="$1"
  pexec "$MASTER" "
    set +e
    IMG='$DISK_DELAY_IMG'
    DM='$DISK_DELAY_NAME'
    LOOP=\$(losetup -j \"\$IMG\" 2>/dev/null | cut -d: -f1 | head -1)
    if [ -z \"\$LOOP\" ]; then echo DISK_LAT_SET_FAIL no_loop; exit 0; fi
    SEC=\$(blockdev --getsz \"\$LOOP\")
    echo \"0 \$SEC delay \$LOOP 0 $dms\" | dmsetup reload \"\$DM\"
    dmsetup resume \"\$DM\"
    # drop page cache so subsequent preads hit delayed device
    sync; echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true
    echo DISK_LAT_MID_SET delay_ms=$dms loop=\$LOOP
    # iowait sample
    grep -E 'cpu |iowait' /proc/stat | head -2 || true
  " 2>/dev/null
}

disk_lat_restore() {  # back to 0ms
  disk_lat_set 0 || true
  pexec "$MASTER" "echo DISK_LAT_RESTORED delay_ms=0" 2>/dev/null || true
}

disk_lat_teardown() {
  for ((n=0; n<NNODES; n++)); do
    pexec "${PODS[$n]}" "
      set +e
      fuser -km '$DISK_DELAY_MNT' 2>/dev/null || true
      umount -l '$DISK_DELAY_MNT' 2>/dev/null || true
      dmsetup remove '$DISK_DELAY_NAME' 2>/dev/null || dmsetup remove -f '$DISK_DELAY_NAME' 2>/dev/null || true
      LOOP=\$(losetup -j '$DISK_DELAY_IMG' 2>/dev/null | cut -d: -f1 | head -1)
      [ -n \"\$LOOP\" ] && losetup -d \"\$LOOP\" 2>/dev/null || true
      # keep img for faster re-setup next config; optional rm
      exit 0
    " 2>/dev/null &
  done
  wait || true
}

fire_training() {   # $1=port $2=out_dir $3=detect_env $4=round
  local port="$1" out="$2" denv="$3" rnd="$4"
  for ((n=0; n<NNODES; n++)); do
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
cp -f '$CODE_DIR/train_bench_probe.py' /tmp/tbp.py
/opt/conda/bin/torchrun --nnodes=$NNODES --nproc_per_node=$NPROC --node_rank=$n \\
  --master_addr=$MASTER_IP --master_port=$port \\
  /tmp/tbp.py --iters=$ITERS --warmup=$WARMUP --seed=$SEED --mode=$MODE --model=$MODEL --seq=$SEQ --batch=$BATCH \\
  --flush-every=${FLUSH_EVERY:-5} --ckpt-every=${CKPT_EVERY:-100} \\
  --io-payload='${IO_PAYLOAD}' --io-read-kb=${IO_READ_KB} --dl-workers=${DL_WORKERS} \\
  --run-id=$RUN_ID --group=$GROUP_ID --config='$(basename "$out")' --round=$rnd \\
  --out-dir='$out/ranks' > '$out/node_${n}.log' 2>&1
rc=\$?
if [ \$rc -eq 0 ]; then touch '$out/node_${n}.done'; else echo \$rc > '$out/node_${n}.fail'; fi
LAUNCHER
)
    printf '%s' "$launcher" | pexec_i "${PODS[$n]}" "cat > /tmp/run_${GROUP_ID}.sh && chmod +x /tmp/run_${GROUP_ID}.sh" 2>/dev/null       || echo "  WARN: upload launcher fail n=$n" >&2
    echo "  uploaded n=$n"
  done
  local oks=0
  for ((n=0; n<NNODES; n++)); do
    if pexec "${PODS[$n]}" "setsid nohup bash /tmp/run_${GROUP_ID}.sh </dev/null >/dev/null 2>&1 & echo ok; exit 0" 2>/dev/null | grep -q ok; then
      echo "ok"
      oks=$((oks+1))
    else
      echo "  WARN: fire fail n=$n pod=${PODS[$n]}"
      # one retry
      if pexec "${PODS[$n]}" "setsid nohup bash /tmp/run_${GROUP_ID}.sh </dev/null >/dev/null 2>&1 & echo ok; exit 0" 2>/dev/null | grep -q ok; then
        echo "ok"
        oks=$((oks+1))
      fi
    fi
  done
  echo "  fire_ok=$oks/$NNODES"
  if [ "$oks" -lt "$NNODES" ]; then
    echo "  FATAL: incomplete fire $oks/$NNODES"
    return 1
  fi
  return 0
}

wait_warmup() {   # $1=out_dir；rank0 位于 master，故 marker 在 master pod
  local out="$1" e=0
  # host_bound+IO_PAYLOAD+Probing C2 起训更慢；默认 600s（可用 WAIT_WARMUP_S 覆盖）
  local lim="${WAIT_WARMUP_S:-600}"
  while [ $e -lt "$lim" ]; do
    if pexec "$MASTER" "test -f '$out/ranks/warmup_done'" 2>/dev/null; then echo "  warmup ok(${e}s)"; return 0; fi
    # 早退：master 已 fail 或无 torchrun
    if pexec "$MASTER" "ls '$out'/node_0.fail >/dev/null 2>&1" 2>/dev/null; then
      echo "  warmup aborted: node_0.fail"; return 1
    fi
    if [ "$e" -ge 60 ] && ! pexec "$MASTER" "pgrep -f '/tmp/tbp.py' >/dev/null" 2>/dev/null; then
      echo "  warmup aborted: master tbp gone @${e}s"; return 1
    fi
    sleep 5; e=$((e+5))
  done
  echo "  warmup timeout (${lim}s)"; return 1
}

wait_measure_step() {  # $1=out_dir $2=measure step marker
  local out="$1" target="$2" e=0
  # 训练已 fail 时绝不能空等到 1800s（Quiet C1 warmup 失败曾卡死战役）
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

start_sidecar() {   # 在 victim(node0)起注入; freq / 内联 8a 不走这里
  local v="${PODS[0]}"
  case "$INJECT_KIND" in
    cube|hbm)
      # MetaX：只用 MACA_VISIBLE_DEVICES 钉 victim 卡；同时设 CUDA=MACA 易在部分栈上错位。
      # 显式 unset CUDA_VISIBLE_DEVICES，避免继承训练 launcher 环境。
      pexec "$v" "rm -f '$out/injection.log'; MACA_VISIBLE_DEVICES=$SIDECAR_LOCAL_RANK PYTHONUNBUFFERED=1 env -u CUDA_VISIBLE_DEVICES nohup /opt/conda/bin/python3.12 -u '$CODE_DIR/sidecar_inject.py' --kind '$INJECT_KIND' --duty '$DUTY' --warmup-seconds '$SIDECAR_WARMUP' --seconds 1800 --size '$SIZE' >'$out/injection.log' 2>&1 & echo SC=\$!" 2>/dev/null ;;
    1b|1c|2b|2c|3c|5b|8b|8c)
      pexec "$v" "MACA_VISIBLE_DEVICES=$((NPROC-1)) env -u CUDA_VISIBLE_DEVICES nohup /opt/conda/bin/python3.12 $CODE_DIR/sidecar_inject_v2.py --case $INJECT_KIND --seconds 600 --frac $FRAC >/tmp/sc_${GROUP_ID}.log 2>&1 & echo SC=\$!" 2>/dev/null ;;
    stress_cpu)
      # Loud 默认全核 90%；Quiet/Masked 经 INJECT_ARGS: cpu_n / cpu_load / cpu_frac
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
      # P3-EXT-C：主机内存带宽/NUMA；剂量由 INJECT_ARGS 的 vm_n / vm_bytes 控制
      # --vm-keep + --page-in：持续触碰已分配页，避免只 alloc 不扫带宽
      pexec "$v" "nohup stress-ng --vm $VM_N --vm-bytes $VM_BYTES --vm-keep --page-in --timeout 600s >'$out/injection.log' 2>&1 & echo SC=\$!; echo SIDECAR_START stress_vm_n=${VM_N}_bytes=${VM_BYTES}" 2>/dev/null ;;
    stress_io)
      # Loud：fio 与训练/ckpt 同盘；bite 标定 numjobs=4 仅 C1/C0≈1.08 → 提到 16 + iodepth
      pexec "$v" "mkdir -p '$IO_STRESS_DIR'; nohup fio --name=io_stress --rw=randrw --bs=4k --size=4G --numjobs=16 --iodepth=64 --time_based --runtime=600 --directory='$IO_STRESS_DIR' --group_reporting >'$out/injection.log' 2>&1 & echo SC=\$!; echo SIDECAR_START fio_loud_nj16" 2>/dev/null ;;
    8a|inline_8a|none) : ;;  # 8a 走训练进程 INLINE_INJECT
    *) echo "  WARN: unknown INJECT_KIND=$INJECT_KIND" ;;
  esac
}

wait_sidecar_start() {  # $1=out_dir；GPU sidecar 必须见到 SIDECAR_START，否则注入窗空转
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
    # 进程已死且无 START → 失败，勿空等
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

# GPU sidecar 需在训练 measure 前预热(MetaX 时间片隔离; pilot 实测: 预热后 +214% vs 未预热 +3%)
is_gpu_sidecar() {
  case "$INJECT_KIND" in
    cube|hbm|1b|1c|2b|2c|3c|5b) return 0 ;;
    *) return 1 ;;
  esac
}
stop_sidecar() {
  # 先 SIGTERM 让 sidecar 打 SIDECAR_STOP；再 -9。模式避免误杀 kubectl exec bash。
  pexec "${PODS[0]}" 'pkill -TERM -f "[s]idecar_inject" 2>/dev/null || true; sleep 1; pkill -9 -f "[s]idecar_inject" 2>/dev/null || true; pkill -TERM stress-ng 2>/dev/null || true; sleep 1; pkill -9 stress-ng 2>/dev/null || true; pkill -9 -f "[s]tress-ng" 2>/dev/null || true; pkill -f "fio.*io_stress" 2>/dev/null || true; pkill -f "[i]b_write_bw" 2>/dev/null || true; exit 0' 2>/dev/null || true
  return 0
}

wait_done() {   # $1=out_dir $2=是否按 stop marker 停 sidecar
  # LOCAL_FS=1: 第 n 个 pod 只写 node_n.done → 必须到 PODS[n] 上查 node_n.done
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
    # 每 30s 打一行进度，避免静默卡住
    if [ $((e % 30)) -eq 0 ]; then
      echo "  waiting done… d=${d:-0}/$NNODES t=${e}s"
    fi
    sleep 5; e=$((e+5))
  done
  echo "  TIMEOUT(${e}s) d=${d:-0}/$NNODES"; return 1
}

# ===== configs (保留 C0-C4) — 用函数替代关联数组(兼容 bash 3.2) =====
CONFIGS=("C0_baseline" "C1_inject_none" "C2_probing" "C3_greyhound" "C4_xputimer" "C5_flight_recorder")
config_denv() {   # $1=cfg → echo detect_env
  case "$1" in
    C0_baseline|C1_inject_none) echo "unset PROBING PROBING_TORCH_PROFILING PROBING_GPU; export PROBING=0;" ;;
    C2_probing)
      # D4：挂 probing + GPU 采样。
      # MetaX/MACA：PROBING_TORCH_PROFILING=on 会在 import torch.distributed.rpc 阶段
      # Failed SET → panic in nounwind → SIGSEGV（见 sql-attach-smoke node_0.log）。
      # 默认关掉；需要 torch_trace 热开时显式 PROBING_SPEC=on（或 dump 里再 SET）。
      if [ -n "${PROBING_SPEC:-}" ]; then
        echo "export PROBING=2; export PROBING_TORCH_PROFILING='$PROBING_SPEC'; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      else
        echo "export PROBING=2; unset PROBING_TORCH_PROFILING; export PROBING_GPU=on; export PROBING_GPU_SAMPLE_MS=1000;"
      fi
      ;;
    C3_greyhound) echo "export LD_PRELOAD=$CODE_DIR/greyhound/libmcclprobe.so;" ;;
    C4_xputimer)  echo "export LD_PRELOAD=$CODE_DIR/xputimer/libxpu_timer_metax.so;" ;;
    # Flight Recorder：环形缓冲；dump 需训练侧/进程退出时落盘。触发协议见 ledger（本战役标 oracle 若人工开窗）。
    C5_flight_recorder)
      echo "unset PROBING PROBING_TORCH_PROFILING; export PROBING=0; export TORCH_NCCL_TRACE_BUFFER_SIZE=\${TORCH_NCCL_TRACE_BUFFER_SIZE:-1048576}; export TORCH_NCCL_DUMP_ON_TIMEOUT=1;"
      ;;
    *) echo "" ;;
  esac
}
config_has_inject() {   # $1=cfg → echo yes|no
  case "$1" in
    C0_baseline) echo "no" ;;
    *) echo "yes" ;;
  esac
}

# 允许只跑部分 config(Line B / 调试): CONFIGS_ONLY="C0_baseline,C2_probing"
if [ -n "${CONFIGS_ONLY:-}" ]; then IFS=',' read -r -a CONFIGS <<< "$CONFIGS_ONLY"; fi

# ===== main loop =====
# OUTLINE 7C：disk_lat = 本地盘读延迟（dm-delay mid）
IS_DISK_LAT=0
case "$INJECT_KIND" in disk_lat|dm_delay|dm-delay) IS_DISK_LAT=1 ;; esac
port=$BASE_PORT
pipe_rc=0

# 战役开始：建 0ms delayed FS + payload（C0/C1 共用路径）
if [ "$IS_DISK_LAT" = "1" ]; then
  if ! disk_lat_setup; then
    echo "FATAL: cannot setup dm-delay data path"
    exit 2
  fi
fi

for r in $(seq 1 "$ROUNDS"); do
  echo ""; echo "══ Round $r/$ROUNDS ══"
  for cfg in "${CONFIGS[@]}"; do
    port=$((port+1))
    out="$OUT_BASE/round_${r}/${cfg}"
    echo "── [$cfg] r=$r port=$port ──"
    clean_group
    echo "  clean_group done"
    denv="$(config_denv "$cfg")"; inj="$(config_has_inject "$cfg")"
    echo "  cfg=$cfg inj=$inj"
    # Greyhound MetaX：dump/marker 落到本轮 out（LOCAL_FS 每 pod 一份）
    if [ "$cfg" = "C3_greyhound" ]; then
      denv="${denv}
mkdir -p '$out/greyhound';
export GREYHOUND_DUMP='$out/greyhound/mcclprobe.collect.jsonl';
export GREYHOUND_STUB_MARKER='$out/greyhound/loaded.marker';"
    fi
    # XPUTimer MetaX：prom/jsonl 落到本轮 out/xputimer
    if [ "$cfg" = "C4_xputimer" ]; then
      denv="${denv}
mkdir -p '$out/xputimer';
export XPU_TIMER_ENABLE=1;
export XPU_TIMER_DUMP_DIR='$out/xputimer';
export XPU_TIMER_DUMP_INTERVAL_S=\${XPU_TIMER_DUMP_INTERVAL_S:-2};
export XPU_TIMER_HANG_TIMEOUT_MS=\${XPU_TIMER_HANG_TIMEOUT_MS:-60000};
export XPU_TIMER_SLOW_REPORT_US=\${XPU_TIMER_SLOW_REPORT_US:-0};
export XPU_TIMER_LAUNCH_SAMPLE=\${XPU_TIMER_LAUNCH_SAMPLE:-32};"
    fi
    # ensure 0ms before each config
    if [ "$IS_DISK_LAT" = "1" ]; then disk_lat_restore || true; echo "  disk_lat baseline 0ms"; fi

    cfg_failed=0
    if [ "$IS_DISK_LAT" = "1" ] && [ "$inj" = "yes" ]; then
      # P3-HW-C / OUTLINE 7C：先 0ms 起训，measure start 后中途抬 dm-delay
      if ! fire_training "$port" "$out" "$denv" "$r"; then
        echo "  FAILED: fire incomplete"; cfg_failed=1; pipe_rc=1
      else
        echo "  fired(disk_lat-mid-armed delay_ms=$DISK_DELAY_MS)"
        if ! wait_warmup "$out"; then
          echo "  FAILED: warmup"; cfg_failed=1; pipe_rc=1
        elif wait_measure_step "$out" "$INJECT_START_MEASURE_STEP"; then
          disk_lat_set "$DISK_DELAY_MS"
          pexec "$MASTER" "printf '%s\n' \
            'SIDECAR_WARMUP kind=disk_lat mid_after_measure_${INJECT_START_MEASURE_STEP}' \
            'SIDECAR_START kind=disk_lat delay_ms=${DISK_DELAY_MS} path=${IO_PAYLOAD} host=victim_master' \
            'DISK_LAT_MID_SET delay_ms=${DISK_DELAY_MS}' \
            'NOTE ≠ EXT-B stress_io; OUTLINE 7C dm-delay read-path' \
            >'$out/injection.log'" 2>/dev/null || true
          echo "  disk_lat MID-SET delay_ms=$DISK_DELAY_MS (master dm-delay)"
        else
          echo "  FAILED: disk_lat mid inject skipped (no start marker)"
          cfg_failed=1; pipe_rc=1
        fi
      fi
    else
      echo "  firing training (baseline or non-mid) …"
      if ! fire_training "$port" "$out" "$denv" "$r"; then
        echo "  FAILED: fire incomplete"; cfg_failed=1; pipe_rc=1
      else
        echo "  fired"
        if ! wait_warmup "$out"; then
          echo "  FAILED: warmup"; cfg_failed=1; pipe_rc=1
        elif [ "$inj" = "yes" ] && [ "$INJECT_KIND" != "none" ] && [ "$IS_DISK_LAT" != "1" ]; then
          if wait_measure_step "$out" "$INJECT_START_MEASURE_STEP"; then
            start_sidecar; echo "  sidecar($INJECT_KIND) up"
          else
            echo "  injection skipped: start marker unavailable"
          fi
        fi
      fi
    fi

    # C2：注入窗内拉 Probing SQL（训练仍活时）
    if [ "$cfg" = "C2_probing" ] && [ "${DUMP_PROBING_SQL:-1}" = "1" ] && [ "$cfg_failed" = "0" ]; then
      HERE_PIPE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      DUMP_WAIT_S="${DUMP_WAIT_S:-45}"
      echo "  waiting ${DUMP_WAIT_S}s into inject window for SQL dump …"
      sleep "$DUMP_WAIT_S"
      if pexec "$MASTER" "pgrep -f '/tmp/tbp.py' >/dev/null" 2>/dev/null; then
        echo "  dumping Probing SQL …"
        if [ -f "$HERE_PIPE/dump_probing_sql.sh" ]; then
          pexec_i "$MASTER" "cat > '$CODE_DIR/dump_probing_sql.sh' && chmod +x '$CODE_DIR/dump_probing_sql.sh'" \
            < "$HERE_PIPE/dump_probing_sql.sh" 2>/dev/null || true
        fi
        pexec "$MASTER" \
          "OUT_DIR='$out' CASE='$CASE' CODE_DIR='$CODE_DIR' VICTIM_LOCAL_RANK='$SIDECAR_LOCAL_RANK' \
           DISK_DELAY_MS='$DISK_DELAY_MS' DISK_DELAY_NAME='$DISK_DELAY_NAME' IO_PAYLOAD='$IO_PAYLOAD' \
           bash '$CODE_DIR/dump_probing_sql.sh' >'$out/probing_dump.log' 2>&1; exit 0" 2>/dev/null || true
        echo "  SQL dump attempted → $out/probing/"
      else
        echo "  SQL dump skipped: training not running"
      fi
    fi

    if [ "$inj" = "yes" ] && [ "$IS_DISK_LAT" != "1" ]; then
      stop_flag=1
    else
      stop_flag=0
    fi
    if [ "$cfg_failed" = "1" ]; then
      echo "  skip wait_done after cfg fail"
    elif wait_done "$out" "$stop_flag"; then
      echo "  COMPLETE"
    else
      echo "  FAILED"
      pipe_rc=1
    fi
    stop_sidecar
    if [ "$IS_DISK_LAT" = "1" ]; then disk_lat_restore; fi
  done
done
# 收尾可选 teardown（下一次 tick 会再 setup）
if [ "$IS_DISK_LAT" = "1" ] && [ "${DISK_LAT_KEEP_MOUNT:-1}" != "1" ]; then
  disk_lat_teardown || true
fi
echo ""; echo "╚═ v4 DONE case=$CASE grp=$GROUP_ID rc=$pipe_rc ═╝"
exit "$pipe_rc"
