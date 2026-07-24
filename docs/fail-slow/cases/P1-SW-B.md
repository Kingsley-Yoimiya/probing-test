# Case P1-SW-B：动态 shape 触发次优 kernel

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（普通用户，改数据分布/框架 flag）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-SW-B |
| Case 名称 | 动态 shape 触发次优 kernel（Dynamic Shape Triggering Suboptimal Kernel） |
| 27 格坐标 | 位置: P1 芯片 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | 普通用户（改数据分布 / 框架 flag） |

---

## 1. 注入方案

### 1.1 故障机制
Dataloader 在大部分 step 使用固定序列长度，偶尔混入罕见 padding 长度，触发底层库（如 cuDNN/MACA autotuner）重新选 kernel 或选中次优 kernel。与 P1-SW-C 的一次性编译尖刺不同，本 case 的次优选择是**持久性**的：每当该 shape 再次出现，runtime 都走慢路径（autotuner 缓存了次优结果，或 shape 不在 cache 命中范围内每次重新 autotune）。真实场景：NLP 训练中 bucket 分桶不均匀、dynamic padding 策略导致少数 step 的 tensor shape 落入低效区。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 自定义 Dataloader wrapper，按频率注入异常序列长度 |
| 启动方式 | 训练脚本内通过环境变量 `INJECT_SHAPE_RATIO` + `INJECT_START_STEP` 控制 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-SW-B/shape_inject_dataloader.py` |
| 依赖 | GPT-2 124M 训练脚本；自定义 collator 支持动态 padding |

**注入器核心逻辑**：在正常 batch（固定 seq_len=128）的基础上，从 step 150 开始按指定频率将某些 step 的 seq_len 替换为异常值（如 seq_len=97 或 seq_len=173），使 kernel autotuner 选择次优算法。
- 异常 shape 选择：避开 2 的幂次与常见 cache 命中尺寸，故意选择非对齐长度
- 每次异常 shape 出现，对应 step 的 matmul/attention kernel 走慢路径

### 1.3 剂量三档

| 档位 | 异常 shape 频率 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 50%（每隔 1 步） | 受影响步 +40%~80%，均值 +25%~40% | 极其明显的双峰分布 |
| **Quiet** | 20%（每隔 4 步） | 受影响步 +40%~80%，均值 +10%~15% | 双峰可见但均值偏移不大 |
| **Masked** | 5%（每隔 19 步） | 受影响步 +40%~80%，均值 +3%~5% | 偶发慢步，均值几乎不变 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 注入触发时机 | step 150 | warmup 50 步后正常跑 100 步再注入 |
| 注入持续时长 | step 150 → 500（直到训练结束） | |
| 注入模式 | 周期性（每 N 步一次异常 shape） | N 由剂量档位决定 |
| 特殊时序 | 非持续恒定——只有异常 shape 步慢，正常 shape 步不受影响 | 区别于 P1-EXT-A 持续干扰 |
| 注意事项 | 异常 shape 值需固定（如始终用 97），确保每次命中同一慢路径 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-SW-B"
target_rank: 0               # 所有 rank 同时受影响（数据分布层注入）
target_host: "worker-all"
target_gpu: "all"
t_on_step: 150
t_off_step: 500              # 直到训练结束
intensity: "shape_ratio=50%,abnormal_seq_len=97"
dose: "loud"
seed: 42
injector_commit: "TBD"
injection_pattern: "periodic_every_2_steps"
abnormal_shape: [97]         # 注入的异常序列长度
normal_shape: 128            # 正常序列长度
timestamp: "2026-07-23T00:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
动态 shape 次优 kernel 的核心特征：step_time 呈**双峰分布**（正常 shape 步快、异常 shape 步慢），且慢步稳定复现（不是随机抖动而是确定性关联到特定 shape）。因此：
- L0: 看 step_time 是否存在双峰/高方差模式（straggler ratio 可能不明显因为所有 rank 同时受影响）
- L2: 按 rank 比较——如果全体 rank 同步出现双峰，说明不是单点硬件故障
- L3: 分解到 kernel/op 粒度——找到哪些 op 存在高方差，按 shape 分桶看 p50 差异。`python.torch_trace` 中同一算子不同 shape 的 duration 应呈双峰
- L4: 确认是 P1-SW（芯片软件层 kernel 选择问题，不是硬件故障也不是外部干扰）

**关键信号**：`python.torch_trace` 中特定 op（如 `aten::mm`、`aten::bmm`）的 duration 双峰分布 + 慢 bucket 与异常 shape 的时间相关性。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— step_time 是否呈双峰或高方差
SELECT rank,
       avg(duration_ms) as avg_ms,
       stddev(duration_ms) as std_ms,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) as p50_ms,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 500
  AND phase = 'step'
GROUP BY rank
ORDER BY std_ms DESC;
-- 判据: p99/p50 ≥ 1.3 且 std/avg > 0.15 → 存在双峰模式
-- 注意: 若所有 rank 的 std 都高 → 全局数据层问题（非单点）

-- Step 2: 定位 —— 找到双峰的快/慢分界
SELECT rank,
       step,
       duration_ms,
       CASE WHEN duration_ms > <p50_ms> * 1.2 THEN 'slow' ELSE 'fast' END as bucket
FROM python.torch_trace
WHERE step BETWEEN 150 AND 500
  AND phase = 'step'
  AND rank = 0
ORDER BY step;
-- 判据: slow bucket 的 step 是否呈周期性模式（如每隔 N 步一次）
-- 若周期性明显 → 指向数据层周期性变化

-- Step 3: 归因 —— 按 op 分解,找高方差算子
SELECT name as op_name,
       count(*) as call_count,
       avg(duration_us) as avg_us,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_us) as p50_us,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_us) as p99_us,
       (percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_us)) /
       NULLIF(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_us), 0) as p99_p50_ratio
FROM python.torch_trace
WHERE step BETWEEN 150 AND 500
  AND rank = 0
  AND phase = 'kernel'
GROUP BY name
HAVING count(*) > 50
ORDER BY p99_p50_ratio DESC
LIMIT 20;
-- 判据: 特定 matmul/attention kernel 的 p99/p50 ≥ 1.5
-- → 该 kernel 存在 shape-dependent 性能差异

-- Step 4: 确认 —— 排除网络/外部因素
SELECT rank,
       avg(duration_us) as avg_comm_us,
       stddev(duration_us) as std_comm_us
FROM python.comm_collective
WHERE step BETWEEN 150 AND 500
GROUP BY rank;
-- 如果通信时间方差不大,但计算 kernel 双峰明显
-- → 排除网络问题 → 确认 P1(芯片层,kernel 选择)
-- → 与外部争用的区别: 外部争用是所有 kernel 等比变慢,
--   这里是特定 kernel 慢(shape-dependent)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| step_time p99/p50 | ≥1.3 | 存在双峰模式 |
| step_time std/avg | >0.15 | 方差异常高 |
| 慢步周期性 | 周期 = 注入间隔 | 指向数据层触发 |
| 特定 kernel p99/p50 | ≥1.5 | 确认是 kernel 级差异 |
| 通信时间方差 | 正常（std/avg < 0.1） | 排除网络层问题 |
| 慢步 kernel profile vs 快步 | 同 op 不同 duration | 确认 shape-dependent |

### 2.4 预期定位路径

```
L0(std/avg=0.25, 双峰) → L2(所有 rank 同步双峰, 全局数据层)
→ L3(aten::mm p99/p50=1.8, shape-dependent kernel 次优选择) → L4(P1-SW: 芯片×软件缺陷)
```

### 2.5 预期 D-level
**D4**（定位到 P1-SW: kernel 选择次优 + shape 关联）。若能进一步关联具体 autotuner 选择记录则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast)；若均值偏移足够大可检出 D1-D2 |
| 预期能到 D 几 | **D1-D2**：Loud 档均值偏移 +25%~40% 可能触发变点，但双峰低频率(Masked 档 5%)可能不触发 changepoint；无 kernel 级可视性，无法识别 shape/kernel 问题 |
| 结构性瓶颈 | Greyhound 无 per-kernel profiling，不能看到"同一 op 不同 shape 双峰"；变点检测对周期性双峰不如对阶跃敏感 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 step timing parquet |
| 该 case 能用的判据 | 均值比较 S = mean(nodelay)/mean(noblk)；若全体 rank 同步变慢则 straggler ratio 不高 |
| 预期能到 D 几 | **D1-D2**：能看到整体变慢（Loud 档），但因所有 rank 同步双峰，straggler ratio 可能正常；无法识别根因 |
| 结构性瓶颈 | 基于均值的方法对双峰分布不敏感；无 kernel 级数据 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 方差异常高） |
| 预期能到 D 几 | **D1**（能发现异常，但无 shape/kernel 归因） |
| 结构性瓶颈 | 有信号无诊断；对"什么导致慢"没有答案 |

---

## 4. 执行检查清单

- [ ] shape 注入 dataloader 在 GPT-2 124M 上测试过（Loud 档确认双峰 step_time）
- [ ] 异常 shape（seq_len=97）确认能触发次优 kernel（对比 seq_len=128 的 kernel 时间）
- [ ] 训练配置确认：500 steps / warmup 50 / seed 42
- [ ] Probing 配置：PROBING=2, PROBING_TORCH_PROFILING=on:rate=1.0
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档验证能检出双峰 + kernel 归因
- [ ] Greyhound LD_PRELOAD 在该环境能跑通
- [ ] 验证 Masked 档（5%）的双峰是否仍可在 Probing 中检出

---

## 5. 实验结果（跑后填写）

### 5.1 Run 记录

| Run | Seed | 日期 | 剂量 | 状态 | Run ID |
|---|---|---|---|---|---|
| A (baseline) | 42 | | — | | |
| B (injection) | 42 | | loud | | |
| C (Probing) | 42 | | loud | | |
| D (Greyhound) | 42 | | loud | | |

### 5.2 注入生效性验证

| 指标 | A 线 | B 线 | 差异 | 结论 |
|---|---|---|---|---|
| step_time mean (ms) | | | | |
| step_time p99/p50 | | | | 双峰比 |
| 慢步 kernel duration vs 快步 | — | | | shape 关联确认 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |
| XPUTimer | | | | | |

### 5.4 开销影响

| 指标 | A 线 | C 线(Probing) | 开销% | D 线(Greyhound) | 开销% |
|---|---|---|---|---|---|
| step_time mean | | | | | |

### 5.5 实际执行的 SQL 记录

```sql
-- (跑后粘贴实际查询和结果)
```

### 5.6 结论与备注

- 

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
