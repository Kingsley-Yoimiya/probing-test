# Probing Fail-Slow 实验标准操作规程（SOP）

> **这份文档干什么**：定义 Probing 论文实验的**标准操作规程**——从实验条件、变量控制、执行步骤、判分规则到数据记录，全部给出可操作的定义。拿到这份 SOP，任何人都能复现同样的实验。
>
> **核心原则**：我们验证的是**工具的检测能力**，不是 Agent/人的推理能力。方法是：预先设计标准化的"小谜题"（受控注入），定义标准化的检测程序（固定的 SQL 查询序列 + 判据阈值），证明 Probing 已有接口在不改代码的前提下能把谜题解出来——且对手用同一套程序在同一批数据上解不出来或解得浅。
>
> **上游依据**：
> - 论文总纲 `writing/probing-paper/OUTLINE-v5.md`
> - 27-case 目录 `OUTLINE-v3-27-cases-per-cell.md`
> - 定位协议 `AGENT-LOCALIZATION-PROTOCOL.md`
> - 对手 setup `BASELINE-SETUP-PLAYBOOK.md`
> - Probing 机制 `docs/fail-slow/profiling-deep-dive.md`
>
> **日期**：2026-07-23　**状态**：v2 重写，操作规程主稿。
>
> **配套（执行落点 / 待补清单）**：
> - 落盘与脚本：`docs/fail-slow/layout.md`
> - 需他方细化：`docs/fail-slow/open-questions.md`
> - 编排脚本：`scripts/fail-slow/`

---

# 一、实验设计原则

## 1.1 我们在验证什么（操作性定义）

**命题**：Probing 作为一个检测**工具**，其已有接口（SQL 查询 + SET 热更新 + 冷热存储）的能力足以让工程师在不改训练代码、不重启的前提下，对 27 类 fail-slow 故障做到比对手工具更深的定位（D0–D5）和更广的覆盖（M/27 vs K/27）。

**验证方法**：
1. 预先设计 N 个**受控注入谜题**（已知答案的故障场景）
2. 对每个谜题，执行人**用工具已有接口自行设计最佳检测方案**（SQL 查询 + 判据 + 决策逻辑）——每个 case 的方案可以不同
3. 对手侧同理：用对手工具的已有接口，设计该 case 的最佳检测方案
4. 用统一的 D0–D5 判分规则评定各自能到达的深度
5. 汇总产出论文需要的 5 个数字

**不是什么**：
- **不是自动化检测程序**——我们不需要证明"一套预置规则能自动检出所有 case"（那反而和 ARGUS 一样了,违背论文卖点"开放词表"）
- **不是让 LLM Agent 运行时推理**——检测方案由人（工程师）事先设计,不依赖运行时 AI
- 我们证明的是**工具的检测能力天花板**：给定一个工程师知道该查什么方向,这个工具的接口能不能支撑他查到根因。对手的工具在同样条件下能不能做到。

**为什么每个 case 允许不同的检测方案**：
- 我们的论文核心卖点是"判据词表运行时可开"——工程师可以根据观察到的现象，**现场构造**最适合的查询
- 如果我们自己搞一套"统一预置规则打所有 case",等于自己把词表关上,和对手没区别
- 真实场景就是：工程师看到某类异常，根据经验和工具接口去查——每次查法可能不同
- **公平性靠的不是"同一套规则",而是"同一组谜题 + 各自用自己工具的最佳方案"**

## 1.2 变量控制框架

### 1.2.1 自变量（我们操纵的）

| 自变量 | 取值范围 | 说明 |
|---|---|---|
| case_id | 27 类中的一个 | 哪种故障 |
| 剂量档位 | Loud / Quiet / Masked | 故障强度（每 case 预定义三档具体数值） |
| 规模 | 8 / 16 / 32 / 64 / 128 / 256 / 512 卡 | Eval-D 扫规模时变 |
| 检测工具 | Probing / Greyhound / StragglerAnalysis / SuperBench / XPUTimer | 对照 |

### 1.2.2 控制变量（必须固定的）

| 控制变量 | 固定值 | 为什么必须固定 |
|---|---|---|
| 训练脚本 | 同一份，所有 config 共用 | 排除训练代码差异 |
| 训练超参 | 见 §2.1 固定参数表 | 排除模型/batch 差异 |
| 硬件环境 | 同一批节点、同一固件版本 | 排除硬件差异 |
| 随机种子 | 固定 seed=42（或指定） | 排除随机性 |
| 健康基线 | 先跑、冻结阈值后不再改 | 保证 FPR 公平 |
| 注入时机 | 统一为 step N_inject 开始 | 排除 warmup 干扰 |
| 检测方案 | 每个 case 由执行人设计,记录在案 | 可复现、可审计 |

### 1.2.3 因变量（我们测量的）

| 因变量 | 测量方式 | 用途 |
|---|---|---|
| D-level（0–5） | 判分规则（§四） | 覆盖深度 |
| time-to-trigger | 从注入开始到 D1 的 step 数 | 响应速度 |
| trigger-to-insight | 从 D1 到最终 D-level 的 step 数 | 归因深度速度 |
| 训练吞吐影响 | 有/无检测器的 step time 比 | 开销 |
| FPR | 健康对照上的误报率 | 假阳性 |

## 1.3 公平性三铁律（贯穿全程）

1. **同一批注入谜题 + 同一份健康基线**喂所有工具
2. 每个工具用**自己接口能力范围内的最佳方案**——不故意让对手用差配置
3. **检测方案记录在案**——每个 case × 每个工具的方案文档化,使他人可复现验证;判分标准(D0–D5)统一

