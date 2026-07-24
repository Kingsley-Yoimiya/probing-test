# P3-EXT-A Loud：首个 D4 case 跑通实录与条件清单

> 日期：2026-07-24  
> 用途：给后续 Agent / 人修订**标准实验流程（SOP）**用的一手材料——写清「怎么跑通的」「改了什么」「新条件是什么」「哪些坑不能再踩」。  
> 成功锚点：`results/muxi-mohe/20260724_090823-p3-live-d4e` → 判分 **D4 / PASS_D4**（证据 `host_psi_cpu`）。

---

## 0. 一句话结论

**离线侧早就证明「外部 CPU 征用把训练咬慢了」（D3）；卡 D4 的不是不知道慢，而是 Probing SQL 的 `cpu.tasks` 看不见 host 上的 `stress-ng`。**  
短探索证明：用 dump 同窗采集的 **Linux PSI**（`/proc/pressure/cpu` 的 `some.total` 速率）可以稳定看见外部 CPU 压力；把该证据接入 `dump_probing_sql.sh` + `score_dlevel_sql.py` 后，在已有 D3 战役上验收得到 **D4**。

---

## 1. 跑通的 case 与环境

| 项 | 值 |
|---|---|
| case | **P3-EXT-A**（host `stress_cpu` / `host_bound`） |
| dose | Loud（验收阈值 C1/C0 ≥ 1.3；实测 **2.97**） |
| 集群 | mohe-241；pods `yjr-fs-h14410` + `yjr-fs-h14411` |
| 身份 | **仅** `yinjinrun.p`；kube `~/.kube/config-vc-c550-mohe-241.yaml` |
| 代理 | Clash `:7897`；`NO_PROXY=127.0.0.1,localhost`；**unset** `ALL_PROXY` |
| Probing | **Probing_plus 0.2.5**（勿用 PyPI 0.2.4）；`probing.pth` / `site_hook` 必须生效 |
| 主结果 run | `20260724_090823-p3-live-d4e` |
| PSI 短探索 | `20260724_092235-p3-d4-psi-smoke` |
| D4 验收补丁跑 | `20260724_092724-p3-d4-psi-accept`（压力窗 dump PSI → 合并进 d4e 再 score） |

规模：2 节点 × 8 卡，GPT-2 124M，`ITERS=500` / `WARMUP=50`，注入窗 measure step **[100, 300]**，victim local_rank=7。

---

## 2. 全过程时间线（从卡死到 D4）

### 阶段 A — 以为「查进程表」就能 D4（失败）

1. 跑 C0 → C1 → C2，C2 注入窗内 `dump_probing_sql.sh`。
2. 得到 `attach=ok`，`cpu.utilization` / `cpu.tasks` 有行。
3. 判分停在 **D3 + `SQL_NO_EXT_EVIDENCE`**：`cpu.tasks` 只有 `torch` / `pt_elastic` / probing 线程，**没有 `stress`**。
4. 实时盯梢曾全程 `Connection refused`：裸 `pgrep -n -f /tmp/tbp.py` 打到无 probing socket 的进程（常是 torchrun 父进程）。

**根因（原理）**：Probing `cpu.tasks` 是**被 attach 进程内的 task 采样**，不是全机 `/proc` 扫进程表。权限上可以 `pgrep stress-ng`，但那不算 A5 允许的检测证据；SQL 表本身也看不到外部进程。

### 阶段 B — 先坐实 D3（成功，仍非 D4）

`d4e` Loud ABC：

| 项 | 结果 |
|---|---|
| C0 / C1 | COMPLETE；C1/C0 **2.97**，Loud acceptance **PASS** |
| C2 | SQL dump `attach=ok`；结束时有 FAIL marker（停注入杀 stress-ng 等），但 **16/16 ranks 齐全** |
| 离线 / SQL 初判 | **D3**（窗 IoU=1，`data_ms` 信号，victim 同机命中） |
| D4 | 否（`SQL_NO_EXT_EVIDENCE`） |

此时我们已经知道：**慢了，且是外部/host 侧咬的**；缺的是「工具接口上的外部争用证据」。

### 阶段 C — 短探索：PSI 可见 vs SQL 盲（≤2 min，不重开长战役）

脚本：

- [`scripts/fail-slow/psi_d4_smoke.sh`](scripts/fail-slow/psi_d4_smoke.sh)
- [`scripts/fail-slow/sql_blind_smoke.sh`](scripts/fail-slow/sql_blind_smoke.sh)

