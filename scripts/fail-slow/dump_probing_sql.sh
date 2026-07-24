#!/usr/bin/env bash
# C2 注入窗内：对训练进程做 Probing SQL 落盘（进程必须存活且已挂 probing）。
#
# 环境：
#   OUT_DIR   = …/C2_probing（写 probing/ 子目录）
#   CASE      = P1-EXT-A|P1-EXT-B|P3-EXT-A|…
#   CODE_DIR  = /workspace/probe-bundle（含 pydeps）
#   VICTIM_LOCAL_RANK 默认 7
set -uo pipefail

OUT_DIR="${OUT_DIR:?need OUT_DIR}"
CASE="${CASE:-unknown}"
CODE_DIR="${CODE_DIR:-/workspace/probe-bundle}"
VICTIM_LOCAL_RANK="${VICTIM_LOCAL_RANK:-7}"
PYTHONPATH="${CODE_DIR}/pydeps${PYTHONPATH:+:$PYTHONPATH}"
export PATH="${CODE_DIR}/pydeps/bin:/opt/conda/bin:${PATH:-}"
export PYTHONPATH
# 切勿注入 maca cu-bridge libcuda：cudarc 缺符号会拖垮训练进程

DUMP="$OUT_DIR/probing"
mkdir -p "$DUMP"
MANIFEST="$DUMP/query_manifest.json"
TS=$(date -Iseconds)

# 候选 PID：victim local_rank 优先，再扫全部 tbp worker
candidate_pids() {
  local prefer="$1"
  ps -eo pid,args | awk -v lr="$prefer" '
    /train_bench_probe|\/tmp\/tbp\.py/ && $0 !~ /awk/ && $0 !~ /bash/ {
      score = 1
      if ($0 ~ ("local[_-]rank[= ]*" lr) || $0 ~ ("LOCAL_RANK=" lr)) score = 0
      print score, $1
    }' | sort -n | awk '{print $2}'
}

probe_alive() {
  local pid="$1"
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
  probing -t "$pid" query "SHOW TABLES" >"$DUMP/_probe_ping.txt" 2>&1
}

PID=""
ATTACH="no"
for cand in $(candidate_pids "$VICTIM_LOCAL_RANK"); do
  if probe_alive "$cand"; then
    PID="$cand"
    ATTACH="ok"
    break
  fi
done

echo "dump_probing_sql case=$CASE out=$DUMP pid=${PID:-none} attach=$ATTACH ts=$TS" | tee "$DUMP/dump.log"

# Host PSI（系统级 CPU 压力）：不依赖进程表，作 P3 EXT 旁路证据（非 injection.log）
sample_pressure_block() {
  local tag="$1"
  local r
  echo "### $tag $(date -Iseconds)"
  for r in cpu memory io; do
    if [ -r "/proc/pressure/$r" ]; then
      echo "resource=$r"
      cat "/proc/pressure/$r"
    else
      echo "resource=$r MISSING"
    fi
  done
  echo "loadavg=$(cat /proc/loadavg)"
}

