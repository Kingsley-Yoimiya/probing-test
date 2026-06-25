#!/usr/bin/env bash
# 一键：构建 Web UI + 重跑实验 + 更新文档素材
set -eo pipefail
ROOT="/home/yjr/probing-test"
cd "$ROOT"

echo "=== [1/2] 构建 Probing Web UI (Docker) ==="
if [[ ! -f probing/web/dist/index.html ]] || ! grep -q 'web-dxh' probing/web/dist/index.html 2>/dev/null; then
  bash scripts/build_frontend_docker.sh
else
  echo "web/dist 已存在，跳过构建（删除 web/dist 可强制重建）"
fi

echo "=== [2/3] 采集 CLI + Web 截图 + 热力图 ==="
unset PROBING_CLI_MODE
bash scripts/capture_viz_demo.sh

echo ""
echo "=== [3/3] 校验文档素材引用 ==="
bash scripts/verify_doc_assets.sh

echo ""
echo "完成。文档：docs/probing-visualization-guide.md"
echo "素材：docs/assets/latest/（含 web_training_heatmap.png）"
