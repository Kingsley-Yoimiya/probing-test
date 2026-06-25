#!/usr/bin/env bash
# 4 卡一键采集：DDP 热力图 + Megatron 126M×4 DP Web/CLI 素材
set -eo pipefail
ROOT="/home/yjr/probing-test"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/logs/capture_4gpu_$TS"
mkdir -p "$LOG"

echo "=== [1/2] 4-GPU DDP Step 热力图 ===" | tee "$LOG/summary.log"
bash "$ROOT/scripts/capture_training_heatmap.sh" 2>&1 | tee "$LOG/heatmap.log"
sleep 5
pkill -f "demo_ddp_train_viz.py" 2>/dev/null || true
sleep 3

echo "=== [2/2] 4-GPU Megatron gpt126m_4dp ===" | tee -a "$LOG/summary.log"
bash "$ROOT/scripts/capture_megatron_web.sh" 2>&1 | tee "$LOG/megatron.log"

echo "=== 校验文档引用 ===" | tee -a "$LOG/summary.log"
bash "$ROOT/scripts/verify_doc_assets.sh" | tee -a "$LOG/summary.log"

echo "4 卡采集完成，素材: docs/assets/latest/ 日志: $LOG"