---

# 二、训练脚本标准配置

## 2.1 固定参数表（所有 case/config 共用）

| 参数 | 值 | 理由 |
|---|---|---|
| 模型 | GPT-2 small (124M) | 够小能快跑、够大有真实的 compute/comm/data 比例 |
| batch size (per GPU) | 8 | 平衡 GPU 利用率和内存 |
| 9 | `/dev/shm` ≥ 8Gi（默认 64Mi 会 SIGBUS；`ensure_shm.sh` remount 或新建 pod 挂 dshm） | 8 卡 MCCL + probing 占满 64Mi |
| sequence length | 1024 | 标准 |
| dtype | fp16 (mixed precision) | 生产常见 |
| 并行策略 | DDP（小规模）/ FSDP（≥64 卡） | 保证有 AllReduce/通信 |
| optimizer | AdamW | 标准 |
| **DataLoader** | **必须开**，num_workers=2，pin_memory=True，worker_init_fn=seed_worker(固定每 worker seed)，persistent_workers=True | host 类 case 的前提（见下） |
| prefetch_factor | 2 | 默认值，不做极端隐藏 |
| **Checkpoint** | **必须开**，每 100 步存一次 | Eval-A1 重启代价 + 9B 磁盘 IO 的前提 |
| 总步数 | **500 步**（含 warmup） | 够长出稳态、够短快迭代 |
| warmup 步数 | **50 步** | 前 50 步不计入任何判分（排除编译/初始化噪声） |
| 随机种子 | 42 | 固定 |
| 日志 | 每步写 step_time、loss、各 phase 耗时到 jsonl | 离线验证用 |
| **Probing 采集** | `PROBING_TORCH_PROFILING=on:rate=1.0` | 实验中每步都采,保证统计可靠性（生产环境默认 5%） |
| **Probing 冷存储上限** | `PROBING_COLD_MAX_TOTAL_MB=512` | 保证 500 步全程数据不被驱逐 |
| **Probing 冷存储 TTL** | `PROBING_COLD_TTL_SECS=7200` | 2 小时,覆盖全 run 时长 |

## 2.2 为什么 DataLoader 和 Checkpoint 必须开

- **DataLoader**：没有真实数据加载路径，host 类 case（8A GC、8B 泄漏、9A 抢 CPU、9B 抢磁盘、9C 抢内存）的注入无路径可咬——data_ms≈0 时任何 host 侧干扰都被隐藏。num_workers=2 + prefetch_factor=2 是"能感知但不完全隐藏"的平衡点。
- **Checkpoint**：(1) Eval-A1 要测"对手中途接入需要重启→从 checkpoint 恢复的 GPU-hours 损失"；(2) 9B 抢磁盘 IO 需要 checkpoint 写入作为 IO 负载。

## 2.3 注入时序标准

```
step 0 ─────── step 50 ─────── step N_inject ─────── step N_inject+D ─────── step 500
 │                │                   │                       │                   │
 warmup        warmup结束          注入开始               注入结束             run结束
 (不判分)      (开始采健康基线)     (ground-truth 起)      (ground-truth 止)    (收数据)
```

| 参数 | 值 | 说明 |
|---|---|---|
| warmup | 前 50 步 | 不计入任何判分/统计 |
| 健康基线段 | step 50 ~ N_inject-1 | 用于建立"正常"的统计基准 |
| N_inject | **150**（默认） | 注入开始 step，保证有 100 步干净基线 |
| 注入持续 D | **200 步**（默认） | 持续注入 |
| 注入后观察 | step N_inject+D ~ 500 | 观察恢复/持续（部分 case 关注） |

> **case 特殊覆盖**：间歇类(1C/3C)注入改为 on-off-on 模式（每 50 步交替）；渐进类(1A)注入改为线性递增。具体在各 case 配方中定义,但总 run 长度和 warmup 不变。

### 2.4 注入器与训练的同步机制

训练脚本在每步结束时写一个原子 step counter 到共享内存(`/dev/shm/training_step`)。注入器 inotifywait 该文件到目标 step 后触发。

- 这不是检测逻辑(不违反红线),只是实验基础设施
- 多节点场景:由 rank 0 写 step counter 到 AFS,注入器各节点分别 watch
- 注入器启动后记录实际触发的 step 号到 ground-truth

## 2.5 训练脚本不做的事（红线）

- **不埋任何针对特定 case 的检测逻辑**——训练脚本对注入和检测完全无感知
- **不在训练代码里 import Probing 或对手库**——接入走环境变量/LD_PRELOAD/ptrace
- **不做 step 内的 barrier sync timing**（除非离线验证用,且不作为检测证据）
- 所有 config 用**同一份训练脚本**,只改启动参数(NNODES/NPROC/seed)

---

# 三、检测方案设计（"小谜题"的解法）

## 3.1 检测方案的本质

每个 case 的检测方案 = **执行人用工具接口设计的一套查询+判据**,它:
- 针对该 case 的特点,选择最合适的 SQL 查询、表、字段组合
- 定义该 case 下"异常"的判据（可以是阈值、趋势、对比、模式匹配等）
- 产出结构化判定（定位路径、D-level、证据引用）

**核心原则**：
- **每个 case 的检测方案可以不同**——这正是我们"开放词表"的体现
- 执行人的角色 = 一个知道问题大方向的工程师,用工具去查
- 方案设计完成后**记录在案**（写到该 case 的文档里），使得他人可以复现验证
- 对手侧同理：也由执行人用对手工具的最佳接口去查同一个 case,记录方案

