#!/usr/bin/env bash
# pull_campaign_results.sh — 增量回拉 AFS 结果到本机(掉机保险)
#
# 盯 AFS 上每个 case 的 .case_done marker, 一出现即经 master pod tar 回拉;
# 另可周期性拉"在跑 case"的 ranks 做残缺备份。
# AFS 多节点共享 → 只需经任一 pod(通常 master)一次 tar 即拉全组结果。
#
# 用法(一次性拉全部已完成):
#   MASTER_POD=p0 AFS_RUN_DIR=/afs-.../results/<run_id> RUN_ID=<run_id> \
#   KUBECONFIG=~/.kube/... bash pull_campaign_results.sh
#
# 用法(watch 模式, 每 60s 拉新完成的):
#   WATCH=1 ... bash pull_campaign_results.sh
set -uo pipefail

# AFS 模式需 MASTER_POD/AFS_RUN_DIR; LOCAL_FS 模式需 PODS_ALL(见文末分支)
MASTER_POD="${MASTER_POD:-}"
AFS_RUN_DIR="${AFS_RUN_DIR:-}"
RUN_ID="${RUN_ID:?need RUN_ID}"
KC="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
LOCAL_ROOT="${LOCAL_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)/results/muxi-h3c/$RUN_ID}"
WATCH="${WATCH:-0}"
INTERVAL="${INTERVAL:-60}"

mkdir -p "$LOCAL_ROOT"
kx() { kubectl --kubeconfig="$KC" -n "$NS" "$@"; }

pull_case() {   # $1=case_id
  local cid="$1"
  local dst="$LOCAL_ROOT/$cid"
  mkdir -p "$dst"
  echo "  ↓ $cid → $dst"
  kx exec -i "$MASTER_POD" -- bash -c "tar -C '$AFS_RUN_DIR/$cid' -cf - . 2>/dev/null" > "$dst/.pull.tar" 2>/dev/null
  if [ -s "$dst/.pull.tar" ]; then
    tar -C "$dst" -xf "$dst/.pull.tar" && rm -f "$dst/.pull.tar"
    local n; n=$(find "$dst" -name 'rank_*.jsonl' | wc -l | tr -d ' ')
    echo "    ✓ $cid: $n rank files"
  else
    echo "    ⚠ $cid: empty tar"; rm -f "$dst/.pull.tar"
  fi
}

list_done() {
  kx exec "$MASTER_POD" -- bash -c "ls -d '$AFS_RUN_DIR'/*/ 2>/dev/null | while read d; do test -f \"\$d/.case_done\" && basename \"\$d\"; done" 2>/dev/null
}

pulled_marker() { echo "$LOCAL_ROOT/.pulled_$1"; }

do_round() {
  local done_cases; done_cases=$(list_done)
  [ -z "$done_cases" ] && { echo "  (无已完成 case)"; return; }
  while read -r cid; do
    [ -z "$cid" ] && continue
    if [ ! -f "$(pulled_marker "$cid")" ]; then
      pull_case "$cid"
      touch "$(pulled_marker "$cid")"
    fi
  done <<< "$done_cases"
}

if [ "$WATCH" = "1" ]; then
  echo "watch 模式: 每 ${INTERVAL}s 拉新完成的 case → $LOCAL_ROOT"
  while true; do
    echo "[$(date +%H:%M:%S)] 检查..."
    do_round
    sleep "$INTERVAL"
  done
elif [ "${LOCAL_FS:-0}" = "1" ]; then
  # 本地盘模式: 结果散在各 pod 本地 /workspace/probe-bundle/out, 逐 pod tar 回拉
  # 需传 PODS_ALL(csv) 与 LOCAL_OUT(pod 内路径, 默认 /workspace/probe-bundle/out)
  LOCAL_OUT="${LOCAL_OUT:-/workspace/probe-bundle/out}"
  IFS=',' read -r -a ALLP <<< "${PODS_ALL:?LOCAL_FS 模式需 PODS_ALL csv}"
  echo "本地盘回拉: ${#ALLP[@]} 台 pod 的 $LOCAL_OUT → $LOCAL_ROOT"
  for pod in "${ALLP[@]}"; do
    dst="$LOCAL_ROOT/by_pod/$pod"; mkdir -p "$dst"
    kx exec -i "$pod" -- bash -c "tar -C '$LOCAL_OUT' -cf - . 2>/dev/null" > "$dst/.pull.tar" 2>/dev/null
    if [ -s "$dst/.pull.tar" ]; then
      tar -C "$dst" -xf "$dst/.pull.tar" && rm -f "$dst/.pull.tar"
      n=$(find "$dst" -name 'rank_*.jsonl' | wc -l | tr -d ' ')
      echo "  ✓ $pod: $n rank files"
    else
      echo "  ⚠ $pod: 无数据"; rm -f "$dst/.pull.tar"
    fi
  done
  echo "完成. 本机: $LOCAL_ROOT/by_pod/  (各 case 目录在 <pod>/<case>/)"
else
  echo "一次性回拉已完成 case → $LOCAL_ROOT"
  do_round
  echo "完成. 本机: $LOCAL_ROOT"
fi
