# 两个 trade-off 极点 baseline 的 27-case 对照方案（Dynolog+HTA / Flight Recorder）

> **状态**：方案冻结前草案（2026-07-25）。落点脚本 `platform/ascend/{dynolog,flight_recorder}/`
> + 共享 `baseline_coverage_matrix.py`。真跑前先按本文对齐口径。
>
> **真相源**：方法论 `docs/fail-slow/rules.md`（尤其 §三·五 baseline 测法、红线 2/4/5）；
> 论文侧 `project/reading-paper/writing/probing-paper/`：`OUTLINE-v5.md` §1.2 trade-off 两极、
> §5.7 定性能力表；`CLAIM-PILLARS-METRICS-AND-EXPERIMENTS.md` Eval-A/B；
> `BASELINE-SETUP-PLAYBOOK.md`（接入手册，本轮需补这两个）。

---

## 0. 为什么这两个不能和 Greyhound/XPUTimer 同口径比

Greyhound（最强在线对手）、XPUTimer（开销对照）都是**在线常驻检测器**——它们自己
决定"何时报异常"，所以能直接比"自主检出+定位的 case 数 vs `M/27`"。

这两个新 baseline 是 outline §1.2 **trade-off 曲线的两个极点**，类型不同：

| baseline | 极点 | 触发类型 | 归因深度上界（§5.7） | 结构盲区 |
|---|---|---|---|---|
| **Dynolog+Profiler+HTA** | 极深极贵 | **oracle**（人/系统已知故障后按需开几秒） | D3–D4，但**事后** | 无（全栈），但常驻 +20~44% 且 OOM → 不敢常驻 |
| **Flight Recorder** | 极轻极窄 | autonomous（环形缓冲常驻） | **D1**（"哪个 collective 卡了"） | **P1（芯片）/P3（主机）结构上看不到**；只 collective 层；只 hang/desync，不检 fail-slow |

两条红线决定它们**不能**并进同一张检出率表：

1. **Dynolog 是 oracle 触发**（rules §三·五 B）：它不自主发现 fail-slow，是"已知故障时刻后
   短开 profiling"。把它塞进 `M/27` 检出率分子 = 给了它一个它没有的能力（自主检出），
   **反而削弱** outline"深的不敢常驻"这一论点。它只能比"**触发后**诊断到 D 几 + 代价"。
2. **Flight Recorder 结构性只覆盖 P2**：P1/P3 类它物理上无数据。它能进检出率表，但分母上
   **P1/P3 那 18 格记 `N/A`（结构盲区）而非 `D0`**——D0 是"跑了但没检出"，N/A 是"这类
   信号它根本不采集"。混为一谈会低估它、也不诚实（对称于红线 5：不把不兼容包装成对手劣势）。

> **结论**：**双表分列**。一张在线自主检出覆盖率表（含 FR），一张 oracle 触发诊断深度+代价表
> （Dynolog 单列）。这既守 rules §三·五 B，又正好把 outline 的 trade-off 叙事画出来。

---

## 1. 表 A · 在线自主检出覆盖率（`M/27` 口径）

**谁进**：Probing / Greyhound / XPUTimer / **Flight Recorder**。都是自主触发，能并列 `M/27`。

**判分**：沿用五级 D0–D5（rules §三），每格取最高连续正确级。

**FR 的分母处理（关键）**：

| 格 | FR 记法 | 理由 |
|---|---|---|
| P2×{HW,SW,EXT} 共 9 格（通信类） | 真跑 → D0–D1（hang/desync 类可到 D1；纯 fail-slow 慢而不挂→D0） | collective 元数据它有 |
| P1×* 9 格（芯片/GPU） | **N/A（结构盲区）** | 环形缓冲无 compute/芯片信号 |
| P3×* 9 格（主机） | **N/A（结构盲区）** | 无 host 层信号 |

- FR 覆盖率上界 = **P2 的 9 格里能到 D1 的数**，写成 `k/9 (P2 only) · 18 格 N/A`，**不写 `k/27`**
  以免和全栈工具误并列。报告里 FR 那一行显式标 "collective-only"。
- **N/A ≠ D0 ≠ ENV-BLOCKED**：N/A=结构上不采这类信号（能力边界，客观）；D0=采了但没报异常；
  ENV-BLOCKED=接入没趟通（本方案禁止早下，红线 5）。三者在 CSV 里用独立取值。