## 3.2 Probing 侧方案的一般结构

虽然每个 case 方案不同,但按**四层漏斗**组织是推荐结构:

```
L0 分诊（有没有异常）→ L1 域分类（哪个大类）→ L2 定位对象（谁）→ L3-L4 归因（为什么、哪一格）
```

每层的具体查询和判据由执行人根据 case 特点决定。例:
- 3A(同卡算力抢占)：L0 看 step_time 离群 → L2 按 rank 比 → L3 看 gpu_util 外部占用 → L4 确认外部 PID
- 2A(显存碎片化)：L0 看 step_time 趋势上升 → L3 看 allocated 单调增长 → L4 确认碎片模式
- 1C(间歇降频)：L0 看 step_time 周期性尖刺 → L3 看 GPU 频率/温度周期 → L4 确认硬件节流

## 3.3 方案设计的约束（必须遵守）

| 约束 | 说明 | 为什么 |
|---|---|---|
| **只用工具已有接口** | Probing 侧只用 SQL 查询 + SET 命令 + 已有表；不写新 extension | 证明的是工具能力,不是定制开发能力 |
| **不改训练代码** | 不能在训练里加 hook/print/barrier 来辅助检测 | 透明性约束 |
| **不用注入的先验知识** | 方案设计时可以知道"这是计算类故障",但不能用 ground-truth 的具体数值(如确切 target_rank) | 模拟"工程师知道大方向但不知道具体答案" |
| **方案必须记录** | 写清"执行了哪些查询、用了什么判据、为什么选这个"| 可复现、可审计 |
| **对手用同等信息** | 对手也知道"这是计算类故障",也用自己工具的最佳方案 | 公平 |

## 3.4 对手侧方案设计

对手的方案 = **用对手工具的已有接口,在同等先验信息下,尽力做到最好**:
- **Greyhound**：喂同一批 trace,看其变点检测 + 规则能走到哪一级
- **StragglerAnalysis**：喂 parquet,看其 decompose 能指出什么
- **SuperBench**：喂 summary,看其 RuleOp 能判定什么
- **XPUTimer**：看其常驻信号能发现什么（但无自动 RCA）

**关键公平性**：对手的方案也应该是"给定其工具能力的最佳使用方式"——不故意用得差。如果对手工具有某个高级功能能检出该 case,就应该用。

## 3.5 "不同方案"和"公平比较"如何兼容

审稿人可能问："每个 case 方案不同,怎么保证比较公平？"

回答：
1. **公平性不靠"同一套规则",靠"同一组谜题 + 各自工具的最佳表现"**——就像比两把锁的安全性,不是用同一把钥匙试,而是各自用最好的攻击手段
2. **判分标准统一**（D0–D5 是公共尺子,与方案无关）
3. **对手也允许最佳方案**——不是故意让对手用差的配置
4. **差异体现在工具能力天花板**：Probing 能构造的查询种类（开放词表）vs 对手只能参数化已有模板——这正是论文的切割点

## 3.6 方案文档模板（每个 case 一份）

```markdown
# Case P1-EXT-A (3A 同卡算力抢占) 检测方案

## 先验信息（模拟工程师知道的）
- 现象：训练吞吐下降,某些 step 特别慢
- 方向提示：可能是计算相关

## Probing 侧方案
### 查询 1: 分诊
```sql
SELECT rank, avg(duration_ms) as avg, ... FROM python.torch_trace 
WHERE step > 50 GROUP BY rank
```
判据: max(avg) / median(avg) ≥ 1.5 → 有 straggler

### 查询 2: 定位
```sql
SELECT rank, gpu_utilization, gpu_utilization_other 
FROM gpu.utilization WHERE rank = <suspect>
```
判据: gpu_utilization_other > 10% → 外部占用

### 查询 3: 归因
```sql
SELECT pid, cmdline, gpu_util FROM process.gpu_users 
WHERE rank = <suspect> AND pid != training_pid
```
判据: 找到非训练 PID → P1×EXT

## 判定路径
L0(straggler ratio=2.3) → L2(rank 7) → L3(gpu_other=45%) → L4(P1-EXT, 外部PID=12345)

## D-level: D4（若停 PID 后恢复则 D5）

## 对手侧方案
### Greyhound: 变点检测→1.2×中位数→指出 rank 7 慢,但无 PID 信息→D3
### StragglerAnalysis: S>1.03→指出 rank 7,但无根因→D2-D3
```

## 3.7 参考阈值表（推荐值,执行人可按 case 调整）

| 判据 | 推荐阈值 | 说明 |
|---|---|---|
| straggler 比率（max/median） | ≥1.5 | 可按 case 噪声水平调 |
| 持续性（worst_fraction） | ≥0.25 | — |
| 通信 culprit | top-1 且 ≥2× median | — |
| 内存泄漏趋势 | ≥70% step 单调增 | — |
| 外部争用 | gpu_util_other > 10% | — |

> **这些不是"冻结阈值"**——执行人可以根据 case 特点选择更合适的判据/阈值,只要记录在方案文档中。唯一的硬约束是：方案设计时**不使用 ground-truth 的具体数值**。

## 3.8 跨节点联邦查询说明

多节点（≥2 nodes）的 cross-rank comparison 当前需要"对每个 rank 的 Probing 实例分别查询 → 外部 Python 脚本汇总"。Probing 目前没有内置联邦查询,跨 rank 聚合由实验脚本完成。

**汇总模式**:

