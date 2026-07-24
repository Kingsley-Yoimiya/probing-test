# Case 文档模板（TEMPLATE）

> **每个 case 一份文档**，放在 `docs/fail-slow/cases/` 下，命名 `<case_id>.md`（如 `P1-EXT-A.md`）。填写人 = 执行人。跑实验前填好 §1-§4（计划），跑完后填 §5（结果）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | `P?-???-?`（如 P1-EXT-A） |
| Case 名称 | （如"同卡算力抢占"） |
| 27 格坐标 | 位置: P1/P2/P3 × 来源: HW/SW/EXT |
| 梯队 | 第一/第二/第三 |
| 权限要求 | 普通用户 / root / 交换机 / ... |

---

## 1. 注入方案

### 1.1 故障机制（一句话）
> 描述：这个 case 模拟的是什么故障？真实场景中什么条件下会发生？

### 1.2 注入方法
> 具体怎么造出这个故障（注入器是一个独立的进程/sidecar/cgroup 操作/...）

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程 / sidecar / 内核参数 / ... |
| 启动方式 | 如何与训练协调启动（由调度器在 step N 触发 / 定时启动 / ...） |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/<case_id>/` |
| 依赖 | 需要什么额外工具/权限 |

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | （如 GPU 占用 80%） | step_time +100%~200% |
| **Quiet** | （如 GPU 占用 30%） | step_time +20%~50% |
| **Masked** | （如 GPU 占用 15%） | step_time +5%~10%，接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热/启动准备 | （如"注入器需先预热 10s 再开始干扰"） | |
| 注入触发时机 | step 150（默认） | |
| 注入持续时长 | 200 步（默认） | |
| 特殊时序 | （如间歇类: on 50 步 / off 50 步 / on 50 步 / off 50 步） | |
| 注意事项 | （如"必须先设频再起 kernel，否则 shader exception"） | |

### 1.5 Ground-truth 记录

注入器启动时自动落盘以下字段到 `injection/ground_truth.yaml`：

```yaml
case_id: "P1-EXT-A"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "gpu_util_sidecar=80%"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

> **由执行人设计,跑实验前写好(可迭代调试),正式 run 前冻结。**

### 2.1 检测思路（自然语言）
> 描述：对于这个 case,用 Probing 的什么接口、什么表、什么逻辑能检测出来？为什么选这条路？

### 2.2 检测 SQL 序列（示例/默认）

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: max(avg_ms) / median(avg_ms) ≥ 1.5

-- Step 2: 定位 —— 谁慢
-- (根据 Step 1 结果选择怀疑对象)

-- Step 3: 归因 —— 为什么慢
-- (针对怀疑对象进一步查)

-- Step 4: 根因层 —— 27 格的哪一格
-- (综合证据给出坐标)
```

> **注意**：以上 SQL 是默认示例。执行人可以根据实际探索结果修改/替换,但最终冻结版本必须记录在本文档。

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| （如 straggler ratio） | ≥1.5 | （执行人定） |
| （如 gpu_util_other） | >10% | |
| ... | ... | |

### 2.4 预期定位路径

```
L0(straggler ratio=?) → L2(rank ?) → L3(机理=?) → L4(P?-???-?)
```

### 2.5 预期 D-level
> D4 / D5 / ...（跑前预期,跑后对照）

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | （从 Greyhound 代码中找,该 case 相关的规则） |
| 预期能到 D 几 | |
| 结构性瓶颈 | （如"无 PID 信息,到 D3 但不到 D4"） |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 trace parquet |
| 该 case 能用的判据 | |
| 预期能到 D 几 | |
| 结构性瓶颈 | |

### 3.3 其他对手
> （按需填写）

---

## 4. 执行检查清单（跑前确认）

- [ ] 注入器脚本可用,已测试 Loud 档能咬到训练
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测方案已冻结（§2 填完）
- [ ] 对手方案已确认（§3 填完）
- [ ] 节点列表确认,硬件健康
- [ ] Seed / config 与本组其他 run 一致

---

## 5. 实验结果（跑后填写）

### 5.1 Run 记录

| Run | Seed | 日期 | 状态 | 备注 |
|---|---|---|---|---|
| A (baseline) | 42 | 2026-07-?? | completed | |
| B (injection-only) | 42 | | | |
| C (Probing) | 42 | | | |
| D (Greyhound) | 42 | | | |
| ... | | | | |

### 5.2 注入生效性验证

| 指标 | A 线（基准） | B 线（注入） | 差异 | 结论 |
|---|---|---|---|---|
| step_time (ms) mean | | | | 注入是否生效 |
| step_time (ms) p95 | | | | |
| 目标 rank step_time | | | | |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 归因层 | 证据摘要 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |
| ... | | | | | |

### 5.4 开销影响

| 指标 | A 线 | C 线(Probing) | 差异(%) | D 线(Greyhound) | 差异(%) |
|---|---|---|---|---|---|
| step_time mean | | | | | |
| GPU util | | | | | |

### 5.5 检测 SQL 实际执行记录

> 正式 run 中实际执行的查询和结果（复制粘贴），供复核：

```sql
-- 实际查询 1
...
-- 结果: ...
```

### 5.6 结论与备注

- 检测成功/失败的原因分析：
- 与预期的差异：
- 对后续 case / 论文的影响：

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-?? | 初始创建 | |
| | | |