collect_host_pressure() {
  local f0="$DUMP/host_pressure_t0.txt"
  local f1="$DUMP/host_pressure_t1.txt"
  local dt="${HOST_PRESSURE_DT_S:-2}"
  sample_pressure_block t0 >"$f0"
  sleep "$dt"
  sample_pressure_block t1 >"$f1"
  python3 - <<PY
import json, re
from pathlib import Path
dump = Path("$DUMP")
dt = float("$dt")

def parse(path: Path):
    out = {}
    cur = None
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("resource="):
            cur = line.split("=", 1)[1].strip()
            out[cur] = {}
            continue
        if cur and (line.startswith("some ") or line.startswith("full ")):
            kind = line.split()[0]
            d = {"raw": line}
            for k, v in re.findall(r"(avg10|avg60|avg300|total)=([0-9.]+)", line):
                d[k] = float(v) if k != "total" else int(float(v))
            out[cur][kind] = d
        if line.startswith("loadavg="):
            out["loadavg"] = line.split("=", 1)[1].strip()
    return out

t0 = parse(dump / "host_pressure_t0.txt")
t1 = parse(dump / "host_pressure_t1.txt")

def rate(res, kind="some"):
    a = (t0.get(res) or {}).get(kind) or {}
    b = (t1.get(res) or {}).get(kind) or {}
    if "total" not in a or "total" not in b or dt <= 0:
        return None
    return (b["total"] - a["total"]) / dt

cpu_rate = rate("cpu", "some")
io_rate = rate("io", "some")
mem_rate = rate("memory", "some")
avg10 = ((t1.get("cpu") or {}).get("some") or {}).get("avg10")
# 标定：128 核机 2×nproc stress 时 cpu_rate≈8e5 us/s；基线≈4e4。阈值取 2e5。
cpu_thresh = float("${HOST_PSI_CPU_RATE_THRESH:-200000}")
# P3-EXT-B 短标定：fio randrw×8 的 io.some≈1.49e5 us/s，基线≈23 us/s。
# 默认 5e4 仅用于识别该明显分离的压力窗；正式战役可用环境变量抬高。
io_thresh = float("${HOST_PSI_IO_RATE_THRESH:-50000}")
cpu_hit = cpu_rate is not None and cpu_rate >= cpu_thresh
io_hit = io_rate is not None and io_rate >= io_thresh
io_dom = (io_rate or 0) > (cpu_rate or 0) * 0.5 and (io_rate or 0) > cpu_thresh * 0.5
mem_dom_cpu = (mem_rate or 0) > (cpu_rate or 0) * 0.5 and (mem_rate or 0) > cpu_thresh * 0.5
mem_dom_io = (mem_rate or 0) > (io_rate or 0) * 0.5 and (mem_rate or 0) > io_thresh * 0.5
case = "$CASE"
if case == "P3-EXT-B":
    hit = bool(io_hit and not mem_dom_io)
    evidence = "host_psi_io" if hit else "host_psi_io_no_hit"
    threshold = io_thresh
else:
    hit = bool(cpu_hit and not io_dom and not mem_dom_cpu)
    evidence = "host_psi_cpu" if hit else "host_psi_no_hit"
    threshold = cpu_thresh
hp = {
    "dt_s": dt,
    "cpu_some_rate_us_s": cpu_rate,
    "io_some_rate_us_s": io_rate,
    "memory_some_rate_us_s": mem_rate,
    "cpu_some_avg10_t1": avg10,
    "threshold_cpu_rate_us_s": cpu_thresh,
    "threshold_io_rate_us_s": io_thresh,
    "threshold_rate_us_s": threshold,
    "hit": hit,
    "evidence": evidence,
    "t0": t0,
    "t1": t1,
}
(dump / "host_pressure.json").write_text(json.dumps(hp, indent=2, ensure_ascii=False) + "\n")
# 便于人工扫一眼
lines = [
    f"cpu_some_rate_us_s={cpu_rate}",
    f"io_some_rate_us_s={io_rate}",
    f"memory_some_rate_us_s={mem_rate}",
    f"cpu_some_avg10_t1={avg10}",
    f"threshold_cpu={cpu_thresh}",
    f"threshold_io={io_thresh}",
    f"threshold={threshold}",
    f"hit={hit}",
    f"evidence={hp['evidence']}",
]
(dump / "host_pressure.tsv").write_text("\n".join(lines) + "\n")
print(json.dumps({"host_pressure_hit": hit, "cpu_rate": cpu_rate}, ensure_ascii=False))
PY
}

collect_host_pressure || echo "WARN: host_pressure collect failed" | tee -a "$DUMP/dump.log"