```python
# 对每个 rank 的 Probing 连接分别查询,外部汇总
results = {}
for rank in ranks:
    results[rank] = query(probing_conn[rank], sql)
# 再做跨 rank 比较(如找 straggler、计算 max/median ratio)
```

实验中这部分逻辑在 `scripts/analysis/cross_rank_compare.py` 统一封装,确保所有 case 用同一套汇总代码。

---

# 四、判分规则（操作性定义）

## 4.1 D0–D5 五级判分

| 级 | 名称 | 操作性判定条件 | 证据要求 |
|---|---|---|---|
| D0 | 无感 | 检测程序输出"no anomaly" | — |
| D1 | 检出 | 检测程序触发异常信号（straggler ratio ≥ 阈值） | 输出含 triggered=True |
| D2 | 时间窗 | 检测程序报告的异常时间窗 ∩ ground-truth 注入窗 ≥ 50% | IoU ≥ 0.5（用 ground-truth 的 t_on/t_off 核验） |
| D3 | 对象 | 检测程序指出的 target_rank/host **等于** ground-truth 的 target_rank/host | 精确匹配 |
| D4 | 根因层 | 检测程序输出的 27 格坐标（位置×来源）**等于** ground-truth 的 case_id 对应格 | 位置和来源都对 |
| D5 | 可处置 | D4 成立 **且** 执行处置动作后指标恢复（处置前后 step_time 差 > 阈值） | before/after 数据 |

## 4.2 判分规则细则

- **只取最高连续 D-level**：D3 对了但 D4 错了 → 记为 D3
- **D2 的 IoU 计算**：overlap_steps / union_steps ≥ 0.5
- **D3 允许 ±1 rank 容差**：某些通信类 case,victim 和 culprit 相邻,指出任一算 D3
- **D4 的"位置"和"来源"独立判**：位置对但来源错 → D3.5（记录但统计时算 D3）
- **D5 的恢复判据**：处置后连续 10 步 step_time 回到注入前均值 ±10%
- **FPR 可接受阈值**：FPR ≤ 2%（即健康 450 步中误报 ≤9 步）时可接受
- **FPR 报告方式**：FPR 和检测率一起报,画 ROC 或 precision-recall,不做单独一票否决

## 4.3 判分表模板

每个 case × 每个工具 × 每档剂量,填一行:

| 字段 | 类型 | 说明 |
|---|---|---|
| run_id | string | 唯一标识本次 run |
| case_id | string | 如 "P1-EXT-A"（3A 同卡算力抢占） |
| dose | enum | Loud / Quiet / Masked |
| tool | string | Probing / Greyhound / ... |
| d_level | int 0-5 | 到达的最高判分 |
| d1_step | int | 首次触发 D1 的 step 号（time-to-trigger） |
| d_final_step | int | 到达最终 D-level 的 step 号（trigger-to-insight） |
| target_reported | string | 检测程序报告的对象 |
| target_truth | string | ground-truth 的对象 |
| grid_reported | string | 报告的 27 格坐标 |
| grid_truth | string | 真实的 27 格坐标 |
| evidence_refs | list[string] | 关键 SQL 查询及结果摘要 |
| notes | string | 边界情况说明 |

---

# 五、实验执行流程

## 5.1 核心实验结构：平行 run 对照（变量控制的根本）

**每个 case 不是跑一次,而是跑一组平行 run——只改一个变量（检测工具）,其余全部固定。**

### 5.1.1 一个 case 的完整 run 组

| Run | 训练 | 注入器 | 检测工具 | 说明 |
|---|---|---|---|---|
| **A (baseline)** | ✅ 固定 seed | ❌ 无注入 | ❌ 无工具 | 纯净基准线：正常训练每步 step_time 应稳定不变 |
| **B (injection-only)** | ✅ 同 A | ✅ 有注入 | ❌ 无工具 | 注入效果：故障在训练指标上"长什么样" |
| **C (Probing)** | ✅ 同 A | ✅ 同 B | ✅ Probing (PROBING=2) | Probing 的检测能力 + 对训练的开销 |
<!-- PROBING=2 含义: current+children,适用 torchrun 分布式场景,对主进程及其所有子进程(per-GPU worker)生效 -->
| **D (Greyhound)** | ✅ 同 A | ✅ 同 B | ✅ Greyhound (LD_PRELOAD) | 对手检测能力 + 开销 |
| **E (XPUTimer)** | ✅ 同 A | ✅ 同 B | ✅ XPUTimer (LD_PRELOAD) | 对手检测能力 + 开销 |
| **F (其他对手)** | ✅ 同 A | ✅ 同 B | ✅ 对应工具 | ... |

### 5.1.2 为什么必须是平行 run,不能离线喂数据

- **每个工具挂上去本身就会影响训练**——Probing 有 ptrace 注入的一次性扰动 + 常驻采集开销；Greyhound 有 LD_PRELOAD 的 hook 开销；XPUTimer 有自己的采集。挂的东西不同,训练的行为就不完全相同。
- **离线喂数据无法测量"工具对训练的干扰"**——这是 Eval-A 要测的核心指标之一。
- **在线检测能力 ≠ 离线分析能力**——Probing 的卖点是"训练跑着的时候就能发现",不是事后回看。在线和离线的检测窗口、数据完整性都不同。

### 5.1.3 变量控制要点