| 实验 | 做法 | 结论 |
|---|---|---|
| A0/A1/A3 PSI | 静默 → `stress-ng` → 冷却，采样 `/proc/pressure/{cpu,io,memory}` | **主指标用 `some.total` 速率（us/s）**，不要迷信短窗 `avg10` |
| 核数陷阱 | 128 核机上 `CPU_N=16` → PSI **WEAK**；`CPU_N=2×nproc=256` → A1 速率约 **8.2e5** vs 基线 **3.7e4（~22×）** → **PASS** | Loud 注入强度必须相对核数过载 |
| A2 SQL blind | `PROBING=1` + site_hook 短进程，并行 stress，`probing query cpu.tasks` | **attach=ok 仍无 stress 字样**；host `pgrep` 有 stress（旁证，不升 D4） |

### 阶段 D — 固化证据与判分（代码改动）

1. **`dump_probing_sql.sh`**：attach 前后无关，**始终**采 2s 窗 PSI → `host_pressure_{t0,t1}.txt` / `host_pressure.json` / `.tsv`；写入 `query_manifest.json.host_pressure`。
2. **`score_dlevel_sql.py`**：P3 EXT 证据链  
   - 优先：`cpu.tasks` / `process.cpu_stats` 含 `stress`（理想指名）；  
   - 否则：`host_pressure.json` 的 `hit=true` → **`host_psi_cpu`** → 可升 D4。  
   - 仍禁止：`injection.log`、裸 `pgrep`。
3. **`docs/fail-slow/decisions.md` A5 附注**：允许 dump 同窗 PSI 作 P3 EXT；说明 `cpu.tasks` 本进程限制。
4. **`live_sql_tick.sh`**：实时盯梢必须 victim local_rank 优先 + 试探 attach（禁止裸 `pgrep -n`）。

默认阈值（可由环境变量覆盖）：

| 变量 | 默认 | 含义 |
|---|---|---|
| `HOST_PRESSURE_DT_S` | `2` | PSI 速率采样间隔（秒） |
| `HOST_PSI_CPU_RATE_THRESH` | `200000` | `cpu.some` total 速率阈值（us/s）；标定自 128 核 × 256 stress |

`hit` 条件：`cpu_rate ≥ thresh`，且 io/mem 速率不主导（避免把 IO/内存压力误判成 CPU EXT）。

### 阶段 E — 验收到 D4（短跑，未重开 500-step 全战役）

1. 在 victim pod 上起短 probing 进程 + **`stress-ng --cpu $((nproc*2))`**。
2. 跑更新后的 `dump_probing_sql.sh` → `cpu_some_rate≈9.45e5`，`hit=True`。
3. 将 `host_pressure.*` **合并进**已有 D3 战役  
   `…/d4e/P3-EXT-A/by_pod/yjr-fs-h14410/round_1/C2_probing/probing/`，刷新 manifest。
4. `python3 score_dlevel_sql.py --result-root …/d4e --cases P3-EXT-A --dose Loud`  
   → **`d_level=D4`，`tool_probing_sql=PASS_D4`，notes 含 `host_psi_cpu:rate=944654.5`**。

说明：验收刻意**短**（压力窗 dump + 复用 d4e 离线 D3），符合「不靠再开全量 ABC 探索」；**标准流程修订时**应把 PSI 采进**真实 C2 注入窗**的 dump，而不是事后手工合并（见 §6）。

---

## 3. 必须满足的「新条件」清单（给 SOP 用）

### 3.1 环境 / 门禁

- [ ] 身份 `yinjinrun.p`；mohe kubeconfig；Clash；`unset ALL_PROXY`。
- [ ] **`/dev/shm` ≥ 8Gi**（默认 Docker/k8s 常为 **64Mi**，8 卡 MCCL 易打满 → SIGBUS）。开训前：`PODS=… KUBECONFIG=… bash scripts/fail-slow/ensure_shm.sh`（privileged 上 `mount -o remount,size=32G`）；新建 pod 挂 `emptyDir medium=Memory sizeLimit=32Gi` → `/dev/shm`（见 `image/pod-shm-snippet.yaml` / `docker --shm-size=32g`）。**勿在训练中途 remount**。
- [ ] C0 **必须** `unset PROBING` / `PROBING=0`（残留 PROBING 会让基线挂 crash handler / SIGABRT）。
- [ ] C2 才开 Probing；`train_bench_probe.py` 入口显式 `run_site_hook()`（`--target=pydeps` 时 `.pth` 不会自动加载）。
- [ ] **禁止**把 maca cu-bridge `libcuda` 塞进 `LD_LIBRARY_PATH`（cudarc panic）。
- [ ] **禁止**默认 `PROBING_TORCH_PROFILING=on`（MetaX 上易 SIGSEGV）。
- [ ] 本机后台跑 case 用 Cursor/IDE **持久 background shell**；macOS **无 `setsid`**，普通 `nohup &` 易被会话收掉。