# Host GPU（MetaX mx-smi）：CudaBackend 起不来时 gpu.utilization 永不建表；
# 同窗 mx-smi 作 P1-EXT 旁路（对标 P3 的 host_psi_*）。禁止仅靠 injection.log。
collect_host_gpu() {
  local dev="${VICTIM_LOCAL_RANK:-7}"
  local usage_f="$DUMP/host_gpu_usage.txt"
  local hbm_f="$DUMP/host_gpu_hbm.txt"
  local proc_f="$DUMP/host_gpu_process.txt"
  local mx
  mx="$(command -v mx-smi || true)"
  if [ -z "$mx" ]; then
    echo "WARN: mx-smi not found" | tee -a "$DUMP/dump.log"
    return 1
  fi
  "$mx" -i "$dev" --show-usage >"$usage_f" 2>&1 || true
  "$mx" -i "$dev" --show-hbm-bandwidth >"$hbm_f" 2>&1 || true
  "$mx" --show-process >"$proc_f" 2>&1 || true
  python3 - <<PY
import json, re
from pathlib import Path
dump = Path("$DUMP")
dev = int("$dev")
case = "$CASE"
usage = (dump / "host_gpu_usage.txt").read_text(errors="ignore")
hbm = (dump / "host_gpu_hbm.txt").read_text(errors="ignore")
proc = (dump / "host_gpu_process.txt").read_text(errors="ignore")

def gpu_util_pct(text: str):
    # "GPU                                       : 97 %"
    m = re.search(r"GPU\s*:\s*([0-9.]+)\s*%", text)
    return float(m.group(1)) if m else None

def hbm_mbs(text: str):
    # "throughput                                : 12345 MBytes/s"
    m = re.search(r"throughput\s*:\s*([0-9.]+)\s*MBytes/s", text, re.I)
    return float(m.group(1)) if m else None

util = gpu_util_pct(usage)
hbm_bw = hbm_mbs(hbm)
# 进程表：除表头外是否有 PID 行
proc_lines = [l for l in proc.splitlines() if re.search(r"\b\d{2,}\b", l) and "PID" not in l]
n_procs = len(proc_lines)
has_sidecar = bool(re.search(r"sidecar_inject", proc, re.I))

util_thr = float("${HOST_GPU_UTIL_THRESH:-50}")
hbm_thr = float("${HOST_HBM_BW_THRESH_MBS:-500}")  # idle≈1；内联 HBM Loud 应远高于此
if case == "P1-EXT-B":
    hit = hbm_bw is not None and hbm_bw >= hbm_thr
    evidence = "host_mx_smi_hbm_bw" if hit else "host_mx_smi_hbm_no_hit"
elif case.startswith("P1-EXT"):
    hit = bool(
        (util is not None and util >= util_thr)
        or has_sidecar
        or n_procs >= 2
    )
    if hit and has_sidecar:
        evidence = "host_mx_smi_sidecar_proc"
    elif hit and util is not None and util >= util_thr:
        evidence = "host_mx_smi_gpu_util"
    elif hit:
        evidence = "host_mx_smi_multi_proc"
    else:
        evidence = "host_mx_smi_no_hit"
else:
    hit = False
    evidence = "host_mx_smi_unused"

blob = {
    "device": dev,
    "gpu_util_pct": util,
    "hbm_bw_mbs": hbm_bw,
    "n_procs": n_procs,
    "has_sidecar_inject": has_sidecar,
    "threshold_gpu_util_pct": util_thr,
    "threshold_hbm_bw_mbs": hbm_thr,
    "hit": bool(hit),
    "evidence": evidence,
}
(dump / "host_gpu.json").write_text(json.dumps(blob, indent=2, ensure_ascii=False) + "\n")
(dump / "host_gpu.tsv").write_text(
    "\n".join(f"{k}={v}" for k, v in blob.items()) + "\n"
)
print(json.dumps({"host_gpu_hit": hit, "evidence": evidence, "hbm_bw_mbs": hbm_bw, "gpu_util_pct": util}, ensure_ascii=False))
PY
}

collect_host_gpu || echo "WARN: host_gpu collect failed" | tee -a "$DUMP/dump.log"