| 必须固定的 | 怎么保证 |
|---|---|
| **硬件** | 同一组机器（冻结节点列表）,所有 run 用这批机器 |
| **种子** | 同一 seed（默认 42），保证训练确定性 |
| **训练脚本 + 超参** | 同一份,不改 |
| **注入器 + 注入时机** | 同一脚本、同一 step 触发（B/C/D/E/F 的注入完全相同） |
| **网络/环境** | 尽量背靠背跑（同一天、同一时段），减少外部噪声 |

| 唯一改变的 | 取值 |
|---|---|
| 是否有检测工具 + 哪个工具 | A=无、B=无(有注入)、C=Probing、D=Greyhound... |

### 5.1.4 每条线能读出什么

- **A 线（基准）**：每步 step_time 应稳定。若不稳定 → 环境有噪声,需排查后再跑。A 线是一切比较的锚。
- **B 线（注入效果）**：B 相对 A 的差 = 纯注入效果。验证注入确实生效了（step_time 变化 > 噪声）。若 B ≈ A → 注入不咬,该 case 在当前配置下无效。
- **C 线（Probing）**：
  - C 相对 A = Probing 常驻开销（Eval-A 的 X%）
  - C 相对 B = Probing 在有注入时的额外干扰（应该很小）
  - C 线上 Probing 的检测输出 = 检测能力（能到 D 几）
  - C 线上检测触发的 step 号 = time-to-trigger
- **D/E/F 线（对手）**：
  - D 相对 A = 对手常驻开销
  - D 线上对手的检测输出 = 对手检测能力
  - D 和 C 的能力差 = 我们比对手好在哪

## 5.2 每个 case 的三阶段流程（Pilot → 固化 → 正式）

> **核心教训（从 P3-EXT-A 首个 D4 跑通中来）**：不能照本宣科。Case 文档里预写的参数/SQL 只是**起点**,执行人必须先小规模验证环境和注入,再固化检测方案,最后才跑正式 run。但所有调整不得违反论文核心原则（不改训练代码、不用 ground-truth 具体值、不引入 Agent 运行时推理）。

### 阶段一：Pilot 探索（每个 case 首次必做,允许反复调）

**目标**：验证"注入能咬到训练 + Probing 接口能看到信号",确定该 case 的具体可用参数。

**怎么做**：
1. **小规模快速跑**(如 100 步 / 单节点 / Loud 档),确认:
   - 注入器真的能让 step_time 变化 > 噪声(否则调注入参数)
   - Probing attach 成功、SQL 表有数据(否则排查环境问题)
   - 哪些 SQL 表/字段在该平台上**真的有值**(不能假设所有表都可用)
2. **Agent 或执行人交互式探索 SQL**:
   - 训练+注入跑着的时候,用 Probing SQL 接口交互式查询
   - 找到能区分"注入期 vs 健康期"的信号——哪些字段有差异、阈值大概是多少
   - **这个阶段允许用任何手段**(Agent、手动 `probing query`、看 dashboard)——目标是"找到路"
3. **标定注入参数**:
   - 注入强度和机器规格挂钩(如 P3 的 stress CPU 数 ≥ 2×nproc 才有效)
   - 记录实际生效的参数(不一定是 case 文档预写的值)
4. **确认环境门禁**(从 P3-EXT-A 教训):
   - [ ] C0 run 必须 `unset PROBING`(残留会污染基线)
   - [ ] C2 run 确认 site_hook 生效(MetaX 需 `run_site_hook()`)
   - [ ] 确认不会 SIGSEGV(MetaX 上禁默认 `PROBING_TORCH_PROFILING=on`,需显式指定 rate)
   - [ ] Probing attach PID 用 victim local_rank 的 worker 进程(不是 torchrun 父进程)

**产出**：
- 确认注入生效(step_time 变化比)
- 确认 Probing 可用的 SQL 表/字段列表
- 初步可行的检测 SQL 序列 + 阈值

**时间**：≤ 1-2 小时/case(含排错)

### 阶段二：固化检测方案（写死 SQL,冻结）

**目标**：把 Pilot 探索到的检测路径固化成**确定性脚本**,不再依赖 Agent 或人的运行时判断。

**怎么做**：
1. 从 Pilot 中提炼出**固定的 SQL 查询序列 + 固定的判据阈值 + 固定的决策逻辑**
2. 写成可执行的检测脚本(如 `dump_probing_sql.sh` + `score_dlevel_sql.py`)
3. 每个 case 的 SQL 可以不同(开放词表),但一旦冻结就不再改
4. **冻结标准**:在 Loud pilot 数据上能稳定到达预期 D-level(如 D4)
5. 将最终方案写回 case 文档 §2(覆盖预写的示例 SQL)

**冻结后不允许的**:
- 看了 Quiet/Masked 结果后回来改 SQL/阈值(overfitting)
- 在正式 run 中临时调整判据
- 用 injection.log 或外部 `pgrep` 作为检测证据

**冻结后允许的**:
- 发现环境 bug(如表字段名变了)→ 修 bug 后重新 pilot + 冻结
- 发现 case 文档预写的剂量无效 → 调整剂量参数(但记录变更理由)

**产出**：
- 冻结的检测脚本(每个 case 一套)
- 更新后的 case 文档 §2(实际生效的 SQL,不再是示例)

### 阶段三：正式 run（平行 run 对照,产出论文数字）

**目标**：用冻结的方案跑 A/B/C/D/E 平行 run,产出判分表和论文数字。

**前提**：阶段一、二都已完成,检测方案已冻结。

**执行**：按 §5.1 的平行 run 结构,每个 case 跑 A/B/C/D/E 五条线,seed 42/43/44 三组。