### 3.2 注入强度（P3 Loud）

- [ ] 节点核数先 `nproc`；stress 工作线程数需**相对过载**（探索标定：**≥ 2× nproc** 时 PSI 才稳）。
- [ ] 仅 `CPU_N=16` 在 128 核机上会出现「训练已明显变慢、但短窗 PSI avg10 不抬头」的假阴性——**判 PSI 用 total 速率，且注入要够重**。
- [ ] Loud 训练验收仍看 C1/C0 `step_ms`（P3 ≥ 1.3）；与 PSI 阈值是两条线。

### 3.3 Dump / Attach

- [ ] Dump PID：victim `local_rank` 优先，对候选 PID **试探** `SHOW TABLES`，直至 socket 可连（见 `dump_probing_sql.sh` / `live_sql_tick.sh`）。
- [ ] C2 注入窗等待后再 dump（管线默认 `DUMP_WAIT_S=45`）。
- [ ] Dump **必须**产出 `host_pressure.json`（即使 attach 失败也应尽量采到 PSI——当前脚本在 attach 判定后仍会采）。
- [ ] `query_manifest.json` 含 `host_pressure.{hit,evidence,cpu_some_rate_us_s,threshold…}`。

### 3.4 判分（D3 → D4）

- [ ] 离线先到 **D3**（否则 SQL 分最高停在 D&lt;3）。
- [ ] P3 D4 EXT：**SQL 指名 stress** 或 **`host_psi_cpu` hit**。
- [ ] **永不**用 `injection.log` / 本机 `pgrep stress` 单独升 D4。
- [ ] Greyhound / XPUTimer = ENV-BLOCKED，不记 D0。

### 3.5 结果落盘

- [ ] 本机：`results/muxi-mohe/<run_id>/`（ranks jsonl、acceptance、probing dump、VERDICT）。
- [ ] 短探索/验收另目录带时间戳，便于审计。

---

## 4. 改动文件清单（回顾）

| 路径 | 改动要点 |
|---|---|
| `scripts/fail-slow/dump_probing_sql.sh` | 新增 `collect_host_pressure`；manifest 挂 `host_pressure`；注释澄清 `cpu.tasks` 本进程限制 |
| `scripts/fail-slow/score_dlevel_sql.py` | `_host_psi_evidence`；P3 `ext_evidence` 回落 PSI |
| `scripts/fail-slow/psi_d4_smoke.sh` | A0/A1/A3 短 PSI AB |
| `scripts/fail-slow/sql_blind_smoke.sh` | A2：证明 SQL 盲 |
| `scripts/fail-slow/live_sql_tick.sh` | 正确 attach 的实时 tick |
| `docs/fail-slow/decisions.md` | A5 P3 PSI 附注 |
| `docs/fail-slow/d4-live-sql-watch.md` | 现状 D3→D4 卡点与盯梢坑 |
| （历史相关）`train_bench_probe.py` site_hook、`sidecar_inject.py` MetaX 异步、`score_dlevel_offline.py` 同机 victim 命中 | 使 D3 可稳定达到的前置 |

---

## 5. 推荐复现命令（压缩版）

