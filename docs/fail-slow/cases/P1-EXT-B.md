# Case P1-EXT-B：同卡带宽争用

> 基于模板 `TEMPLATE.md`。本 case 属第一梯队（纯软件零审批），与 3A 共享编排但注入不同负载类型。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-EXT-B |
| Case 名称 | 同卡带宽争用（co-located memory bandwidth contention） |
| 27 格坐标 | 位置: P1 芯片 × 来源: EXT 外部争用 |
| 梯队 | 第一梯队 |
| 权限要求 | 普通用户（同 GPU 上起另一个进程即可，复用 3A 编排） |

---

## 1. 注入方案

### 1.1 故障机制
同一张 GPU 上有另一个进程持续执行高频小块显存拷贝（memcpy D2D / H2D），**仅占用显存带宽，不占用 SM 算力**。训练中的 memory-intensive 操作（大矩阵搬运、activation 读写、optimizer state 更新）被带宽饱和拖慢，而 compute-intensive 操作（matmul kernel）几乎不受影响。与 3A（compute contention）的关键区别：3A 使 compute op 变慢，3B 使 memory op 变慢——两者在 op 频谱上的退化模式截然不同。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立 CUDA 进程（sidecar），持续执行高频小块 memcpy 占用显存带宽 |
| 启动方式 | 外部调度在训练到 step 150 时通过 signal 触发启动 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-EXT-B/sidecar_membw_burn.py` |
| 依赖 | 同节点能起另一个 CUDA 进程；沐曦用 `MACA_VISIBLE_DEVICES` 指定同卡 |

**注入器核心逻辑**：在目标 GPU 上开多个 CUDA stream，每个 stream 死循环执行 `cudaMemcpyAsync`（小块 1~4 MB，D2D），通过并发 stream 数和块大小控制带宽占用比例。不使用任何 matmul/conv 等计算 kernel。
- 预热：先跑 5s 让带宽占用稳定
- 占用比例可调（通过并发 stream 数 × 块大小控制）

### 1.3 剂量三档（mohe-241 实测配方）

| 档位 | `INJECT_ARGS`（`sidecar_inject.py --kind hbm`） | 预期 / 实测 C1/C0 | 说明 |
|---|---|---|---|
| **Loud** | `duty=0.9,size=8192`（MB） | 预期 +60%~100%；**实测 2.84×**（loud2） | 验收 ≥1.6；OOM 可退 `size=4096,duty=1.0` |
| **Quiet** | `duty=0.4,size=4096` | 预期 +15%~30% | 验收 ≥1.15 |
| **Masked** | `duty=0.15,size=4096` | 预期 +5%~8% | 近噪声 |

编排：`INJECT_KIND=hbm`，`SIDECAR_WARMUP=8`，victim `local_rank=7`。

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | sidecar 启动后先跑 **8s** 再满载带宽占用 | MetaX 时间片隔离 |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步（step 150→350） | 与 3A 相同窗口 |
| 特殊时序 | 无（持续干扰） | |
| 注意事项 | 必须确认 sidecar 和训练在**同一张 GPU** 上；sidecar 只做 memcpy 不做 matmul |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-EXT-B"
target_rank: 7           # 被抢占的 rank
target_host: "worker-82"
target_gpu: 7            # 该节点上的 GPU index
t_on_step: 150
t_off_step: 350
intensity: "sidecar_membw_util=80%"
dose: "loud"
seed: 42
injector_commit: "abc1234"
injector_pid: 12346      # sidecar 的 PID（关键证据）
timestamp: "2026-07-23T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
同卡带宽争用的特征：被抢 rank 的 **memory-intensive op 变慢**（带宽被分走），但 **compute-intensive op（如 matmul）基本不变**。这与 3A（compute contention）正好相反——3A 是 compute op 慢、memory op 正常。因此：
- L0: 看 step_time 离群（有 straggler）
- L2: 按 rank 比 step_time，找最慢的
- L3: **op 频谱分解**——对慢 rank 做 op-level profiling，如果 memory-intensive op（如大块 memcpy、optimizer step、activation 搬运）退化而 compute op（matmul）不退化，指向带宽争用而非算力争用。同时查外部 PID。
- L4: 外部 PID 只做 memcpy → P1(芯片级) × EXT(外部争用，带宽子类型)

**关键信号**：`python.torch_trace` 中 memory-bound op 的 duration 退化 vs compute-bound op duration 不变——频谱差异是区分 3A/3B 的核心诊断依据。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, 
       avg(duration_ms) as avg_ms,
       max(duration_ms) as max_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max_rank_avg / median_all_avg ≥ 1.5 → 有 straggler

-- Step 2: 定位 —— op 频谱分解（区分 compute vs memory）
SELECT rank,
       op_type,
       CASE WHEN op_name IN ('aten::mm', 'aten::bmm', 'aten::addmm', 'aten::linear')
            THEN 'compute_bound'
            ELSE 'memory_bound' END as op_class,
       avg(duration_us) as avg_dur_us
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, op_class;
-- 判据: memory_bound op 退化 >30% 而 compute_bound op 退化 <5%
-- → 带宽争用（非算力争用）

-- Step 3: 归因 —— 找外部 PID
SELECT pid, cmdline, avg(gpu_util_pct) as pct
FROM process.gpu_users
WHERE rank = <suspect_rank>
  AND pid != <training_pid>
  AND gpu_util_pct > 5
ORDER BY pct DESC;
-- 判据: 存在非训练 PID → 确认外部进程
-- 进一步: 检查该 PID 的 kernel 是否全为 memcpy 类
-- → 确认是带宽型争用

-- Step 4: 确认 —— culprit 模式（排除网络）
SELECT rank,
       avg(send_gpu_wait_ns) as send_wait,
       avg(recv_wait_ns) as recv_wait
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>;
-- 如果 send_gpu_wait 高(memory op 慢导致数据就绪晚) 而 recv_wait 低
-- → 该 rank 是 culprit → 排除网络 → 确认 P1(芯片级)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio (max_avg/median_avg) | ≥1.5 | 触发 D1 |
| memory_bound op 退化率 | >30% | 指向带宽瓶颈 |
| compute_bound op 退化率 | <5% | 排除算力争用（区分 3A） |
| 非训练 PID 存在 | True | 确认 EXT |
| 外部 PID kernel 类型 | 全为 memcpy | 确认带宽子类型 |
| send_gpu_wait 高 + recv_wait 低 | culprit 模式 | 排除网络,确认芯片级 |

### 2.4 预期定位路径

```
L0(ratio=1.8, straggler) → L2(rank 7, avg_ms highest) 
→ L3(memory_bound op +65%, compute_bound op +2%; PID 12346 纯 memcpy) → L4(P1-EXT: 芯片×外部争用, 带宽子类型)
```

### 2.5 预期 D-level
**D4**（定位到正确的 27 格坐标，且能区分带宽/算力子类型）。若实验中能停 PID 后看恢复则 D5。

**SQL 环境（2026-07-23）**：同 P1-EXT-A——Probing_plus `0.2.5`；`process.gpu_users` 无表；`gpu.utilization` 采样未起。见 `scripts/fail-slow/image/` 与 SQL-D4 战役结果。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast) + 慢组 ≥1.2×中位数 + 计算根因 >2× |
| 预期能到 D 几 | **D3**（能指出哪个 rank 慢、判断是计算类根因），但无 op-level 频谱分解能力，不能区分"算力被抢"和"带宽被抢" |
| 结构性瓶颈 | Greyhound 无 op-class 分解接口，无法做 compute vs memory op 退化对比；无 PID 信息 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 → 指出 straggler |
| 预期能到 D 几 | **D2**（能指出谁慢,但无根因区分） |
| 结构性瓶颈 | 无 GPU op-level 信息，无法区分带宽争用 vs 算力争用 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常） |
| 预期能到 D 几 | **D1-D2**（能发现异常,但无自动 RCA） |
| 结构性瓶颈 | 有信号无诊断,无 op 频谱分解 |

---

## 4. 执行检查清单

- [ ] sidecar memcpy 脚本在目标 GPU 上测试过（Loud 档确认带宽占 80%）
- [ ] 确认 sidecar 只做 memcpy 不做 matmul（用 nsight/profiler 验证 kernel 类型）
- [ ] 预热逻辑已验证（5s 后带宽占用率稳定）
- [ ] op 频谱分解验证：Loud 档下 memory op 退化 >50% 而 compute op <5%
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档上验证过能检出
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
| sidecar membw_util 确认 | — | | | 注入器真的在占带宽 |
| memory_bound op mean (us) | | | | 带宽类 op 退化 |
| compute_bound op mean (us) | | | | 计算类 op 不变 |

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
