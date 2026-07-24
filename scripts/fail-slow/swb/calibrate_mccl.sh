#!/usr/bin/env bash
# calibrate_mccl.sh — 短 AllReduce 标定：默认 vs Ring/Simple + channels=4
#
# 在 PODS 上跑少量迭代、单消息尺寸（默认 64MiB），对比带宽/时延。
# 结果写 LOCAL_RESULT_ROOT 或 /tmp。
#
# 用法:
#   PODS=yjr-swb-0,yjr-swb-1 KUBECONFIG=... NNODES=2 NPROC=8 \
#   bash calibrate_mccl.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
NNODES="${NNODES:-2}"
NPROC="${NPROC:-8}"
ITERS="${ITERS:-20}"
WARMUP="${WARMUP:-5}"
BYTES="${BYTES:-$((64*1024*1024))}"   # 64 MiB
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle/swb}"
TS="$(date +%Y%m%d_%H%M%S)"
LOCAL_RESULT_ROOT="${LOCAL_RESULT_ROOT:-/tmp/swb_mccl_calibrate_$TS}"
mkdir -p "$LOCAL_RESULT_ROOT"

IFS=',' read -r -a POD_ARR <<< "$PODS"
MASTER="${POD_ARR[0]}"
MASTER_IP=$(kubectl --kubeconfig="$KUBECONFIG" -n "$NS" get pod "$MASTER" -o jsonpath='{.status.podIP}')
[ -z "$MASTER_IP" ] && { echo "FATAL: no IP for $MASTER"; exit 2; }
PORT="${PORT:-29555}"

# 嵌入短标定脚本到 master，再 torchrun 全并行
CAL_PY=$(cat <<'PY'
#!/usr/bin/env python3
"""短 AllReduce 带宽标定（默认 MCCL vs 强制 Ring/Simple ch=4）。"""
from __future__ import annotations
import json, os, time
import torch
import torch.distributed as dist

def main() -> None:
    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local = int(os.environ.get("LOCAL_RANK", 0))
    torch.cuda.set_device(local)
    nbytes = int(os.environ.get("CAL_BYTES", str(64 * 1024 * 1024)))
    iters = int(os.environ.get("CAL_ITERS", "20"))
    warmup = int(os.environ.get("CAL_WARMUP", "5"))
    tag = os.environ.get("CAL_TAG", "default")
    nelem = nbytes // 4  # float32
    buf = torch.randn(nelem, device=f"cuda:{local}", dtype=torch.float32)
    # warmup
    for _ in range(warmup):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    dist.barrier()
    t0 = time.perf_counter()
    for _ in range(iters):
        dist.all_reduce(buf)
    torch.cuda.synchronize()
    t1 = time.perf_counter()
    ms = (t1 - t0) * 1e3 / max(1, iters)
    # bus bandwidth approx: 2*(n-1)/n * size / time  (ring AllReduce)
    alg_bw = (nbytes / 1e9) / (ms / 1e3)  # GB/s algorithmic
    bus_bw = alg_bw * (2.0 * (world - 1) / world) if world > 1 else alg_bw
    rec = {
        "tag": tag,
        "rank": rank,
        "world": world,
        "bytes": nbytes,
        "iters": iters,
        "ms_per_iter": round(ms, 4),
        "alg_bw_GBs": round(alg_bw, 4),
        "bus_bw_GBs": round(bus_bw, 4),
        "MCCL_ALGO": os.environ.get("MCCL_ALGO", ""),
        "MCCL_PROTO": os.environ.get("MCCL_PROTO", ""),
        "MCCL_MIN_NCHANNELS": os.environ.get("MCCL_MIN_NCHANNELS", ""),
        "MCCL_MAX_NCHANNELS": os.environ.get("MCCL_MAX_NCHANNELS", ""),
    }
    out = os.environ.get("CAL_OUT", f"/tmp/cal_{tag}_rank{rank}.json")
    if rank == 0:
        with open(out, "w") as f:
            json.dump(rec, f, indent=2)
            f.write("\n")
        print(json.dumps(rec), flush=True)
    dist.barrier()
    dist.destroy_process_group()

if __name__ == "__main__":
    main()
PY
)