**正式 run 中执行人的角色**：
- 启动训练 + 注入 + 工具 → 等待 run 完成 → 收数据 → 跑冻结的判分脚本
- **不做任何交互式探索**——全部由冻结脚本自动执行
- 如果正式 run 中发现冻结方案失效(如 Quiet 档检不出) → **如实记录 D0**,不回去改

### 为什么是三阶段而非"直接照方案跑"

| 教训来源 | 问题 | 三阶段怎么解决 |
|---|---|---|
| P3-EXT-A | `cpu.tasks` 看不见外部 stress → 预写 SQL 失败 | Pilot 阶段发现 → 换 PSI 路径 → 固化 |
| P3-EXT-A | stress CPU 数不够(16 vs 128 核) → 注入假阴性 | Pilot 阶段标定 → 调到 2×nproc → 记录 |
| P3-EXT-A | MetaX 上 `PROBING_TORCH_PROFILING=on` 导致 SIGSEGV | Pilot 阶段暴露 → 门禁加入 |
| 通用 | Case 文档预写的 SQL 字段可能在特定平台上不存在 | Pilot 阶段确认实际可用表/字段 |

### 5.2.1 公平性说明

- **Probing 有 Pilot 阶段(人/Agent 探索 SQL)、对手没有——这公平吗?**
  - 公平。我们验证的是**工具的能力天花板**——给定工程师知道大方向,工具能不能支撑查到根因。
  - Pilot 阶段 = 工程师用工具探索的正常过程;对手同样给了"健康集+Loud pilot 调阈值"的机会。
  - 最终比较的是**冻结后的方案在同一批数据上的表现**——不是比"谁探索得快"。
  - 论文的切割点是"开放词表能走到 D4、封闭词表止步 D3"——Pilot 只是让"能走到"变成"确实走到"。

### 5.2.2 对手侧
(不变：对手用自动规则,不需要 Pilot 探索;对手阈值在健康集+Loud pilot 上冻结)

### 5.2.3 OUTLINE-v5 sys 层验证说明
(不变)

---

## 5.3 环境门禁检查表（从 P3-EXT-A 教训提炼,每次 run 前必过）

| # | 检查项 | 为什么 |
|---|---|---|
| 1 | C0 run: `unset PROBING` / `PROBING=0` | 残留 PROBING 会让基线挂 crash handler,污染 A 线 |
| 2 | C2 run: 确认 `site_hook` 生效(`PROBING=2` + `run_site_hook()`) | MetaX 上 `--target=pydeps` 时 `.pth` 不自动加载 |
| 3 | **禁止** `PROBING_TORCH_PROFILING=on` 作为默认值 | MetaX 上易 SIGSEGV;需显式指定 `rate=1.0` |
| 4 | **禁止**把 MACA cu-bridge `libcuda` 塞进 `LD_LIBRARY_PATH` | cudarc panic |
| 5 | Probing attach PID 用 **victim local_rank worker 进程** | torchrun 父进程无 probing socket |
| 6 | 注入强度与机器规格挂钩 | 128 核机上 16 个 stress 线程 = 假阴性 |
| 7 | 本机启动用持久后台 shell(IDE background) | macOS 无 `setsid`,普通 `nohup &` 易被收 |
| 8 | `NO_PROXY=127.0.0.1,localhost`; `unset ALL_PROXY` | Clash 代理干扰 kubectl/probing socket |

- **A-sys(开销-规模)**：单独跑纯净 baseline(无注入) 8→512 卡,只挂 Probing,测每步开销和热更新延迟。不在 27-case 循环里做。
- **B-sys(词表表达力)**：静态分析——枚举 27 case 中哪些需要对手模板以外的判据(由 case 文档 §3 的"结构性瓶颈"字段汇总)。无需单独跑实验。
- **C-sys(回溯窗)**：见 §5.7,另跑长 run(2000 步)限制存储预算测极限。

## 5.3 离线对手的特殊处理（StragglerAnalysis / SuperBench）

这两个对手是离线分析工具,不 LD_PRELOAD 到训练里：
- **数据来源**：一律使用 **B run（纯注入无工具）** 导出的 trace——不用 C run,避免 Probing 常驻采集对 timing 的微扰影响离线分析
- **喂入方式**：转换为对手要求的格式（parquet / summary）
- **公平性**：它们看到的数据量 ≤ 在线工具看到的（因为离线只有导出的部分,不是全量流式）
- **标注**：论文中明确标注"离线分析"vs"在线检测",不混到一条曲线；标注"离线对手使用 B-run trace"

## 5.4 正式 run 的步骤

```
门禁检查(§5.3) → Pilot 已完成确认 → 启动训练 → [warmup] → [干净运行]
→ [注入器启动] → [注入期: 检测脚本自动执行] → [观察恢复]
→ 收数据 → 判分脚本 → 记录
```

### 前置确认（每个正式 run 前）
- [ ] §5.3 门禁全部通过
- [ ] 该 case 的 Pilot(阶段一)已完成,注入生效性已确认
- [ ] 该 case 的检测方案(阶段二)已冻结,脚本版本锁定
- [ ] 确认 seed 和配置与本组其他 run 一致
- [ ] Ground-truth 记录器就绪

### 启动顺序
1. 启动训练（附带对应工具：A 不挂、C 挂 Probing、D 挂 Greyhound...）
2. 注入器在 step N_inject 自动触发（或由外部调度在训练到 step 150 时启动）
3. Ground-truth 记录器同步落盘