```bash
# 代理 + kube
unset ALL_PROXY all_proxy
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
export NO_PROXY=127.0.0.1,localhost
export KUBECONFIG="$HOME/.kube/config-vc-c550-mohe-241.yaml"
HERE=project/lab-workspace/projects/probing-test/scripts/fail-slow

# （1）完整 Loud ABC — 拿 D3 + 正式 C2 dump（含 host_pressure）
# 务必用 IDE 持久后台，勿依赖 macOS setsid
export RUN_ID=$(date +%Y%m%d_%H%M%S)-p3-d4
env -u PROBING -u PROBING_TORCH_PROFILING \
  CASE_ID=P3-EXT-A RUN_ID=$RUN_ID PODS=yjr-fs-h14410,yjr-fs-h14411 \
  ITERS=500 SIDECAR_WARMUP=8 DUMP_WAIT_S=45 ACCEPT_GATE=0 \
  bash "$HERE/run_case_abc.sh"

# （2）判分
python3 "$HERE/score_dlevel_offline.py" --result-root results/muxi-mohe/$RUN_ID --cases P3-EXT-A --dose Loud
python3 "$HERE/score_dlevel_sql.py"     --result-root results/muxi-mohe/$RUN_ID --cases P3-EXT-A --dose Loud

# （3）仅 PSI 能力冒烟（可选，≤90s）
kubectl cp "$HERE/psi_d4_smoke.sh" yjr-fs-h14410:/tmp/psi_d4_smoke.sh
kubectl exec yjr-fs-h14410 -- bash -lc \
  'OUT=/tmp/psi_out CPU_N=$(($(nproc)*2)) bash /tmp/psi_d4_smoke.sh'
```

期望：`VERDICT_SQL_Loud.md` 中 P3-EXT-A 为 **D4** / **PASS_D4**，notes 含 `host_psi_cpu` 或 `*_stress`。

---

## 6. 给「修订标准流程」Agent 的明确建议

下列项是本轮跑通后暴露的 SOP 缺口，建议纳入下一版标准流程（本文件只记录，不在此直接改大 SOP）：

1. **P3 D4 证据定义**：写明「SQL 指名优先；否则 dump 同窗 PSI rate」；禁止 injection.log。  
2. **C2 dump 清单**：`host_pressure.json` 列为必产物；与 ranks / manifest 一同回拉。  
3. **注入强度与核数**：Loud `stress_cpu` 参数与 `nproc` 挂钩（探索值 2×nproc）；文档化假阴性。  
4. **实时 SQL 盯梢**：强制 `live_sql_tick.sh` 语义；禁止裸 `pgrep -n`。  
5. **门禁检查表**：C0 unset PROBING、site_hook、禁 libcuda、禁默认 torch profiling、代理/NO_PROXY。  
6. **本机启动方式**：文档写清 macOS 后台陷阱。  
7. **验收诚实性**：下一轮标准战役应在**真实 C2 注入窗**由管线自动 dump PSI（勿再依赖「事后 stress + 合并进旧 run」作为主路径；后者仅用于本轮探索验收）。  
8. **P1 仍未通 D4**：GPU 表 / `process.gpu_users` 仍缺；勿把 P3 PSI 路径误套到 P1。

---

## 7. 证据目录索引

```
results/muxi-mohe/20260724_090823-p3-live-d4e/          # 主战役 D3→合并 PSI 后 D4
  VERDICT_SQL_Loud.md
  scoring_table_SQL_Loud.csv
  acceptance_P3-EXT-A.md
  P3-EXT-A/by_pod/yjr-fs-h14410/round_1/C2_probing/probing/
    query_manifest.json   # host_pressure.hit
    host_pressure.json
    query_cpu_tasks.txt   # 无 stress（对照）

results/muxi-mohe/20260724_092235-p3-d4-psi-smoke/      # 短探索
  SUMMARY.md
  psi_retry/              # 256 CPU PASS
  a2_sql_blind/           # SQL 盲

results/muxi-mohe/20260724_092724-p3-d4-psi-accept/     # 验收 dump + score 日志
  SUMMARY.md
  probing/host_pressure.*
  score.log
```

---

## 8. 叙事分层（写论文 / case 文档时别混）

| 层级 | 我们已有什么 | 角色 |
|---|---|---|
| 训练埋点 | C1/C0、`data_ms`、窗 IoU、同机 victim | **D1–D3**（知道慢、定位窗/节点） |
| Probing SQL 进程表 | `cpu.tasks` 无外部名 | **不能单独撑 D4**（当前实现） |
| Dump 同窗 PSI | `host_psi_cpu` rate | **本轮 P3 D4 主证据** |
| injection.log / pgrep | 有 | **旁证 only**，不升 D4 |

至此：**一个 Loud P3-EXT-A case 已从原理卡点走到可复现的 D4 判分闭环**；后续工作是把上述条件写回标准 SOP，并在下一轮战役里让 C2 管线原生产出 PSI，而不是手工补丁。