run_one() {  # $1=tag $2=extra_env
  local tag="$1" extra="$2"
  local out_pod="/tmp/swb_cal_${tag}.json"
  echo "── calibrate tag=$tag ──"
  # 推脚本
  for p in "${POD_ARR[@]}"; do
    printf '%s' "$CAL_PY" | kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec -i "$p" -- \
      bash -c "cat > $LOCAL_CODE/calibrate_mccl_inner.py" 2>/dev/null || true
  done
  # 发射
  local n
  for ((n=0; n<NNODES; n++)); do
    kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "${POD_ARR[$n]}" -- bash -c "
      export PATH=/opt/conda/bin:\$PATH
      export NCCL_SOCKET_IFNAME=eth0 MCCL_SOCKET_IFNAME=eth0
      export NCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
      export MCCL_IB_HCA=xscale_0,xscale_1,xscale_2,xscale_3
      export NCCL_IB_GID_INDEX=5 MCCL_IB_GID_INDEX=5 MCCL_IB_TC=128
      export MCCL_ENABLE_VSWITCH=1
      export CAL_BYTES=$BYTES CAL_ITERS=$ITERS CAL_WARMUP=$WARMUP CAL_TAG=$tag CAL_OUT=$out_pod
      $extra
      cd $LOCAL_CODE
      setsid nohup /opt/conda/bin/torchrun --nnodes=$NNODES --nproc_per_node=$NPROC --node_rank=$n \
        --master_addr=$MASTER_IP --master_port=$PORT \
        calibrate_mccl_inner.py > /tmp/swb_cal_${tag}_n${n}.log 2>&1 &
      echo ok; exit 0
    " 2>/dev/null &
  done
  wait || true
  # 等 master 结果
  local e=0
  while [ $e -lt 180 ]; do
    if kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$MASTER" -- test -f "$out_pod" 2>/dev/null; then
      kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$MASTER" -- cat "$out_pod" \
        > "$LOCAL_RESULT_ROOT/cal_${tag}.json"
      echo "  ok → $LOCAL_RESULT_ROOT/cal_${tag}.json"
      return 0
    fi
    sleep 2; e=$((e+2))
  done
  echo "  TIMEOUT tag=$tag"
  kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$MASTER" -- \
    tail -n 30 "/tmp/swb_cal_${tag}_n0.log" 2>/dev/null || true
  return 1
}

# 清理残留
for p in "${POD_ARR[@]}"; do
  kubectl --kubeconfig="$KUBECONFIG" -n "$NS" exec "$p" -- \
    bash -c "pkill -9 -f '[c]alibrate_mccl_inner' 2>/dev/null || true; pkill -9 -f '[t]orchrun' 2>/dev/null || true; exit 0" 2>/dev/null &
done
wait || true
sleep 2

run_one "default" "unset MCCL_ALGO MCCL_PROTO MCCL_MIN_NCHANNELS MCCL_MAX_NCHANNELS 2>/dev/null || true"
# 换端口避免残留
PORT=$((PORT + 1))
sleep 3
run_one "ring_simple_ch4" \
  "export MCCL_ALGO=Ring MCCL_PROTO=Simple MCCL_MIN_NCHANNELS=4 MCCL_MAX_NCHANNELS=4"

# 摘要
python3 - <<PY
import json
from pathlib import Path
root = Path("$LOCAL_RESULT_ROOT")
rows = {}
for p in sorted(root.glob("cal_*.json")):
    rows[p.stem] = json.loads(p.read_text())
print("=== MCCL calibrate summary ===")
lines = []
for k, v in rows.items():
    line = (
        f"{k}: bus_bw={v.get('bus_bw_GBs')} GB/s  ms={v.get('ms_per_iter')}  "
        f"algo={v.get('MCCL_ALGO')}/{v.get('MCCL_PROTO')} "
        f"ch={v.get('MCCL_MIN_NCHANNELS')}-{v.get('MCCL_MAX_NCHANNELS')}"
    )
    print(line)
    lines.append(line)
if "cal_default" in rows and "cal_ring_simple_ch4" in rows:
    a, b = rows["cal_default"]["bus_bw_GBs"], rows["cal_ring_simple_ch4"]["bus_bw_GBs"]
    if a and b and b > 0:
        r = f"ratio default/ch4 = {a/b:.3f}  (fabric loud 参考 ~2.14)"
        print(r)
        lines.append(r)
(root / "SUMMARY.txt").write_text("\n".join(lines) + "\n")
print("wrote", root)
PY

echo "CALIBRATE_DONE root=$LOCAL_RESULT_ROOT"