### 收数据
- 训练侧：step_timing.jsonl（每步必有）
- 检测工具侧：各自输出（Probing=SQL dump / Greyhound=检测 log / ...）
- Ground-truth：注入器元数据
- 系统快照：节点配置、环境变量、版本号

## 5.5 健康基线（A 线）的特殊要求

- A 线是**所有比较的锚**——如果 A 线本身不稳定,后面什么都比不了
- **稳定性判据**：A 线 step_time 的变异系数(CV) < 5%。若超过 → 环境有问题,先排查
- **建议多跑几次 A**（seed 42/43/44），确认确定性训练确实确定
- A 线同时用于：
  - 检测工具的 FPR 测试（在 A 上跑检测规则,应该不触发）
  - Eval-A 开销基准（C 相对 A 的差）

## 5.6 重复策略

| 组别 | 重复次数 | seed |
|---|---|---|
| 每个 case 的 A/B/C/D/E 一组 | ≥3 组 | 42 / 43 / 44 |
| 每组内各 run | 1 次（确定性训练 + 同 seed 理论结果一致） |
| 若某组结果异常 | 加跑 1-2 次排查 | 45 / 46 |

> **为什么同 seed 只跑一次**：确定性训练（固定 seed + 固定硬件 + 固定 config）的 step_time 理论上是确定的。如果同 seed 跑两次结果不同 → 说明有不可控的环境噪声,需先解决。不同 seed 跑 3 组是为了证明结论不依赖于特定随机种子。
>
> **一致性校验**：同 seed 也建议跑 2 次确认一致性;若两次结果 step_time CV>3% 说明有环境噪声,需排查后再正式跑。

## 5.7 Eval-C 回溯捕获率专项实验

**场景**：制造"onset 早、发现晚"(注入从 step 50 开始,但"发现"延迟到 step 300 才执行检测查询)

**选 case**：8A(GC 骤停)、2C(编译尖刺)——onset 早于发现的典型

**协议**：
- 注入从 step 50 开始(比标准早 100 步)
- 检测查询延迟到 step 300 才执行
- 比较各工具在 step 50-300 窗口内能查到多少遥测记录

**捕获率定义**：P% = 工具在 onset 窗口(step 50-300)内每步有 ≥1 条可查记录的步数 / 总窗步数

**对照**：对手(定时采样工具)在同一窗口内有记录的比例 = Q%

**存储预算对齐**：所有工具在同一常驻内存限制下比较(如 PROBING_COLD_MAX_TOTAL_MB=256)

## 5.8 D5 处置闭环 run（可选）

部分 case（如 P1-EXT-A）可做处置验证：
- 注入不在 step 350 停,持续到 run 结束
- 在 step 350 执行处置(kill sidecar / 恢复配置)
- 观察 step 350-500 的恢复曲线
- 只对第一梯队 case 做,不是每个 case 必跑

**判定标准**：处置后连续 10 步 step_time 回到注入前均值 ±10% → 记为 D5。

---

# 六、数据管理与记录

## 6.1 目录结构标准

```
results/<cluster>/<experiment_batch>/
├── manifest.yaml                    # 本批次所有 run 的索引
├── baseline/                        # 健康基线 run
│   ├── run_<timestamp>_baseline/
│   │   ├── manifest.yaml            # 单 run 元数据
│   │   ├── training/                # 训练产物
│   │   │   └── step_timing.jsonl
│   │   ├── probing/                 # Probing 数据
│   │   │   └── query_results.json
│   │   └── system/                  # 系统快照
│   │       └── env_snapshot.yaml
│   └── ...
├── cases/
│   ├── P1-EXT-A_loud_seed42/        # case × 剂量 × seed
│   │   ├── manifest.yaml
│   │   ├── training/
│   │   ├── probing/
│   │   ├── injection/
│   │   │   ├── ground_truth.yaml    # 注入器落盘的真值
│   │   │   └── injector.log
│   │   ├── baselines/               # 对手输出
│   │   │   ├── greyhound/
│   │   │   ├── straggler_analysis/
│   │   │   └── ...
│   │   └── verdict/                 # 判分结果
│   │       ├── probing_verdict.yaml
│   │       ├── greyhound_verdict.yaml
│   │       └── ...
│   └── ...
└── summary/
    ├── scoring_table.csv            # 汇总判分表（所有 case × 工具）
    └── figures/                     # 论文图表数据
```

## 6.2 Run Manifest Schema（每次 run 必填）

```yaml
# manifest.yaml
run_id: "20260724_143022_P1-EXT-A_loud_s42"
timestamp: "2026-07-24T14:30:22+08:00"
case_id: "P1-EXT-A"
case_name: "同卡算力抢占"
dose: "loud"
dose_params:
  gpu_util_injected: 80%  # 具体注入参数
seed: 42
scale:
  nnodes: 4
  nproc_per_node: 8
  world_size: 32
versions:
  training_script: "abc1234"  # git commit
  probing: "def5678"
  injection_script: "ghi9012"
  detection_program: "jkl3456"  # 冻结版本
nodes:
  - hostname: "worker-80"
    gpu_model: "C550"
    firmware: "v2.1.3"
ground_truth:
  target_rank: 7
  target_host: "worker-82"
  t_on_step: 150
  t_off_step: 350
  intensity: "80% gpu util by sidecar"
duration:
  total_steps: 500
  warmup_steps: 50
  inject_start: 150
  inject_end: 350
status: "completed"  # completed / failed / partial
notes: ""
```

## 6.3 实验复核检查清单（每批次完成后）

