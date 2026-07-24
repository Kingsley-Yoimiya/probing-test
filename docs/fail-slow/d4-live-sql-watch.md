# D4 新跑法：边跑边盯实时 SQL → 固化 → 验收

> 2026-07-24　现状：尚无完整 D4；最高 Loud P3-EXT-A **D3**（`20260724_090823-p3-live-d4e`，SQL=`SQL_NO_EXT_EVIDENCE`）。
>
> **实时盯梢坑**：禁止裸 `pgrep -n -f /tmp/tbp.py`（常打到无 probing socket → Connection refused）。用 `scripts/fail-slow/live_sql_tick.sh`（victim local_rank 优先 + 试探 attach，与 `dump_probing_sql.sh` 同逻辑）。
>
> **D4 卡点**：官方 dump `attach=ok` 仍看不到 host `stress-ng`（`cpu.tasks` 仅本进程）。下一步改采 PSI/`/proc/pressure` 等非进程表证据，或扩展 Probing 系统级表。

## 为何旧法低效

1. 整战役盲跑 → 事后才看 dump → 注入/IP/probing 误挂等问题混在一起  
2. 预置 SQL 按文档里的 `process.*` 表查，主线根本没有 → 永远 `TABLE_MISSING`  
3. 修一个环境点就重开全量，反馈环太长  

## 目标 D4（操作性）

- 离线先到 **D3**（注入有效 + 定位窗/信号）  
- **实时 SQL** 在注入窗内抓到「外部争用」证据（不是 injection.log）  
- 证据 SQL **固化**进 case 文档 + `dump_probing_sql.sh` / score 规则  
- 再用固化 SQL 做一轮验收战役  

## 新流程（单 case 闭环）

```text
门禁(清场/IP/unset PROBING@C0) 
  → 起 C0|C1|C2（ITERS=500，只 1 case）
  → 注入窗内 Agent 每 10–20s：SHOW TABLES + 试探查询
  → 记下「能出数且能区分注入」的 SQL
  → 固化到 recipes
  → 同参复跑验收（只验固化 SQL + 离线 D3）
```

### 先做哪几个（顺序）

| 优先级 | case | 为何 |
|---|---|---|
| 1 | P3-EXT-A Loud | 注入已稳（C1/C0~2.7），SQL attach 曾 ok，最容易冲 D3→D4 |
| 2 | P1-EXT-A Loud | cube 冒烟已 2.60，缺的是 GPU 侧可观测 SQL |
| 3 | P1-EXT-B Loud | hbm 冒烟 2.95，同上 |

### 实时盯什么（探索，不预设 process.*）

- `SHOW TABLES` 动态清单  
- `cpu.utilization`（P3：注入窗 vs 基线是否抬升；注意可能是 self-process）  
- `gpu.devices` / 若出现 `gpu.utilization`  
- `python.torch_trace` / `python.comm_collective`（延迟开 profiling 若会崩则跳过）  
- 任何能标出 **victim rank / 外部 pid / 异常 util** 的查询  

找到后写入：`docs/fail-slow/decisions.md` + case 文档 + dump/score。

### Agent 分工

- **Runner**：清场、起单 case C0/C1/C2、保证 ITERS=500  
- **Watcher**（父或子）：注入窗内轮询 SQL，落盘 `live_sql/<ts>.md`，异常立刻喊停  
- **不再**：无 Watcher 时开全量 4 case 战役  

## 成功标准（单 case）

- C1/C0 过 Loud 阈值  
- C2 `attach=ok`  
- 至少 1 条固化 SQL：注入窗有信号、C0 对照无/弱  
- score：离线 D3 + 该 SQL → 标 D4（或明确仍差哪类表，改判据而非空想 process.*）  
