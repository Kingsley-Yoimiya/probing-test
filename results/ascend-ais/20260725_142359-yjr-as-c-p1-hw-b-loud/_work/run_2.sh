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
export CKPT_DIR=/data/yinjinrun.p-huawei/probe-bundle/ckpt
export PROBING=2; unset PROBING_TORCH_PROFILING; export PROBING_GPU=on; export PROBING_GPU_BACKEND=npu; export PROBING_NPU_SOURCE=auto; export PROBING_GPU_SAMPLE_MS=1000; export PROBING_CPU=on; export PROBING_CPU_SAMPLE_MS=1000; export PYTHONPATH=/data/yinjinrun.p-huawei/probe-bundle/pydeps:${PYTHONPATH:-}; export PATH=/data/yinjinrun.p-huawei/probe-bundle/pydeps/bin:/root/miniconda3/envs/llm_test/bin:${PATH}; export INLINE_INJECT=hbm; export INLINE_VICTIM_LOCAL_RANK=7; export INLINE_INJECT_START=100; export INLINE_INJECT_STOP=300; export INLINE_HBM_MB=512; export INLINE_HBM_COPIES=6; export INLINE_HBM_COPIES_MAX=48; export INLINE_HBM_RAMP=1; export INLINE_HBM_RAMP=1;
OUT='/data/yinjinrun.p-huawei/results/ascend-ais/20260725_142359-yjr-as-c-p1-hw-b-loud/P1-HW-B/by_pod/yysong-master-0/round_1/C2_probing'
rm -f "$OUT/node_0.done" "$OUT/node_0.fail"
rm -rf "$OUT/ranks"
mkdir -p "$OUT/ranks"
/root/miniconda3/envs/llm_test/bin/torchrun --nnodes=1 --nproc_per_node=16 --node_rank=0 \
  --master_addr=10.119.7.46 --master_port=30200 \
  /tmp/tbp_npu.py --iters=500 --warmup=50 --seed=42 --mode=gpu_bound --model=gpt2 --seq=1024 --batch=8 \
  --flush-every=5 --ckpt-every=100 \
  --io-payload='' --io-read-kb=0 \
  --run-id=20260725_142359-yjr-as-c-p1-hw-b-loud --group=2 --config='C2_probing' --round=1 \
  --out-dir="$OUT/ranks" > "$OUT/node_0.log" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then touch "$OUT/node_0.done"; else echo $rc > "$OUT/node_0.fail"; fi