run_q() {
  local name="$1" sql="$2"
  local f="$DUMP/query_${name}.txt"
  echo "SQL: $sql" >"$f"
  echo "----" >>"$f"
  if [ -z "${PID:-}" ] || [ "$ATTACH" != "ok" ]; then
    echo "error=no_probing_attach" >>"$f"
    echo "$name|error=no_probing_attach" >>"$DUMP/status.tsv"
    return 1
  fi
  set +e
  probing -t "$PID" query "$sql" >>"$f" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "error=query_rc_$rc" >>"$f"
    echo "$name|error=query_rc_$rc" >>"$DUMP/status.tsv"
    return 1
  fi
  if grep -qiE "table .* not found|QueryError|Error during planning|Connection refused" "$f"; then
    echo "$name|error=table_or_query" >>"$DUMP/status.tsv"
    return 1
  fi
  echo "$name|ok" >>"$DUMP/status.tsv"
  return 0
}

: >"$DUMP/status.tsv"

if [ "$ATTACH" = "ok" ]; then
  cp -f "$DUMP/_probe_ping.txt" "$DUMP/tables.txt" 2>/dev/null || true
  {
    # 正确 option 名；MetaX 上 CudaBackend 常失败 → SET 也可能失败，仅记日志
    probing -t "$PID" query "SET probing.gpu.gpu_sample_interval_ms=1000" 2>&1 || true
    probing -t "$PID" query "SET probing.gpu.sample_interval=1000" 2>&1 || true
    sleep 2
    probing -t "$PID" query "SHOW TABLES" 2>&1 || true
  } >"$DUMP/gpu_enable.log" || true
  probing -t "$PID" query "SHOW TABLES" >"$DUMP/tables.txt" 2>&1 || true
else
  echo "error=no_probing_attach (Connection refused on all tbp PIDs; check PROBING site_hook)" >"$DUMP/tables.txt"
fi

run_q show_tables "SHOW TABLES" || true
run_q torch_trace_tail \
  "SELECT timestamp, step, module, stage, duration, allocated FROM python.torch_trace ORDER BY timestamp DESC LIMIT 50" || true
run_q gpu_util \
  "SELECT ts, device_id, name, gpu_util_pct, mem_used_pct, used_bytes FROM gpu.utilization ORDER BY ts DESC LIMIT 100" || true
run_q cpu_util \
  "SELECT ts, scope, cpu_total_pct, rss_kb, thread_count, comm FROM cpu.utilization ORDER BY ts DESC LIMIT 100" || true
run_q process_gpu_users "SELECT * FROM process.gpu_users LIMIT 20" || true
run_q process_cpu_stats "SELECT * FROM process.cpu_stats LIMIT 20" || true
# 主线常无 process.*。cpu.tasks 实测多为本进程线程（见不到 host stress-ng）；仍落盘供对照。
run_q cpu_tasks "SELECT * FROM cpu.tasks LIMIT 50" || true

case "$CASE" in
  P1-EXT-A|P1-EXT-B)
    run_q p1_gpu_window \
      "SELECT ts, device_id, gpu_util_pct, mem_used_pct FROM gpu.utilization ORDER BY ts DESC LIMIT 200" || true
    # MetaX 常无 gpu.utilization；envs 可旁证内联注入开关（主证据仍走 host_gpu.json）
    run_q p1_process_envs \
      "SELECT key, value FROM process.envs WHERE key LIKE 'INLINE%' OR key LIKE 'MACA%' OR key LIKE 'CUDA%' LIMIT 50" || true
    ;;
  P3-EXT-A|P3-EXT-B)
    run_q p3_cpu_window \
      "SELECT ts, scope, cpu_total_pct, comm FROM cpu.utilization WHERE scope = 'process' ORDER BY ts DESC LIMIT 200" || true
    # 列名因版本而异；整表落盘后由 score 用 stress 关键字匹配
    run_q p3_cpu_tasks_stress "SELECT * FROM cpu.tasks LIMIT 80" || true
    ;;
  P3-SW-A)
    # 进程内泄漏：看 attach 进程 RSS（cpu.utilization.rss_kb）；无 process.memory 表
    run_q p3sw_rss_window \
      "SELECT ts, scope, rss_kb, thread_count, cpu_total_pct FROM cpu.utilization WHERE scope = 'process' ORDER BY ts DESC LIMIT 200" || true
    ;;
