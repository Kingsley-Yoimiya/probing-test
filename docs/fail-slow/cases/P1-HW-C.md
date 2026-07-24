# Case P1-HW-C：功耗墙间歇触发

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（需管理员权限设置功率上限），核心价值：验证检测系统能否捕捉**间歇性**异常——均值正常但尾部周期性异常的场景。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-HW-C |
| Case 名称 | 功耗墙间歇触发（Power Cap Intermittent Trigger） |
| 27 格坐标 | 位置: P1 芯片 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | 管理员（需 `nvidia-smi -pl` 或等效功率限制接口） |

---

## 1. 注入方案

### 1.1 故障机制
共享电源总线争用或机房功率配额周期性调降——功率上限被**周期性**拉低再恢复。与 P1-HW-A（恒定降频）不同，本 case 是间歇性的：均值可能正常，只有尾部（p99/max）出现周期性尖峰。真实场景：数据中心功率预算在高负载时段由 BMS 自动节流、或电力合同中的峰值功率限制周期性生效。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 外部脚本周期性调用功率管理接口（`nvidia-smi -pl` / 沐曦等效 sysfs） |
| 启动方式 | 训练到 step 150 时通过 signal 触发定时器脚本，按 on/off 窗口交替设置功率限制 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-HW-C/power_cap_intermittent.sh` |
| 依赖 | root/admin 权限操作 `nvidia-smi -pl`；需知道目标 GPU 的默认功率上限值 |

**注入器核心逻辑**：
- 获取目标 GPU 默认功率上限 `P_default`（如 300W）
- 在 "on" 窗口（50 步）内：`nvidia-smi -pl <P_reduced>` 设置降低后的功率上限
- 在 "off" 窗口（50 步）内：`nvidia-smi -pl <P_default>` 恢复原始功率上限
- 交替执行 on→off→on→off，覆盖 step 150-350 的 200 步注入窗口
- 步数到窗口的映射：通过监听训练日志的 step 计数或用固定时间估算（基于 baseline step_time）

### 1.3 剂量三档

| 档位 | 功率上限（on 窗口内） | 预期 on-window step_time 变化 | 预期全程 mean 变化 | 说明 |
|---|---|---|---|---|
| **Loud** | 50% P_default（如 150W） | +150% | +40%（均值被拉高） | on 窗口极其明显，mean 也异常 |
| **Quiet** | 70% P_default（如 210W） | +50% | +15% | on 窗口可见，mean 轻微异常 |
| **Masked** | 85% P_default（如 255W） | +20% | +5% | on 窗口弱信号，mean 几乎正常——典型"均值盲"场景 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热/启动准备 | 无特殊预热（功率限制即时生效） | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步（step 150–350） | |
| 特殊时序 | **间歇模式**: on 50 步 → off 50 步 → on 50 步 → off 50 步 | step 150-200 on, 200-250 off, 250-300 on, 300-350 off |
| 注意事项 | 1) 脚本退出时必须恢复默认功率上限；2) 步数到时间的映射需校准；3) 沐曦平台需确认等效接口 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-HW-C"
target_rank: 7
target_host: "worker-82"
target_gpu: 7
t_on_step: 150
t_off_step: 350
pattern: "intermittent"
on_windows:
  - [150, 200]
  - [250, 300]
off_windows:
  - [200, 250]
  - [300, 350]
intensity: "power_cap=50%_of_default"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-23T14:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
间歇性功耗墙的特征：被限 rank 的 step_time **均值可能正常**（off 窗口正常拉低平均），但 **p99/max 异常高**，且呈现**周期性尖峰**。因此：
- L0: 不能只看 mean——必须看 p99/max 与 median 的比值（p99/p50 gap）；若 p99/median ≥ 2.0 → 间歇性异常
- L2: 按 rank 分组看 p99，找周期性尖峰最突出的 rank
- L3: 查该 rank 的 GPU 功率/throttle 数据——如果功率周期性跌落且 throttle_reason 包含 power cap 标志 → 功耗墙触发
- L4: 确认 P1-HW（芯片×硬件退化类——功率管理单元的限制动作）

**关键信号**：`gpu.utilization` 表中的 `power_draw` 周期性低谷 + `throttle_reasons` 含 `SwPowerCap` / `HwPowerBrakeSlowdown`。

**注意**：`gpu.utilization` 表是时间采样（无 step 列），需通过时间窗口 JOIN `python.torch_trace` 来关联 step。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 看尾部而非均值
SELECT rank,
       avg(duration_ms) as avg_ms,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms) as p50_ms,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_ms,
       max(duration_ms) as max_ms,
       p99_ms / p50_ms as tail_ratio
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY tail_ratio DESC;
-- 判据: tail_ratio (p99/p50) ≥ 2.0 → 间歇性异常（mean 可能正常！）
-- 对比: avg_ms 可能只有 +5%~15% (Masked/Quiet)，但 tail_ratio 暴露问题

-- Step 2: 定位 —— 哪个 rank 有周期性尖峰
SELECT rank, step, duration_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
  AND rank = <suspect_rank>
ORDER BY step;
-- 判据: 可视化后看到 on-window (150-200, 250-300) 明显高于 off-window (200-250, 300-350)
-- 量化: avg(on_windows) / avg(off_windows) ≥ 1.5 → 周期性模式确认

-- Step 3: 归因 —— 查 GPU 功率和 throttle（时间窗口 JOIN）
WITH step_time_bounds AS (
  SELECT rank, step, start_ts, end_ts
  FROM python.torch_trace
  WHERE step BETWEEN 150 AND 350
    AND phase = 'step'
    AND rank = <suspect_rank>
)
SELECT s.step,
       avg(g.power_draw_w) as avg_power,
       max(g.throttle_reasons) as throttle
FROM gpu.utilization g
JOIN step_time_bounds s
  ON g.rank = s.rank
  AND g.timestamp BETWEEN s.start_ts AND s.end_ts
GROUP BY s.step
ORDER BY s.step;
-- 判据: on-window 的 power_draw 显著低于 off-window
--        且 throttle_reasons 含 'SwPowerCap' / 'HwPowerBrakeSlowdown'

-- Step 4: 确认 —— 周期性模式（排除随机抖动）
-- 计算 on-window vs off-window 的功率差异
SELECT
  CASE WHEN step BETWEEN 150 AND 200 OR step BETWEEN 250 AND 300
       THEN 'on_window' ELSE 'off_window' END as window_type,
  avg(duration_ms) as avg_ms,
  count(*) as n_steps
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
  AND rank = <suspect_rank>
GROUP BY window_type;
-- 判据: on_window avg / off_window avg ≥ 1.2 → 周期性功耗墙确认
-- → P1-HW（芯片硬件层的功率管理动作）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| tail_ratio (p99/p50) | ≥2.0 | 触发间歇性异常分诊（mean 可能正常） |
| on_window_avg / off_window_avg | ≥1.2 | 确认周期性模式（非随机抖动） |
| power_draw on-window vs off-window | 差值 >30W 或 >15% | GPU 功率周期性跌落 |
| throttle_reasons 含 power cap | True | 确认是功率限制触发而非其他原因 |
| 周期性匹配注入模式 | on/off 每 ~50 步交替 | 排除随机抖动，确认外部周期性干预 |

### 2.4 预期定位路径

```
L0(tail_ratio=3.5, p99 异常但 mean 仅 +15%) → L2(rank 7, on/off 周期性)
→ L3(power_draw 周期性跌落, throttle=SwPowerCap) → L4(P1-HW: 芯片×硬件退化/功率管理)
```

### 2.5 预期 D-level
**D4**（定位到 P1-HW 坐标 + 识别功率限制间歇模式）。若能进一步确认功率限制的具体值和触发周期则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast) + 滑动窗口均值；慢组 ≥1.2×中位数 |
| 预期能到 D 几 | **D1-D2**：滑动窗口均值对间歇模式敏感度低（Masked 档均值仅 +5%，可能不触发阈值）；Loud 档均值 +40% 可触发变点,但无法识别周期性模式或功率原因 |
| 结构性瓶颈 | 1) 基于均值/变点，对间歇性模式天然弱（均值正常 → 漏检）；2) 无 GPU 功率/throttle 信息，无法定位 power cap；3) 即使检出异常也只能报"计算慢"，D2 封顶 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 → straggler |
| 预期能到 D 几 | **D1**：均值比值对间歇模式不敏感；Masked 档 mean 仅 +5% 可能与噪声无法区分；无周期性分析能力 |
| 结构性瓶颈 | 1) 只有均值比指标，无 p99/尾部分析；2) 无时序分析（周期性模式在均值中被平滑）；3) 无 GPU telemetry |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常） |
| 预期能到 D 几 | **D1**：可能捕捉到 step 异常信号，但无自动 RCA，无周期性分析，无功率数据 |
| 结构性瓶颈 | 有信号无诊断；缺乏周期性分析和硬件 telemetry 关联能力 |

---

## 4. 执行检查清单

- [ ] 确认目标节点有 admin 权限（可执行 `nvidia-smi -pl`）
- [ ] 确认目标 GPU 默认功率上限值（`nvidia-smi -q -d POWER`）
- [ ] 注入脚本 on/off 窗口切换逻辑测试通过（Loud 档确认 on-window step_time +150%）
- [ ] 脚本退出时功率上限恢复逻辑验证（异常退出也能恢复）
- [ ] 步数到时间的映射校准完成（确保 on/off 窗口切换准确）
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档上验证过：tail_ratio 能区分 on/off 窗口
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
| step_time p99 (ms) | | | | p99 差异应远大于 mean 差异 |
| on-window mean (ms) | | | | 间歇窗口内的退化 |
| off-window mean (ms) | | | | 恢复窗口应接近 A 线 |
| target rank throttle_reasons | — | | | 确认 power cap 标志 |

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

- 核心验证点：检测系统是否被"均值正常"欺骗，能否通过尾部+周期性分析发现间歇性异常
- 

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
