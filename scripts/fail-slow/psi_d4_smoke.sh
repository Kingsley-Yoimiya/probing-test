#!/usr/bin/env bash
# P3 D4 短探索：A0 基线 → A1 stress 20s → A3 回落；并行记 PSI，不跑长训。
# 在 victim pod 内执行，或由本机 kubectl exec 调用。
set -euo pipefail

OUT="${OUT:?need OUT}"
CPU_N="${CPU_N:-16}"
STRESS_S="${STRESS_S:-20}"
BASE_S="${BASE_S:-10}"
COOL_S="${COOL_S:-10}"
SAMPLE_DT="${SAMPLE_DT:-2}"

mkdir -p "$OUT"
TSV="$OUT/pressure_samples.tsv"
SUMMARY="$OUT/SUMMARY.md"
: >"$TSV"
echo -e "phase\telapsed_s\tresource\tline" >>"$TSV"

sample_psi() {
  local phase="$1" el="$2"
  local r f
  for r in cpu memory io; do
    f="/proc/pressure/$r"
    if [ -r "$f" ]; then
      while IFS= read -r line; do
        echo -e "${phase}\t${el}\t${r}\t${line}"
      done <"$f"
    else
      echo -e "${phase}\t${el}\t${r}\tMISSING"
    fi
  done
  echo -e "${phase}\t${el}\tloadavg\t$(cat /proc/loadavg)"
}

phase_loop() {
  local phase="$1" dur="$2"
  local t=0
  while [ "$t" -le "$dur" ]; do
    sample_psi "$phase" "$t" >>"$TSV"
    [ "$t" -ge "$dur" ] && break
    sleep "$SAMPLE_DT"
    t=$((t + SAMPLE_DT))
  done
}

parse_avg10() {
  local phase="$1"
  awk -F'\t' -v p="$phase" '
    $1==p && $3=="cpu" && $4 ~ /^some / { print $4; exit }
  ' "$TSV" | sed -n 's/.*avg10=\([0-9.]*\).*/\1/p'
}

echo "[psi_d4_smoke] OUT=$OUT CPU_N=$CPU_N STRESS=${STRESS_S}s"
pkill -9 stress-ng 2>/dev/null || true
sleep 1

echo "[A0] baseline ${BASE_S}s"
phase_loop A0 "$BASE_S"
A0_AVG=$(parse_avg10 A0 || echo 0)

echo "[A1] stress-ng --cpu $CPU_N --timeout ${STRESS_S}s"
stress-ng --cpu "$CPU_N" --timeout "${STRESS_S}s" >"$OUT/stress.log" 2>&1 &
SPID=$!
phase_loop A1 "$STRESS_S"
wait "$SPID" || true
A1_AVG=$(parse_avg10 A1 || echo 0)

echo "[A3] cool ${COOL_S}s"
phase_loop A3 "$COOL_S"
A3_AVG=$(parse_avg10 A3 || echo 0)

# totals delta for cpu some (more sensitive than avg10 on short windows)
psi_total_line() {
  local phase="$1" which="$2" # which=first|last
  if [ "$which" = first ]; then
    awk -F'\t' -v p="$phase" '$1==p && $3=="cpu" && $4 ~ /^some / { print $4; exit }' "$TSV"
  else
    awk -F'\t' -v p="$phase" '$1==p && $3=="cpu" && $4 ~ /^some / { line=$4 } END { print line }' "$TSV"
  fi
}
extract_total() { sed -n 's/.*total=\([0-9]*\).*/\1/p'; }
A0_T0=$(psi_total_line A0 first | extract_total)
A0_T1=$(psi_total_line A0 last | extract_total)
A1_T0=$(psi_total_line A1 first | extract_total)
A1_T1=$(psi_total_line A1 last | extract_total)
A0_DT=$(( ${A0_T1:-0} - ${A0_T0:-0} ))
A1_DT=$(( ${A1_T1:-0} - ${A1_T0:-0} ))

{
  echo "# P3 D4 PSI smoke"
  echo
  echo "- host: $(hostname) ts=$(date -Iseconds)"
  echo "- stress: stress-ng --cpu $CPU_N --timeout ${STRESS_S}s"
  echo
  echo "| phase | cpu.some avg10 (last sample in phase) | cpu.some total Δ (us) |"
  echo "|---|---:|---:|"
  echo "| A0 baseline | ${A0_AVG:-?} | ${A0_DT} |"
  echo "| A1 stress | ${A1_AVG:-?} | ${A1_DT} |"
  echo "| A3 cool | ${A3_AVG:-?} | — |"
  echo
  if [ "${A1_DT:-0}" -gt $(( ${A0_DT:-0} * 3 + 1000000 )) ] 2>/dev/null || \
     awk -v a="${A1_AVG:-0}" -v b="${A0_AVG:-0}" 'BEGIN{exit !(a>=b+5 || a>b*1.5 && a>b+1)}'; then
    echo "**判据：PASS** — 外部 CPU stress 在 PSI 上可见（相对基线抬升）。"
    echo "PSI_VISIBLE=yes" >"$OUT/verdict.env"
  else
    echo "**判据：WEAK** — avg10/total 抬升不足，需加大 CPU_N 或延长窗。"
    echo "PSI_VISIBLE=weak" >"$OUT/verdict.env"
  fi
  echo
  echo "原始采样：\`pressure_samples.tsv\`"
} | tee "$SUMMARY"

echo "[psi_d4_smoke] done → $SUMMARY"
cat "$OUT/verdict.env"