---

## 2. 表 B · oracle 触发诊断深度 + 代价（Dynolog+HTA 单列）

**谁进**：Dynolog+Profiler+HTA。**不产检出率**（oracle 触发，rules §三·五 B）。

**触发协议（必须写死并在产物里标）**：
- 触发方式 = **oracle**：用 case 的已知注入窗 `[100,300]` 之后，人工/脚本按需开 profiling
  几秒。**注入窗只用于触发采集，不进任何"检出"判定**——它本来就不声称自主检出。
- 采集时长：几秒~几十秒（Meta 实践；常驻会 +20~44% 且 OOM，正是不敢常驻的证据）。

**比什么**（两轴）：
1. **触发后诊断深度**：拿到那段 trace，HTA 事后分解能到 D 几（预期 D3–D4，kernel 级 temporal
   breakdown）。逐 case 记 `post_trigger_d_level`，标 "oracle-triggered, post-hoc"。
2. **代价**（rules §三·五 B 五项，重点前两项）：
   - 常驻开销 %（若强行常驻）：实测复核 outline 引用的 +20~44%；
   - onset-前空白：触发前那段历史**没有**（环形/短窗共性）——这是 Eval-C 回溯对照的点。

**Dynolog 在 27-case 的角色**：不填检出率分母；填 Motivation §1.2 的"极深极贵"活例子 +
Eval-A 开销对照点 + Eval-C"人触发 vs 我们自动检测后触发"对照。

---

## 3. 要"扒"什么数据（回答用户："是不是也把数据扒下来"）

不是扒"检出+定位结果"（那是 Greyhound/XPUTimer 的），而是各扒各的能力证据：

| baseline | 扒什么 | 从哪扒（离线优先） |
|---|---|---|
| **Flight Recorder** | 每个 P2 case 的环形缓冲 dump 里：有没有可用 collective timeline / 能否 hang-desync 定位到 rank | 已有 P2-SW-B run 的 comm trace（本机/AFS 回拉）离线喂 `fr_trace` 解析；P1/P3 直接记 N/A 不跑 |
| **Dynolog+HTA** | 触发一段 trace 后 HTA 能分解到哪层（compute/comm/mem breakdown）+ 常驻开销实测 | 已有 run 的 kineto/msprof trace 离线喂 HTA；开销另起 C2 位挂 profiler 短测 |

- **离线优先**：本轮先把已回拉的 run（如 P2-SW-B、P3-EXT-A）离线喂这两个解析器，产第一版
  对照数字，不必新起大作业。
- 真跑接入（趟通后）：FR 走 `config_denv_ascend.sh` 的 C5（`TORCH_HCCL_*`）；Dynolog 走
  daemon + `KINETO_USE_DAEMON=1` / MSProf。接入命令补进 `BASELINE-SETUP-PLAYBOOK.md`。

---

## 4. 产物 schema（对齐 `baseline_coverage_matrix.py`）

每个 baseline 每个 case 一行，字段：

```
tool, case_id, grid, trigger_type(autonomous|oracle),
coverage_status(detected|d0_no_bite|structural_na|env_pending),
d_level(0-5 或 NA), post_trigger_d_level(仅 oracle), notes
```

- `trigger_type=oracle` 的行**不进**表 A 的 `M/27` 分子/分母，只进表 B。
- `coverage_status=structural_na` 的行进表 A 分母但记 N/A，不算 D0。
- 汇总脚本据此自动分流两张表，并打印 `M/27`（Probing）vs 各对手的 `k/N`。

---

## 5. 红线自查（本方案）

- [ ] Dynolog 的注入窗只用于 oracle 触发采集，**没进检出判定**？（rules §三·五 B）
- [ ] FR 的 P1/P3 记 `structural_na` 而非 `D0`，且 N/A 与 ENV-BLOCKED 分开？（红线 5 对称）
- [ ] 两个工具都**先当能跑、离线趟通**，没在穷尽接入前记 blocked？（红线 5）
- [ ] 判分脚本里没有写死 case 答案（注入窗/rank/PID 只在判分期读 GT）？（红线 2）
- [ ] 代价五项对齐（同 seed、对齐窗、中位数）？（rules §三·五 B）
- [ ] outline 侧：`BASELINE-SETUP-PLAYBOOK.md` 补这两个的接入段；§5.7 表已有深度上界，跑出数后回填实测。
