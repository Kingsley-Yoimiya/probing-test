#!/usr/bin/env bash
set -euo pipefail
source /root/miniconda3/etc/profile.d/conda.sh
conda activate llm_test
export PYTHONUNBUFFERED=1
export PATH=/root/miniconda3/envs/llm_test/bin:${PATH}
export PYTHONPATH=/data/yinjinrun.p-huawei/probe-bundle/pydeps:${PYTHONPATH:-}
export GLOO_SOCKET_IFNAME=${GLOO_SOCKET_IFNAME:-eth0}
export HCCL_CONNECT_TIMEOUT=${HCCL_CONNECT_TIMEOUT:-1800}
export HOST_BOUND_MATMUL=768
export CKPT_DIR=/data/yinjinrun.p-huawei/probe-bundle/io_stress/ckpt
unset PROBING PROBING_TORCH_PROFILING PROBING_GPU INLINE_INJECT 2>/dev/null || true; export PROBING=0;
OUT='/data/yinjinrun.p-huawei/results/ascend-ais/20260725_020212-yjr-as-c-p3-ext-b-loud/P3-EXT-B/by_pod/yysong-master-0/round_1/C1_inject_none'
rm -f "$OUT/node_0.done" "$OUT/node_0.fail"
rm -rf "$OUT/ranks"
mkdir -p "$OUT/ranks"
/root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node=16 --node_rank=0 \
  --master_addr=10.119.7.46 --master_port=30100 \
  /tmp/tbp_npu.py --iters=500 --warmup=50 --seed=42 --mode=host_bound --model=gpt2 --seq=1024 --batch=8 \
  --flush-every=1 --ckpt-every=20 \
  --io-payload='/data/yinjinrun.p-huawei/probe-bundle/io_stress/payload.bin' --io-read-kb=1024 \
  --run-id=20260725_020212-yjr-as-c-p3-ext-b-loud --group=1 --config='C1_inject_none' --round=1 \
  --out-dir="$OUT/ranks" > "$OUT/node_0.log" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then touch "$OUT/node_0.done"; else echo $rc > "$OUT/node_0.fail"; fi