- [ ] 所有 run 的 manifest 完整填写
- [ ] ground-truth 文件存在且和 manifest 一致
- [ ] 健康基线的 FPR ≤ 2%（检测程序在基线上误报 ≤9/450 步）
- [ ] 每个 case 至少 3 次重复
- [ ] 判分表中无空行（每个 run 都有判定）
- [ ] 训练脚本版本在整个批次中一致
- [ ] 检测程序版本在整个批次中一致（冻结后未改）
- [ ] 对手代码版本记录且和论文引用一致
- [ ] 数据已回拉到本机 `results/` 备份

---

# 七、特殊情况处理

## 7.1 注入不生效

现象：Loud 档注入了但 step_time 无变化。
处理：
1. 先查注入器日志确认真的在跑
2. 若注入路径被训练逻辑隐藏（如 prefetch 完全掩盖 host 注入）→ 不是注入失败,是该 case 在该训练配置下**不可咬**
3. 记录为 `injection_ineffective`，该 case 不计入 27 的分母（诚实报告"该 case 在该配置下不适用"）
4. 不强行调训练配置去迁就注入——训练配置固定（§2.1）

## 7.2 检测程序在某 case 上判错

现象：Probing 检测程序到了 D3 但方向指错。
处理：
1. 如实记录错误的 D-level（按 §4.2 规则,D3 错了算 D2 或按最高正确级）
2. **不回头改检测程序**（冻结铁律）
3. 在 notes 中记录"误判原因分析"供后续改进
4. 汇总时如实报告——误判率本身是论文需要报的指标

## 7.3 对手环境不可用

现象：Greyhound 需要 CUDA/NCCL 特定版本,在沐曦上跑不通。
处理：
1. 记录为 `ENV-BLOCKED`（环境阻断），**不是 0/27**
2. 不包装成"Probing 优势"——对手没执行到检测逻辑,不能说它检不到
3. 在论文中标注"N/A (env incompatible)"，与 D0（执行了但没检出）区分
4. 若对手只能在特定环境跑,另行搭建该环境做公平对照（或标注适用范围）

## 7.4 判分边界争议

处理：
1. 两人独立判分,不一致时讨论达成共识
2. 争议 case 在 notes 中记录双方理由
3. 最终取**保守判定**（低的那个 D-level）
4. 论文中报告争议比例

---

# 八、产出物与论文数字对应

| 论文数字 | 来源 | 计算方式 |
|---|---|---|
| M/27 | scoring_table.csv, tool=Probing | count(d_level ≥ 4) / 27（取 Quiet 档中位数） |
| K/27 | scoring_table.csv, tool=best_competitor | 同上 |
| X% | 健康 run 有/无 Probing 的 step_time 比 | (with - without) / without × 100% |
| P% | Eval-C 回溯实验 | Probing 在 onset 前窗口能查到的信号比例 |
| Q% | Eval-C 对手 | 对手在同一窗口能查到的比例 |
| 重启代价 | Eval-A1 | 对手重启恢复的 GPU-hours vs Probing=0 |

---

# 九、执行优先级（建议顺序）

1. **健康基线 run**（必须最先）→ 冻结阈值
2. **第一梯队 case × Loud 档**（3A/9A/9B/8A）→ 跑通全链路、验证 SOP 可执行
3. **接入对手**(CPU 三件套先行)→ 同一批数据喂对手,验证对照管线
4. **Eval-A1 + Eval-C1**（不需大规模,快出数字）
5. **第一梯队 × Quiet/Masked 档** → 出 M/27 vs K/27 第一版
6. **第二梯队 case** → 补覆盖
7. **Eval-D 规模扫描** → 出开销斜率 + 掩蔽律

---

# 附：术语表

| 术语 | 操作性定义 |
|---|---|
| 检测方案 | 执行人针对具体 case 设计的查询+判据,记录在案,可复现 |
| ground-truth | 注入器落盘的元数据,是判分 D2–D5 的唯一真值 |
| 冻结 | 某个 case 的检测方案在正式 run 前定稿,正式 run 中不改 |
| D-level | 检测方案对一个 case 能到达的最深定位层级(0–5) |
| 触发覆盖 | D1+ 的 case 比例(能检出) |
| 诊断覆盖 | D4+ 的 case 比例(能到根因) |
| FPR | 健康 run (A 线) 上误报的比例(≤2% 可接受) |
| IoU | 报告时间窗和注入时间窗的交并比 |
| 平行 run 组 | 同一 case 的 A/B/C/D/E... 一组 run,唯一变量是检测工具 |

---

# 附：Case 细化文档

每个 case 有独立文档 `docs/fail-slow/cases/<case_id>.md`,基于模板 `TEMPLATE.md`。

**文档结构**:
- §1 注入方案（怎么注入、三档剂量、时序、ground-truth 格式）
- §2 Probing 检测方案（SQL 序列 + 判据,由执行人设计）
- §3 对手检测方案（各对手能用的判据 + 预期 D-level）
- §4 执行检查清单（跑前确认）
- §5 实验结果（跑后填写：run 记录、注入验证、检测结果、开销、SQL 实录）

**SOP 是宏观框架,case 文档是具体执行手册。** 两者的关系:
- SOP 定义"怎么跑"(平行 run 结构、判分规则、数据管理)
- Case 文档定义"跑什么"(具体注入方法、具体检测 SQL、具体结果记录)

已创建:
- `docs/fail-slow/cases/TEMPLATE.md` — 空模板
- `docs/fail-slow/cases/P1-EXT-A.md` — 填好的范例(3A 同卡算力抢占)
