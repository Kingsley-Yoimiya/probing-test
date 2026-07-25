#!/usr/bin/env bash
# yysong-worker-1 上：装 collect-min → torchrun 短训 → 验收 dump 非空。
# 标签: yjr-as-b-gh-*
set -euo pipefail

RUN_ID="${RUN_ID:-yjr-as-b-gh-$(date +%Y%m%d_%H%M%S)}"
ROOT="${FS_GH_ROOT:-/data/yinjinrun.p-huawei}"
BUNDLE="${ROOT}/probe-bundle/greyhound"
OUT="${ROOT}/results/ascend-ais/baseline/greyhound/${RUN_ID}"
NPROC="${NPROC:-16}"
ITERS="${ITERS:-20}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT" "$BUNDLE"
echo "RUN_ID=$RUN_ID OUT=$OUT NPROC=$NPROC"

# Ascend env（镜像常见路径；部分 set_env 在 set -u 下读 ZSH_VERSION 会炸）
set +u
for f in \
  /usr/local/Ascend/ascend-toolkit/set_env.sh \
  /usr/local/Ascend/cann-8.5.0/set_env.sh \
  /usr/local/Ascend/nnal/atb/set_env.sh
do
  # shellcheck disable=SC1090
  [[ -f "$f" ]] && source "$f" || true
done
set -u
# 确保 HCCL 库在动态链接路径里
export LD_LIBRARY_PATH="/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64:${LD_LIBRARY_PATH:-}"

bash "$SCRIPT_DIR/install_collect_min.sh" "$BUNDLE"
cp -a "$SCRIPT_DIR/smoke_allreduce.py" "$OUT/"
cp -a "$BUNDLE/libhcclprobe.so" "$OUT/" 2>/dev/null || true

export GREYHOUND_DUMP="$OUT/hcclprobe.collect.jsonl"
export GREYHOUND_STUB_MARKER="$OUT/hcclprobe.loaded"
export GREYHOUND_DEBUG=1
export GREYHOUND_HCCL_SO="${GREYHOUND_HCCL_SO:-/usr/local/Ascend/cann-8.5.0/aarch64-linux/lib64/libhccl.so}"
export FS_GREYHOUND_SO="$BUNDLE/libhcclprobe.so"
export LD_PRELOAD="$FS_GREYHOUND_SO${LD_PRELOAD:+:$LD_PRELOAD}"
# 避免写宋盘；结果只落本 OUT
export HCCL_IF_BASE_PORT="${HCCL_IF_BASE_PORT:-56000}"

: >"$GREYHOUND_DUMP"
rm -f "$GREYHOUND_STUB_MARKER"

echo "[run] LD_PRELOAD=$LD_PRELOAD" | tee "$OUT/run.log"
echo "[run] GREYHOUND_DUMP=$GREYHOUND_DUMP" | tee -a "$OUT/run.log"

set +e
torchrun --standalone --nproc_per_node="$NPROC" \
  "$OUT/smoke_allreduce.py" --iters "$ITERS" --count "$((1 << 20))" \
  >>"$OUT/run.log" 2>&1
RC=$?
set -e

echo "torchrun_rc=$RC" | tee -a "$OUT/run.log"
ls -la "$OUT" | tee -a "$OUT/run.log"
DUMP_LINES=0
if [[ -f "$GREYHOUND_DUMP" ]]; then
  DUMP_LINES=$(wc -l <"$GREYHOUND_DUMP" | tr -d ' ')
fi
echo "dump_lines=$DUMP_LINES marker=$([[ -f $GREYHOUND_STUB_MARKER ]] && echo yes || echo no)" | tee -a "$OUT/run.log"
head -3 "$GREYHOUND_DUMP" 2>/dev/null | tee -a "$OUT/run.log" || true

# 汇总
python3 - <<PY | tee "$OUT/SUMMARY.json"
import json, os
out = {
  "run_id": "$RUN_ID",
  "torchrun_rc": $RC,
  "nproc": $NPROC,
  "iters": $ITERS,
  "dump_lines": $DUMP_LINES,
  "marker": os.path.isfile("$GREYHOUND_STUB_MARKER"),
  "dump": "$GREYHOUND_DUMP",
  "collect_ok": $DUMP_LINES > 0,
  "s1_load_ok": $RC == 0 and os.path.isfile("$GREYHOUND_STUB_MARKER"),
}
print(json.dumps(out, indent=2))
PY

if [[ $RC -ne 0 ]]; then
  echo "FAIL torchrun rc=$RC" >&2
  exit $RC
fi
if [[ "$DUMP_LINES" -le 0 ]]; then
  echo "FAIL empty dump (collect_ok=no)" >&2
  exit 3
fi
echo "OK S1+S2 collect_ok=yes dump_lines=$DUMP_LINES"
