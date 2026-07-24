# Case P1-EXT-C：共享时间片抖动

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（需集群支持 GPU 分时共享配置）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-EXT-C |
| Case 名称 | 共享时间片抖动（shared time-slice jitter） |
| 27 格坐标 | 位置: P1 芯片 × 来源: EXT 外部争用 |
| 梯队 | 第二梯队 |
| 权限要求 | ◐ 需集群支持 GPU 分时共享调度配置（非 root，但依赖集群侧功能） |

---

## 1. 注入方案

### 1.1 故障机制
多个作业通过时间片分时共享同一张物理 GPU。邻居作业**间歇性**占用时间片，导致训练进程周期性得不到完整时间片——表现为 step_time 周期性尖刺（spike），但均值近基线。与 3A/3B 的持续干扰不同，3C 是**间歇性**的，类似功率限制抖动（1C）。关键诊断特征：p99/median 比值高，但 mean 基本正常；utilization 呈锯齿状。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立 CUDA 进程（sidecar），间歇性执行 GPU 密集计算（10 步忙 / 10 步闲循环） |
| 启动方式 | 外部调度在训练到 step 150 时通过 signal 触发启动 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-EXT-C/sidecar_timeslice_jitter.py` |
| 依赖 | 集群支持 GPU 分时共享（MPS/time-slicing mode）；沐曦用 `MACA_VISIBLE_DEVICES` 同卡 |

**注入器核心逻辑**：sidecar 进程在目标 GPU 上按周期模式运行——忙 10 步（与训练 step 同步）做密集 matmul，闲 10 步 sleep。通过忙时占用比例控制时间片竞争强度。
- 忙时：满载占用目标比例的时间片
- 闲时：完全释放（sleep），不产生任何 GPU 负载
- 周期：10 步忙 + 10 步闲，从 step 150 持续到 step 350

### 1.3 剂量三档

| 档位 | 忙时时间片占用 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 80% | 忙窗 +100%，总均值 +50% | 尖刺非常明显，但闲窗正常 |
| **Quiet** | 40% | 忙窗 +40%，总均值 +20% | 尖刺可见但需关注 tail |
| **Masked** | 15% | 忙窗 +15%，总均值 +7% | 仅 p99 微升,mean 几乎不动 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无（间歇模式直接开始） | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步（step 150→350） | |
| 特殊时序 | **间歇性**：10 步忙 + 10 步闲循环 | 与 3A/3B 持续干扰的关键区别 |
| 注意事项 | 需确认集群支持分时模式；sidecar 忙/闲切换需与训练 step 边界对齐以便分析 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-EXT-C"
target_rank: 7           # 被干扰的 rank
target_host: "worker-82"
target_gpu: 7            # 该节点上的 GPU index
t_on_step: 150
t_off_step: 350
intensity: "timeslice_busy_ratio=80%"
pattern: "periodic_10on_10off"
busy_steps: [150-159, 170-179, 190-199, 210-219, 230-239, 250-259, 270-279, 290-299, 310-319, 330-339]
idle_steps: [160-169, 180-189, 200-209, 220-229, 240-249, 260-269, 280-289, 300-309, 320-329, 340-349]
dose: "loud"
seed: 42
injector_commit: "abc1234"
injector_pid: 12347      # sidecar 的 PID
timestamp: "2026-07-23T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
时间片抖动的特征：step_time 呈**周期性尖刺**，mean 近基线但 p99/median 比值高。与 3A/3B 的区分：3A/3B 是持续退化（所有注入窗口内的 step 都慢），3C 只有一半 step 慢（忙窗慢、闲窗正常）。与 1C（功率限制间歇）的区分：3C 有外部 PID，1C 没有。因此：
- L0: 看 **p99/median**（不是 mean!）——间歇尖刺使 tail 膨胀但 mean 不动
- L2: 按 rank 比 p99/median ratio，找最大的
- L3: 检查 step_time 尖刺的**周期性**（FFT 或自相关）；检查 GPU utilization 是否锯齿状；查外部 PID 活动模式是否与尖刺时间窗吻合
- L4: 外部 PID + 周期性活动模式 → P1-EXT（芯片×外部争用，时间片子类型）

**关键信号**：`python.torch_trace` 中 step_time 的周期性模式 + `gpu.utilization` 锯齿形态 + 外部 PID 活动窗口与尖刺的时间相关性。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 尾部膨胀检测（用 p99/median 而非 mean）
SELECT rank, 
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_ms,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) as median_ms,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) /
         percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) as tail_ratio
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY tail_ratio DESC;
-- 判据: tail_ratio ≥ 1.5 → 有间歇性异常（mean-based 方法会漏掉）

-- Step 2: 定位 —— 周期性检测
SELECT rank, step, duration_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
  AND rank = <suspect_rank>
ORDER BY step;
-- 后处理: 对 duration_ms 做自相关 / FFT
-- 判据: 周期 ~20 步（10 忙 + 10 闲）有显著峰 → 确认间歇性模式

-- Step 3: 归因 —— GPU utilization 锯齿 + 外部 PID
-- 注: gpu.utilization 无 step 列，需通过时间窗口 JOIN
SELECT g.rank,
       g.timestamp,
       g.gpu_utilization
FROM gpu.utilization g
INNER JOIN (
  SELECT rank, step, start_time, end_time
  FROM python.torch_trace
  WHERE phase = 'step' AND rank = <suspect_rank>
    AND step BETWEEN 150 AND 350
) t ON g.rank = t.rank
  AND g.timestamp BETWEEN t.start_time AND t.end_time
ORDER BY g.timestamp;
-- 判据: utilization 呈锯齿（忙窗高、闲窗正常）→ 时间片竞争

-- 归因续: 外部 PID 活动模式
SELECT pid, cmdline, timestamp, gpu_util_pct
FROM process.gpu_users
WHERE rank = <suspect_rank>
  AND pid != <training_pid>
ORDER BY timestamp;
-- 判据: 外部 PID 活动窗口与 step_time 尖刺窗口时间相关
-- → 确认外部进程的间歇性活动导致

-- Step 4: 确认 —— 排除网络，确认芯片级
SELECT rank,
       step,
       send_gpu_wait_ns,
       recv_wait_ns
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
ORDER BY step;
-- 忙窗 step: send_gpu_wait 高(计算被抢导致发送晚) + recv_wait 低
-- 闲窗 step: send_gpu_wait 正常 + recv_wait 正常
-- → 与时间片模式吻合 → 确认 P1(芯片级) 非网络
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| tail ratio (p99/median) | ≥1.5 | 触发 D1（mean-based 可能漏掉） |
| 周期性（自相关周期 ~20 步） | 显著峰 | 区分随机抖动 vs 周期性干扰 |
| GPU utilization 锯齿 | 忙闲窗差 >30% | 时间片竞争特征 |
| 外部 PID 活动与尖刺时间相关 | 相关系数 >0.7 | 确认 EXT |
| 忙窗 send_gpu_wait 高 / 闲窗正常 | 与周期吻合 | 排除网络,确认芯片级 |

### 2.4 预期定位路径

```
L0(tail_ratio=2.1, p99/median) → L2(rank 7, tail_ratio highest) 
→ L3(周期=20步, utilization锯齿, PID 12347 间歇活动) → L4(P1-EXT: 芯片×外部争用, 时间片子类型)
```

### 2.5 预期 D-level
**D4**（定位到正确的 27 格坐标，且能识别间歇性时间片模式）。若实验中能停 PID 后看恢复则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 滑动窗口均值 + 变点检测(Rbeast) |
| 预期能到 D 几 | **D1-D2**（滑动窗口均值会被间歇模式"稀释"；若尖刺够大可触发 D1,但周期性归因不可能） |
| 结构性瓶颈 | Greyhound 用均值做变点检测,间歇性模式下均值被拉低;无周期性分析能力;无 PID 信息 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 |
| 预期能到 D 几 | **D1**（mean-based 指标被间歇模式稀释,可能连 straggler 都检不出） |
| 结构性瓶颈 | 纯 mean-based,对间歇性尖刺天然不敏感 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常） |
| 预期能到 D 几 | **D1**（可能看到单步尖刺信号,但无周期性分析） |
| 结构性瓶颈 | 有信号无诊断,无间歇模式识别 |

---

## 4. 执行检查清单

- [ ] 集群确认支持 GPU 分时共享模式（MPS 或 time-slicing）
- [ ] sidecar 间歇脚本测试过（10 步忙 / 10 步闲周期验证）
- [ ] Loud 档下忙窗 step_time 确认 +100%，闲窗正常
- [ ] p99/median ratio 确认 ≥1.5（验证 tail 检测有效）
- [ ] mean 确认近基线（验证 mean-based 方法会漏掉）
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml（含 busy/idle step 列表）
- [ ] Probing SQL 周期性检测在 Loud 档上验证
- [ ] Greyhound LD_PRELOAD 在该环境能跑通
- [ ] 节点列表和 seed 确认
- [ ] 若集群不支持分时共享,记录 fallback 方案（降级为纯 sidecar 间歇模式）

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
| step_time mean (ms) | | | | 均值应接近（间歇性） |
| step_time p99 (ms) | | | | p99 应显著升高 |
| p99/median ratio | | | | 应 ≥1.5 |
| 忙窗 step_time mean | | | | 忙窗大幅升高 |
| 闲窗 step_time mean | | | | 闲窗应接近基线 |

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
