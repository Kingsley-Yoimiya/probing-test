# Case P3-HW-B：主机 CPU 温度墙降频

> 基于模板 `TEMPLATE.md`。P3 主机硬件退化格，CPU 降频拖慢主机侧发射/预处理。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-HW-B |
| Case 名称 | 主机 CPU 温度墙降频（host CPU thermal throttling） |
| 27 格坐标 | 位置: P3 主机 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需 root（改 CPU 频率需 cpufreq/intel_pstate 权限） |

---

## 1. 注入方案

### 1.1 故障机制
主机散热问题导致 CPU 温度接近上限，内核 thermal governor 自动下调 CPU 频率。CPU 密集的主机侧操作（DataLoader 预处理、Python 解释器、tensor 序列化、pin_memory 拷贝）被拖慢，导致设备发射间隙增大、step_time 上升。真实场景：服务器风扇故障、机房局部过热、CPU 负载过高触发热保护。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | CPU 频率锁定工具（cpufreq-set / intel_pstate / 写 sysfs） |
| 启动方式 | 训练到 step 150 时，脚本调低目标主机 CPU 最大频率 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-HW-B/cpu_throttle.sh` |
| 依赖 | root 权限；`cpufrequtils` 或直接写 `/sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq` |

**注入器核心逻辑**：
1. 记录原始 CPU 频率（用于恢复）
2. Step 150 时将 scaling_max_freq 写为目标值（模拟温度墙降频）
3. Step 350 时恢复原始频率
4. 替代方案（无 root）：用 `stress-ng --cpu` 满载所有核心逼近真实温度墙

### 1.3 剂量三档

| 档位 | CPU 频率限制 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 限制到基频的 40%（如 3.6GHz→1.4GHz） | +60%~120% | DataLoader 极慢 |
| **Quiet** | 限制到基频的 70%（如 3.6GHz→2.5GHz） | +15%~35% | 可观测但不剧烈 |
| **Masked** | 限制到基频的 90%（如 3.6GHz→3.2GHz） | +3%~8% | 接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热，频率立即生效 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续降频） | 可选：渐进降频模拟真实温漂 |
| 注意事项 | 必须在实验结束后恢复频率；记录注入前后 /proc/cpuinfo 频率 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-HW-B"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "cpu_freq_cap=40%_base"
dose: "loud"
original_freq_mhz: 3600
capped_freq_mhz: 1400
seed: 42
injector_commit: "TBD"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
CPU 降频→主机侧 DataLoader/预处理变慢→设备空闲升高→step_time 上升。检测路径：
- L0: step_time straggler
- L2: 定位到具体 rank/host
- L3: 查该 host 的 CPU 频率 + 主机侧耗时分解
- L4: CPU 频率↓与主机侧 gap 强相关 → P3-HW（主机硬件降频）

**关键**：num_workers=2 确保 DataLoader 预处理是 CPU 密集且在关键路径上。CPU 降频直接放大预处理耗时。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max(avg_ms) / median(avg_ms) >= 1.3

-- Step 2: 定位 —— 主机侧 gap
SELECT rank, host,
       avg(host_gap_ms) as host_gap,
       avg(device_idle_pct) as idle_pct
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, host;
-- 判据: host_gap 明显高于基线 → 主机侧瓶颈

-- Step 3: 归因 —— CPU 频率
SELECT host,
       avg(cpu_freq_mhz) as freq,
       avg(cpu_utilization) as cpu_util,
       avg(cpu_temperature) as temp
FROM cpu.host_metrics
WHERE step BETWEEN 150 AND 350
  AND host = <suspect_host>;
-- 判据: cpu_freq 低于基线 + cpu_util 高（频率低但负载没降）→ 降频

-- Step 4: 确认降频→gap 相关
SELECT step,
       cpu_freq_mhz,
       host_gap_ms
FROM cpu.host_metrics JOIN python.torch_trace USING (step, host)
WHERE host = <suspect_host>
  AND step BETWEEN 100 AND 400;
-- 判据: step 150 前后 freq 变点与 host_gap 变点对齐
-- → 确认 P3-HW（主机 CPU 降频导致）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.3 | 触发 D1 |
| host_gap 增长 | >2x 基线 | 指向主机侧 |
| cpu_freq 下降 | <80% 基线频率 | 指向 CPU 降频 |
| freq 变点与 gap 变点对齐 | IoU ≥ 0.8 | 确认因果 |
| 温度升高（可选） | 接近 thermal_trip | 指向热原因 |

### 2.4 预期定位路径

```
L0(ratio=1.8, straggler) → L2(rank 7, host worker-82)
→ L3(cpu_freq 1400MHz vs 基线 3600MHz, host_gap +100%)
→ L4(P3-HW: 主机×CPU 降频/温度墙)
```

### 2.5 预期 D-level
**D4**（能定位到"主机 CPU 降频"这一 27 格坐标）。若同时有温度数据可关联则更强。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组；无主机 CPU 频率信号 |
| 预期能到 D 几 | **D2**（能找到 straggler，无法归因 CPU 降频） |
| 结构性瓶颈 | 只看通信时序，无主机 CPU/温度指标 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 步时间离群检测 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无主机指标 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 发射间隙 / host gap 异常 |
| 预期能到 D 几 | **D2-D3**（能看到主机侧 gap，但不采集 CPU 频率） |
| 结构性瓶颈 | 有信号无诊断；不知道为什么主机慢 |

---

## 4. 执行检查清单

- [ ] CPU 频率锁定脚本测试过（Loud 档确认频率被限到 40%）
- [ ] 确认有 root 或等效权限改 cpufreq
- [ ] 频率恢复逻辑确认（实验结束/异常退出都能恢复）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测 SQL 在 Loud 档验证
- [ ] DataLoader 配置：num_workers=2, worker_init_fn=seed_worker, persistent_workers=True
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / seed 42 / PROBING=2 / rate=1.0
- [ ] 节点列表确认，硬件健康

---

## 5. 实验结果（跑后填写）

### 5.1 Run 记录

| Run | Seed | 日期 | 剂量 | 状态 | Run ID |
|---|---|---|---|---|---|
| A (baseline) | 42 | | — | | |
| B (injection) | 42 | | loud | | |
| C (Probing) | 42 | | loud | | |
| D (XPUTimer) | 42 | | loud | | |

### 5.2 注入生效性验证

| 指标 | A 线 | B 线 | 差异 | 结论 |
|---|---|---|---|---|
| step_time mean (ms) | | | | |
| target rank step_time | | | | |
| cpu_freq (MHz) | | | | 降频生效 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |
| XPUTimer | | | | | |

### 5.4 开销影响

| 指标 | A 线 | C 线(Probing) | 开销% | D 线(XPUTimer) | 开销% |
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