esac

python3 - <<PY
import json
from pathlib import Path
dump = Path("$DUMP")
tables_txt = (dump / "tables.txt").read_text(errors="ignore")
status = {}
for line in (dump / "status.tsv").read_text(errors="ignore").splitlines():
    if "|" in line:
        k, v = line.split("|", 1)
        status[k] = v
import re
def has(schema, name):
    return bool(re.search(rf"│\s*{re.escape(schema)}\s*│\s*{re.escape(name)}\s*│", tables_txt)) \
        or f"{schema}.{name}" in tables_txt
needed = {
    "gpu.utilization": has("gpu", "utilization"),
    "cpu.utilization": has("cpu", "utilization"),
    "cpu.tasks": has("cpu", "tasks"),
    "python.torch_trace": has("python", "torch_trace"),
    "process.gpu_users": has("process", "gpu_users"),
    "process.cpu_stats": has("process", "cpu_stats"),
}
missing = [k for k, ok in needed.items() if not ok]
hp = {}
hp_path = dump / "host_pressure.json"
if hp_path.is_file():
    try:
        hp = json.loads(hp_path.read_text())
    except Exception:
        hp = {}
hg = {}
hg_path = dump / "host_gpu.json"
if hg_path.is_file():
    try:
        hg = json.loads(hg_path.read_text())
    except Exception:
        hg = {}
manifest = {
    "case": "$CASE",
    "pid": "${PID:-}",
    "attach": "$ATTACH",
    "ts": "$TS",
    "victim_local_rank": int("$VICTIM_LOCAL_RANK"),
    "tables_present": needed,
    "tables_missing": missing,
    "query_status": status,
    "dump_dir": str(dump),
    "host_pressure": {
        "hit": bool(hp.get("hit")),
        "evidence": hp.get("evidence"),
        "cpu_some_rate_us_s": hp.get("cpu_some_rate_us_s"),
        "io_some_rate_us_s": hp.get("io_some_rate_us_s"),
        "threshold_cpu_rate_us_s": hp.get("threshold_cpu_rate_us_s"),
        "threshold_io_rate_us_s": hp.get("threshold_io_rate_us_s"),
        "threshold_rate_us_s": hp.get("threshold_rate_us_s"),
    },
    "host_gpu": {
        "hit": bool(hg.get("hit")),
        "evidence": hg.get("evidence"),
        "gpu_util_pct": hg.get("gpu_util_pct"),
        "hbm_bw_mbs": hg.get("hbm_bw_mbs"),
        "n_procs": hg.get("n_procs"),
        "threshold_gpu_util_pct": hg.get("threshold_gpu_util_pct"),
        "threshold_hbm_bw_mbs": hg.get("threshold_hbm_bw_mbs"),
    },
    "notes": (
        "gpu.utilization 在 MetaX 上依赖 CudaBackend；cu-bridge libcuda 缺符号会 panic，"
        "故可能长期 missing。P1 EXT：dump 同窗 mx-smi（host_gpu.json）可作 GPU util/HBM 旁路。"
        "P3 EXT：cpu.tasks 常仅本进程；dump 同窗 host PSI 可作外部 CPU/IO 争用证据。"
        if "$ATTACH" == "ok" else
        "attach failed: train worker 未挂 probing（检查 train_bench site_hook / probing.pth）；host_pressure/host_gpu 仍可能已采集。"
    ),
}
(dump / "query_manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(manifest, ensure_ascii=False))
PY

echo "dump_probing_sql done → $DUMP attach=$ATTACH"
