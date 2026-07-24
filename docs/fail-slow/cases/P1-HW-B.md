# Case P1-HW-B：显存带宽渐进衰减

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（普通用户可执行，起 memory sidecar 即可）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-HW-B |
| Case 名称 | 显存带宽渐进衰减（Memory Bandwidth Progressive Degradation） |
| 27 格坐标 | 位置: P1 芯片 × 来源: HW 硬件退化 |
| 梯队 | 第二梯队 |
| 权限要求 | 普通用户（同 GPU 上起 memory-bound sidecar 即可） |

---

## 1. 注入方案

### 1.1 故障机制
显存通道被持续 sidecar 占用，memory-intensive 阶段看到带宽下降；compute-intensive 阶段影响较小——这个频谱特征与 P1-HW-A（热降频）**相反**，可用于区分。真实场景：显存通道部分失效、ECC 修正密集占用带宽、显存芯片老化导致吞吐下降。

**与 P1-EXT-A（算力抢占）的关键区别**：
- P1-EXT-A: compute ops 变慢, memory ops 相对不变 → SM 抢占
- P1-HW-B: memory ops 变慢, compute ops 基本不变 → 带宽退化
- 频谱分析（memory-intensive vs compute-intensive op 分解）是二者的决定性判据

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | Memory-bound stream sidecar，持续执行大块显存拷贝占用带宽 |
| 启动方式 | 训练到 step 150 后触发启动，sidecar 强度线性递增至 step 350 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-HW-B/mem_bandwidth_sidecar.py` |
| 依赖 | 同节点同 GPU 能起另一个 CUDA 进程；沐曦用 `MACA_VISIBLE_DEVICES` 指定同卡 |

**注入器核心逻辑**：在目标 GPU 上跑 memory-bound stream（大块 `cudaMemcpy` D2D 或 memory-bandwidth kernel），通过调整并发 stream 数量和 buffer 大小控制带宽占用比例。
- 使用 `cudaMemcpyAsync` 或等效 memory-bound kernel（非 compute-bound）
- 强度渐进递增：step 150 起从低占用线性提升到目标占用
- 关键：占用的是**显存带宽**而非 SM 算力

### 1.3 剂量三档

| 档位 | sidecar 带宽占用 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 80% 显存带宽 | +60%~100% | memory-bound ops 受极大影响 |
| **Quiet** | 40% 显存带宽 | +15%~30% | 可检出，memory ops 明显变慢 |
| **Masked** | 20% 显存带宽 | +5%~10% | 接近噪声水平 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 注入触发时机 | step 150 | 训练已稳定 |
| 注入持续时长 | 200 步（150→350） | |
| 特殊时序 | PROGRESSIVE/LINEAR — sidecar 强度从 step 150 到 350 线性递增 | 模拟带宽渐进退化 |
| 强度变化率 | (target_bandwidth_pct) / 200 步 per step | Loud: 每步增 0.4% 带宽占用 |
| 注意事项 | 必须确认 sidecar 只占带宽不占 SM（用 memory kernel 非 compute kernel） |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-HW-B"
target_rank: 7           # 被带宽退化的 rank
target_host: "worker-82"
target_gpu: 7            # 该节点上的 GPU index
t_on_step: 150
t_off_step: 350
injection_type: "progressive_linear"
intensity: "mem_bandwidth_sidecar=80%"
dose: "loud"
bandwidth_start_pct: 0     # sidecar 起始占用
bandwidth_end_pct: 80      # sidecar 终点占用
seed: 42
injector_commit: ""
injector_pid: 12346      # sidecar 的 PID
timestamp: "2026-07-23T00:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
带宽退化的特征：被影响 rank 的 **memory-intensive ops 渐进变慢**（带宽被占），但 **compute-intensive ops 基本不变**（SM 未被占）。这个"频谱分离"是本 case 独有特征，也是与 P1-EXT-A 的决定性区分。

- L0: 看 step_time 离群（有 straggler），呈渐进上升趋势
- L2: 按 rank 比 step_time，找渐进变慢的 rank
- L3: 将该 rank 的 ops 分为 memory-intensive（如 embedding、layernorm、data loading）与 compute-intensive（如 matmul、attention）；若 memory ops 慢而 compute ops 不变 → 带宽问题。检查 `gpu.utilization` 中的带宽相关指标。
- L4: 外部 sidecar PID 在做 memory ops → P1-HW（硬件带宽退化代理via sidecar）

**关键信号**：op 级频谱分解——memory-intensive op duration 单调递增，compute-intensive op duration 稳定。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有渐进式 straggler
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
-- 判据: degradation_ratio 最高的 rank 为嫌疑;渐进递增模式

-- Step 2: 频谱分解 —— memory-intensive vs compute-intensive
-- 分类: matmul/gemm/attention → compute; embedding/layernorm/copy/memset → memory
WITH op_class AS (
  SELECT rank, step, duration_ms,
    CASE 
      WHEN op_name LIKE '%matmul%' OR op_name LIKE '%gemm%' OR op_name LIKE '%attention%'
        THEN 'compute'
      WHEN op_name LIKE '%embedding%' OR op_name LIKE '%layernorm%' 
        OR op_name LIKE '%copy%' OR op_name LIKE '%memset%' OR op_name LIKE '%memcpy%'
        THEN 'memory'
      ELSE 'other'
    END as op_type
  FROM python.torch_trace
  WHERE rank = <suspect_rank>
    AND step BETWEEN 100 AND 350
    AND phase = 'op'
)
SELECT op_type, 
       avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END) as baseline_ms,
       avg(CASE WHEN step BETWEEN 300 AND 350 THEN duration_ms END) as late_ms,
       (avg(CASE WHEN step BETWEEN 300 AND 350 THEN duration_ms END)
        - avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END))
       / avg(CASE WHEN step BETWEEN 100 AND 149 THEN duration_ms END) as degradation_ratio
FROM op_class
WHERE op_type IN ('compute', 'memory')
GROUP BY op_type;
-- 判据: memory 的 degradation_ratio >> compute 的 → 带宽退化
-- 预期: memory degradation ≥ 0.5, compute degradation ≤ 0.05

-- Step 3: 确认 —— GPU 带宽指标（时间窗口 JOIN）
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
-- 判据: clock_mhz 稳定(非热降频), temperature 无显著上升
-- → 排除 P1-HW-A(热降频)

-- Step 4: 归因 —— 确认通信层正常(排除网络)
SELECT rank,
       avg(send_gpu_wait_ns) as send_wait,
       avg(recv_wait_ns) as recv_wait
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>;
-- send_gpu_wait 渐进上升(内存慢导致数据准备慢) + recv_wait 低
-- → 该 rank 是 culprit → 排除网络
-- 加上频谱分解证据(memory ops慢/compute ops正常) → 确认带宽退化

-- Step 5: 找外部 PID（可选，辅助确认 sidecar）
SELECT pid, cmdline, avg(gpu_util_pct) as pct
FROM process.gpu_users
WHERE rank = <suspect_rank>
  AND pid != <training_pid>
  AND gpu_util_pct > 0
ORDER BY pct DESC;
-- 若存在 memory-bound 外部进程 → 进一步佐证
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| degradation_ratio (step_time) | ≥0.15 (Quiet 档) | 触发渐进 straggler 告警 |
| memory_ops degradation / compute_ops degradation | ≥5.0 | 频谱分离：memory 慢而 compute 不慢 |
| memory_ops degradation_ratio | ≥0.3 (Quiet 档) | memory ops 确有退化 |
| compute_ops degradation_ratio | ≤0.05 | compute ops 未退化（排除热降频/算力抢占） |
| clock_mhz 稳定 | 变化 <5% | 排除 P1-HW-A 热降频 |
| 单调递增 (memory op duration vs step) | Spearman ρ ≥ 0.8 | 确认渐进而非阶跃 |

### 2.4 预期定位路径

```
L0(ratio=1.8, straggler, monotonic increase) → L2(rank 7, degradation_ratio highest)
→ L3(memory ops: +85%, compute ops: +3%, spectral_ratio=28) → L4(P1-HW: 芯片×硬件退化/带宽)
```

### 2.5 预期 D-level
**D4**（定位到正确的 27 格坐标：频谱分离是 memory bandwidth 退化的独有特征，且排除了热降频/外部算力抢占）。若能停 sidecar 后看带宽恢复 + memory ops 恢复则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast) + 慢组 ≥1.2×中位数 + compute vs comm 粗分 |
| 预期能到 D 几 | **D3**（能检出 straggler 并定位到 rank,可能判断是计算类），但无 op 级频谱分解能力，无法区分"memory ops 慢"与"compute ops 慢" |
| 结构性瓶颈 | Greyhound 只看 compute/comm 粗粒度，不做 op-level 分解；无法证明"只有 memory-intensive ops 变慢" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 → 指出 straggler |
| 预期能到 D 几 | **D2**（能指出谁慢,但无根因信息） |
| 结构性瓶颈 | 无 op-level 信息，无法做频谱分解，无法到 D3+ |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常,渐进趋势） |
| 预期能到 D 几 | **D1-D2**（能发现异常,但无自动 RCA） |
| 结构性瓶颈 | 有信号无诊断；无 op-level 分解能力 |

---

## 4. 执行检查清单

- [ ] memory sidecar 脚本测试（Loud 档确认占 80% 带宽, step_time +60%）
- [ ] 确认 sidecar 是 memory-bound（非 compute-bound）：验证 SM 占用 <5%
- [ ] 渐进递增逻辑验证（强度线性爬坡）
- [ ] 频谱分解 SQL 验证：compute ops 确实不受影响
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档上验证过能做频谱分离
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
| memory op mean (ms) | — | | | memory ops 确认变慢 |
| compute op mean (ms) | — | | | compute ops 确认不变 |
| spectral ratio (mem/compute degradation) | — | | | 频谱分离确认 |

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
