# Case P1-SW-A：显存碎片化→骤停

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（纯软件注入，普通用户权限），核心价值：验证检测系统能否实现**趋势型预警**——在骤停发生之前通过内存指标趋势预测故障。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-SW-A |
| Case 名称 | 显存碎片化→骤停（Memory Fragmentation → Sudden Stall） |
| 27 格坐标 | 位置: P1 芯片 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | 普通用户（纯框架层 Python 代码注入） |

---

## 1. 注入方案

### 1.1 故障机制
显存分配/释放顺序错位（如 activation recomputation 的 release/alloc 顺序不当），碎片化率逐步上升，累积直到 allocator 碎片整理阈值被触发——产生一次可见的多秒暂停。自然表现为"渐进→骤停"模式。真实场景：自定义 memory pool 策略缺陷、大模型中 tensor 生命周期管理 bug、不同 micro-batch 大小导致分配碎片化。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 训练循环内的 Python hook（在 forward/backward 之间插入碎片化操作） |
| 启动方式 | 训练代码中在 step ≥ 150 时激活碎片化逻辑（通过环境变量或 step 判断） |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-SW-A/mem_frag_injector.py` |
| 依赖 | PyTorch `torch.cuda.memory_*` API；无需额外权限 |

**注入器核心逻辑**：
- 每步在 backward 后、optimizer.step 前插入碎片化操作：
  - 分配 N 个不同大小的 tensor（如 1MB, 4MB, 16MB, 2MB, 8MB...）
  - 释放其中部分（如奇数位置），保留偶数位置 → 制造碎片
  - 下一步再释放偶数位置，重新分配新大小 → 碎片累积
- 通过 `leak_per_step` 参数控制每步净泄漏量（碎片无法被 coalesce 的部分）
- 累积到 `reserved - allocated` 超过阈值时，PyTorch caching allocator 触发 `cudaMalloc` 失败→ `torch.cuda.empty_cache()` → 重新分配 → 产生可见暂停

### 1.3 剂量三档

| 档位 | 每步净泄漏 | 预期骤停时机 | 骤停时长 | step_time 表现 |
|---|---|---|---|---|
| **Loud** | 50 MB/step | ~step 280（累积 ~6.5GB） | 3-5s | 骤停时 step_time spike 10x-50x |
| **Quiet** | 20 MB/step | ~step 320（累积 ~3.4GB） | 1-2s | 骤停时 step_time spike 5x-10x |
| **Masked** | 8 MB/step | ~step 380（累积 ~1.8GB，接近训练结束） | 0.5s | 骤停时 step_time spike 2x-3x，几乎隐没于噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热/启动准备 | 无（首步注入即开始碎片化操作，但效果需累积） | |
| 注入触发时机 | step 150 | 碎片化从此步开始累积 |
| 注入持续时长 | 直到训练结束（200 步内自然触发骤停） | |
| 特殊时序 | **渐进→骤停**: step 150 开始累积，骤停在 step 280-380（取决于剂量） | 前 N 步无明显影响（cache pool 未满时分配器可应付），越积越多直到阈值 |
| 注意事项 | 1) 骤停时刻不完全确定（取决于 PyTorch caching allocator 行为）；2) 需确保 GPU 总显存已被训练占用大部分（否则碎片泄漏很久才触发） |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-SW-A"
target_rank: 7
target_host: "worker-82"
target_gpu: 7
t_on_step: 150
t_off_step: 500            # 持续到训练结束
pattern: "progressive_then_stall"
leak_per_step_mb: 50
expected_stall_step: 280   # 估计值，实际可能有 ±10 步偏差
intensity: "leak_50mb_per_step"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-23T14:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
显存碎片化→骤停有两个检测目标：
1. **事后检测**（reactive）：骤停发生后通过 step_time spike 发现——容易但无预警价值
2. **趋势预警**（proactive）：在骤停发生前通过 `reserved - allocated` 单调增长趋势预测——这是本 case 的核心检测价值

检测路径：
- L0: 两条线索并行——a) step_time spike 检测（事后）；b) memory 指标趋势监测（事前）
- L2: 定位是哪个 rank 的内存在持续增长
- L3: 查 `reserved - allocated` gap 的单调增长趋势——这是碎片化的标志性指标（allocated 是实际使用，reserved 是 caching allocator 预留；gap 增长 = 碎片无法回收）
- L4: 确认 P1-SW（芯片×软件缺陷——allocator/碎片化问题，非硬件故障也非外部干扰）

**关键信号**：`gpu.utilization` 表中的 `memory_allocated` 和 `memory_reserved` 随时间单调增长（在注入 rank 上）。

**注意**：`gpu.utilization` 表是时间采样（无 step 列），需通过时间窗口 JOIN `python.torch_trace` 来关联 step。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊（路线 A）—— 有没有 step_time 骤停
SELECT rank,
       avg(duration_ms) as avg_ms,
       max(duration_ms) as max_ms,
       max(duration_ms) / avg(duration_ms) as spike_ratio
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY spike_ratio DESC;
-- 判据: spike_ratio (max/avg) ≥ 5 → 有骤停事件
-- 注: 如果骤停发生在 350 之后(Masked 档), 需扩大窗口到 step 500

-- Step 1b: 分诊（路线 B）—— 内存趋势监测（关键！可在骤停前预警）
WITH step_memory AS (
  SELECT s.rank, s.step,
         avg(g.memory_reserved_mb) as reserved_mb,
         avg(g.memory_allocated_mb) as allocated_mb,
         avg(g.memory_reserved_mb) - avg(g.memory_allocated_mb) as frag_gap_mb
  FROM python.torch_trace s
  JOIN gpu.utilization g
    ON g.rank = s.rank
    AND g.timestamp BETWEEN s.start_ts AND s.end_ts
  WHERE s.step BETWEEN 150 AND 350
    AND s.phase = 'step'
  GROUP BY s.rank, s.step
)
SELECT rank,
       corr(step, frag_gap_mb) as gap_trend_corr,
       max(frag_gap_mb) - min(frag_gap_mb) as gap_growth_mb,
       regr_slope(frag_gap_mb, step) as gap_slope_mb_per_step
FROM step_memory
GROUP BY rank
ORDER BY gap_trend_corr DESC;
-- 判据: gap_trend_corr > 0.9 (强单调增长) AND gap_slope > 0 → 碎片累积趋势
-- 这是"事前预警"的核心: 不等骤停发生就能发现问题

-- Step 2: 定位 —— 哪个 rank 有内存增长趋势
SELECT rank, step,
       reserved_mb, allocated_mb, frag_gap_mb
FROM step_memory  -- (复用上面的 CTE)
WHERE rank = <suspect_rank>
ORDER BY step;
-- 可视化: frag_gap_mb 应呈线性增长，斜率 = leak_per_step

-- Step 3: 归因 —— 确认碎片化模式
-- 如果骤停已发生：
SELECT rank, step, duration_ms
FROM python.torch_trace
WHERE rank = <suspect_rank>
  AND phase = 'step'
  AND duration_ms > 5 * <baseline_avg_ms>
ORDER BY step;
-- 判据: 存在单点 spike + 前面步骤逐渐略微变慢 → 碎片化积累→骤停模式
-- 关键: reserved - allocated 单调增长 + 突发长暂停 = 碎片化→defrag 暂停

-- Step 4: 根因层 —— 排除硬件和外部
SELECT rank,
       avg(gpu_utilization) as util,
       avg(power_draw_w) as power,
       max(throttle_reasons) as throttle
FROM gpu.utilization g
JOIN python.torch_trace s
  ON g.rank = s.rank
  AND g.timestamp BETWEEN s.start_ts AND s.end_ts
WHERE s.rank = <suspect_rank>
  AND s.step BETWEEN 150 AND 350
  AND s.phase = 'step'
GROUP BY rank;
-- 判据: GPU util/power/throttle 正常 → 排除 HW 降频/功耗墙
-- 结合 memory 趋势 → 确认 P1-SW（芯片软件层：allocator 碎片化）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| spike_ratio (max/avg step_time) | ≥5 | 事后检测：存在骤停事件 |
| frag_gap_trend_corr | >0.9 | 事前预警：reserved-allocated gap 单调增长 |
| gap_slope (MB/step) | >5 MB/step | 碎片化速率异常（正常应 ≈0） |
| gap_growth 总量 | >1 GB | 碎片累积量显著 |
| GPU util/power/throttle | 正常 | 排除硬件原因 |
| 无外部 PID 占用 | True | 排除外部争用 |

### 2.4 预期定位路径

```
L0(路线A: spike_ratio=20, 骤停; 或路线B: gap_corr=0.98, 趋势预警)
→ L2(rank 7, frag_gap 单调增长 50MB/step)
→ L3(reserved-allocated gap 从 200MB 涨到 6.5GB, 然后触发 defrag 暂停)
→ L4(P1-SW: 芯片×软件缺陷, allocator 碎片化)
```

### 2.5 预期 D-level
**D4**（定位到 P1-SW 坐标 + 识别碎片化→骤停机制）。若能在骤停前通过趋势预警发出告警则视为 D4+（超越对手的结构性优势）。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast)——骤停发生时 step_time 突变；慢组 ≥1.2×中位数 |
| 预期能到 D 几 | **D2**：能在骤停发生后检出变点(step_time spike)，能定位到慢 rank，但 1) 无法做趋势预警（骤停前无信号）；2) 无内存指标，无法识别"碎片化"根因；3) 只能判断"某 rank 某刻突然变慢"→ D2 |
| 结构性瓶颈 | 1) 变点检测是事后的（骤停已发生才触发）；2) 无 GPU memory 指标接口（reserved/allocated）；3) 无法做趋势预测，无法区分"碎片化骤停"和"随机 spike" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03；单点 outlier 检测 |
| 预期能到 D 几 | **D1-D2**：离线分析能看到 step_time 中的骤停 spike，但 1) 均值指标被骤停前的正常步数稀释；2) 无内存数据无法归因；3) 完全无趋势预警能力 |
| 结构性瓶颈 | 1) 离线 + 均值导向 → 单点骤停在均值中被淹没（尤其 Masked 档）；2) 无 GPU telemetry；3) 无法区分骤停原因 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常） |
| 预期能到 D 几 | **D1**：能捕捉到骤停时的 step duration 异常信号，但无自动 RCA，无内存指标关联 |
| 结构性瓶颈 | 有信号无诊断；无趋势预警能力；无内存/allocator 层面的可观测性 |

---

## 4. 执行检查清单

- [ ] 碎片化注入器在目标 GPU 上测试通过（Loud 档确认 ~130 步后触发骤停）
- [ ] 确认训练占用的 GPU 显存足够高（>60% 总显存），使碎片化能在合理步数内触发
- [ ] 注入器的 leak_per_step 参数校准（确认不同剂量的骤停时机在预期范围内）
- [ ] PyTorch caching allocator 行为验证（`PYTORCH_CUDA_ALLOC_CONF` 未设置特殊参数）
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml（含实际骤停 step）
- [ ] Probing SQL 在 Loud 档上验证过：趋势检测能在骤停前发现 gap 增长
- [ ] Probing 时间窗口 JOIN 逻辑验证（gpu.utilization 无 step 列）
- [ ] 节点列表和 seed 确认

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
| step_time max (ms) | | | | 骤停时的 spike |
| 实际骤停 step | — | | | 与预期 step 280 对比 |
| reserved-allocated gap 最大值 | | | | 碎片累积量 |
| 骤停时长 (ms) | — | | | defrag 暂停持续时间 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 | 预警？ |
|---|---|---|---|---|---|---|
| Probing (事后) | | | | | | N |
| Probing (趋势) | | | | | | Y/N |
| Greyhound | | | | | | N |
| StragglerAnalysis | | | | | | N |
| XPUTimer | | | | | | N |

### 5.4 开销影响

| 指标 | A 线 | C 线(Probing) | 开销% | D 线(Greyhound) | 开销% |
|---|---|---|---|---|---|
| step_time mean | | | | | |

### 5.5 实际执行的 SQL 记录

```sql
-- (跑后粘贴实际查询和结果)
```

### 5.6 结论与备注

- 核心验证点：Probing 的趋势预警能力（骤停前多少步能预警？）vs 对手的事后检测
- 

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
