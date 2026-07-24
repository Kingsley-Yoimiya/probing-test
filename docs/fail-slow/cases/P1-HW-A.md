# Case P1-HW-A：热墙渐进降频

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（需 admin 权限做频率/功耗锁定）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-HW-A |
| Case 名称 | 热墙渐进降频（Thermal Throttle Progressive Clock Reduction） |
| 27 格坐标 | 位置: P1 芯片 × 来源: HW 硬件退化 |
| 梯队 | 第二梯队 |
| 权限要求 | Admin（需 root 或设备管理权限做频率/功耗墙变更）；若设备接口只读，仅能用"重负载逼近热墙"弱代理 |

---

## 1. 注入方案

### 1.1 故障机制
结温(Junction Temperature)逼近上限，电源管理单元(PMU)逐步降低计算/显存频率。计算密集阶段对频率近似线性敏感——频率下降 x% 则 compute kernel 延长约 x%。真实场景：机房散热不足、风扇故障、GPU 散热膏老化、长时间高负载后温度渐升触发 throttle。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 频率锁定（首选）或持续重负载 sidecar 逼近热墙（备选） |
| 启动方式 | 训练到 step 150 后触发，频率从基线线性递减至 step 350 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-HW-A/thermal_throttle.py` |
| 依赖 | 首选：`nvidia-smi -lgc` 或沐曦等效的时钟锁定接口（需 admin）；备选：同卡重负载 + 散热限制 |

**注入器核心逻辑**：
- **首选路径（admin）**：使用 `nvidia-smi -lgc <min>,<max>` 或等效接口，从 step 150 起每 N 步降低 GPU 最大频率，模拟渐进热降频。
- **备选路径（弱代理）**：在目标 GPU 上起持续重负载 sidecar + 限制风扇转速/功耗墙，让温度自然爬升触发硬件 throttle。
- **关键**：注入是 PROGRESSIVE/LINEAR——频率随时间单调递减，不是阶跃。

### 1.3 剂量三档

| 档位 | 频率锁定 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 锁定至基频 50% | +80%~150% | 极度明显,温度高+频率低 |
| **Quiet** | 锁定至基频 75% | +20%~40% | 稳定可检出 |
| **Masked** | 锁定至基频 90% | +5%~10% | 接近噪声水平 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 注入触发时机 | step 150 | 训练已稳定 |
| 注入持续时长 | 200 步（150→350） | |
| 特殊时序 | PROGRESSIVE/LINEAR — 频率从 step 150 到 350 线性递减 | 非阶跃，模拟真实热降频曲线 |
| 频率变化率 | (base_freq × dose_pct) / 200 步 per step | Loud: 每步 ≈0.25% 降幅 |
| 注意事项 | 必须在 step 150 前记录基线频率和温度 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-HW-A"
target_rank: 7           # 被降频的 rank
target_host: "worker-82"
target_gpu: 7            # 该节点上的 GPU index
t_on_step: 150
t_off_step: 350
injection_type: "progressive_linear"
intensity: "clock_lock_to_50%_base"
dose: "loud"
freq_start_mhz: 1410    # 基线频率（跑后填实际值）
freq_end_mhz: 705       # 终点频率
seed: 42
injector_commit: ""
injector_pid: null       # 频率锁定无独立 PID；弱代理模式才有
timestamp: "2026-07-23T00:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
热墙降频的特征：被降频 rank 的 **compute 阶段渐进变慢**（频率线性下降），step_time 单调递增；GPU utilization 可能仍然很高（满负荷跑但频率低了）；**温度↑ 与 频率↓ 强相关**——这是区分热降频与其他 compute 变慢的关键。

- L0: 看 step_time 离群（有 straggler），且呈渐进上升趋势
- L2: 按 rank 比 step_time，找最慢的（持续最慢且差值递增）
- L3: 看该 rank 的 GPU 时钟频率和温度——若 clock_mhz 渐降 AND temperature 渐升 → 热降频
- L4: 确认是 P1(芯片级) × HW(硬件退化)：频率/温度是硬件层指标，非外部进程

**关键信号**：`gpu.utilization` 中的 `clock_mhz`（GPU 实际时钟）与 `temperature`（结温），二者呈负相关。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有渐进式 straggler
-- 注意: gpu.utilization 是时间采样表，无 step 列，需与 torch_trace JOIN
WITH step_windows AS (
  SELECT rank, step,
         min(start_ts) as step_start,
         max(start_ts + duration_ms * 1000000) as step_end,
         duration_ms
  FROM python.torch_trace
  WHERE step BETWEEN 100 AND 350
    AND phase = 'step'
  GROUP BY rank, step
)
SELECT rank, step,
       duration_ms
FROM step_windows
WHERE rank = <suspect_rank>
ORDER BY step;
-- 判据: duration_ms 在 step 150 后单调递增 → 渐进式 straggler

-- Step 2: 定位 —— 哪个 rank 是渐进变慢的
SELECT rank,
       avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END) as baseline_ms,
       avg(CASE WHEN step BETWEEN 300 AND 350 THEN duration_ms END) as late_ms,
       (avg(CASE WHEN step BETWEEN 300 AND 350 THEN duration_ms END) 
        - avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END))
       / avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END) as degradation_ratio
FROM python.torch_trace
WHERE phase = 'step'
GROUP BY rank
ORDER BY degradation_ratio DESC;
-- 判据: degradation_ratio 最高的 rank 为嫌疑 rank

-- Step 3: 归因 —— 温度-频率相关性（时间窗口 JOIN）
WITH step_windows AS (
  SELECT rank, step,
         min(start_ts) as step_start,
         max(start_ts + duration_ms * 1000000) as step_end
  FROM python.torch_trace
  WHERE step BETWEEN 150 AND 350
    AND phase = 'step'
    AND rank = <suspect_rank>
  GROUP BY rank, step
),
gpu_metrics AS (
  SELECT g.rank, sw.step,
         avg(g.clock_mhz) as avg_clock,
         avg(g.temperature) as avg_temp,
         avg(g.power_w) as avg_power
  FROM gpu.utilization g
  JOIN step_windows sw 
    ON g.rank = sw.rank
    AND g.timestamp BETWEEN sw.step_start AND sw.step_end
  GROUP BY g.rank, sw.step
)
SELECT step, avg_clock, avg_temp, avg_power
FROM gpu_metrics
ORDER BY step;
-- 判据: clock_mhz 随 step 递减 AND temperature 随 step 递增 → 热降频
-- 计算 corr(temperature, clock_mhz) < -0.7 → 强负相关确认

-- Step 4: 排除 —— 排除外部进程抢占
SELECT rank,
       avg(send_gpu_wait_ns) as send_wait,
       avg(recv_wait_ns) as recv_wait
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>;
-- send_gpu_wait 高(计算慢导致发送晚) + recv_wait 低
-- → 该 rank 是 culprit → 排除网络
-- 加上温度-频率证据 → 确认 P1-HW（芯片硬件退化）非 P1-EXT（外部争用）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| degradation_ratio (late/baseline - 1) | ≥0.2 (Quiet 档) | 触发渐进 straggler 告警 |
| 单调递增检测 (step_time vs step) | Spearman ρ ≥ 0.8 | 确认是渐进而非阶跃 |
| corr(temperature, clock_mhz) | < -0.7 | 温度↑ 与频率↓ 强负相关 |
| clock_mhz 变点/渐降 | 终点 < 基线 × 0.85 | 频率确有下降 |
| send_gpu_wait 高 + recv_wait 低 | culprit 模式 | 排除网络,确认计算层 |

### 2.4 预期定位路径

```
L0(ratio=2.5, straggler, monotonic increase) → L2(rank 7, degradation_ratio highest)
→ L3(clock_mhz: 1410→705, temperature: 65→92°C, corr=-0.95) → L4(P1-HW: 芯片×硬件退化)
```

### 2.5 预期 D-level
**D4**（定位到正确的 27 格坐标：温度-频率相关性是 HW 硬件退化的独有特征）。若能停注入后看频率恢复则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast) + 慢组 ≥1.2×中位数 + 计算根因 |
| 预期能到 D 几 | **D3**（能检出 straggler 并定位到 rank，判断是计算类慢），但无 GPU clock/temp 数据，无法区分热降频与其他 compute 变慢 |
| 结构性瓶颈 | 无 `clock_mhz` / `temperature` 时序数据，不能证明"频率降了所以慢"；渐进趋势可能让变点检测灵敏度下降 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 → 指出 straggler |
| 预期能到 D 几 | **D2**（能指出谁慢，但无根因信息） |
| 结构性瓶颈 | 无 GPU 硬件层指标，无法区分任何 compute 变慢的子类型 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常，渐进趋势） |
| 预期能到 D 几 | **D1-D2**（能发现异常,但无自动 RCA） |
| 结构性瓶颈 | 有信号无诊断；渐进变化可能被平滑掉 |

---

## 4. 执行检查清单

- [ ] 确认目标节点有 admin/root 权限或确认退化为弱代理方案
- [ ] 频率锁定接口测试（`nvidia-smi -lgc` 或沐曦等效）
- [ ] 渐进降频脚本测试（Loud 档确认 step_time +80% 以上）
- [ ] 基线温度和频率已记录
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档上验证过能检出温度-频率相关
- [ ] Greyhound LD_PRELOAD 在该环境能跑通
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
| target rank step_time | | | | |
| clock_mhz (start→end) | — | | | 频率确认递减 |
| temperature (start→end) | — | | | 温度确认递增 |

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
