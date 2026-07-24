# Case P1-EXT-A：同卡算力抢占

> 基于模板 `TEMPLATE.md`。本 case 属第一梯队（纯软件零审批），是最先跑通的标准单位。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-EXT-A |
| Case 名称 | 同卡算力抢占（co-located GPU contention） |
| 27 格坐标 | 位置: P1 芯片 × 来源: EXT 外部争用 |
| 梯队 | 第一梯队 |
| 权限要求 | 普通用户（同 GPU 上起另一个进程即可） |

---

## 1. 注入方案

### 1.1 故障机制
同一张 GPU 上有另一个计算任务(如推理服务/其他训练)抢占 SM 资源,导致训练 kernel 的有效算力下降、step_time 上升。真实场景：多租户 GPU 共享、同节点有其他作业未隔离。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立 CUDA 进程（sidecar），持续占用目标 GPU 的 SM |
| 启动方式 | 外部调度在训练到 step 150 时通过 signal 触发启动 |
| 注入脚本路径 | `scripts/fail-slow/sidecar_inject.py --kind cube` |
| 编排入口 | `run_case_abc.sh` / `INJECT_KIND=cube` |
| 依赖 | 同节点能起另一个 CUDA 进程；沐曦用 `MACA_VISIBLE_DEVICES` 指定同卡 |

**注入器核心逻辑**：在目标 GPU 上跑死循环 matmul（`duty` 控制 busy 比例，`size` 为矩阵边长）。
- 预热：`SIDECAR_WARMUP=8`（沐曦时间片隔离；未预热约 +3%，预热后可达 +200%+）
- victim：`SIDECAR_LOCAL_RANK=7`（与训练 local_rank=7 同卡）

### 1.3 剂量三档（mohe-241 实测配方）

| 档位 | `INJECT_ARGS` | 预期 / 实测 C1/C0 | 说明 |
|---|---|---|---|
| **Loud** | `duty=0.9,size=8192` | 预期 +100%~200%；**实测 3.80×**（loud2） | 验收阈值 ≥1.8 |
| **Quiet** | `duty=0.3,size=4096` | 预期 +20%~50% | 验收阈值 ≥1.15 |
| **Masked** | `duty=0.15,size=4096` | 预期 +5%~10% | 近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | sidecar 启动后先跑 **8s** 再满载 | MetaX 时间片隔离 |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续干扰） | |
| 注意事项 | 必须确认 sidecar 和训练在**同一张 GPU** 上 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-EXT-A"
target_rank: 7           # 被抢占的 rank
target_host: "worker-82"
target_gpu: 7            # 该节点上的 GPU index
t_on_step: 150
t_off_step: 350
intensity: "sidecar_gpu_util=80%"
dose: "loud"
seed: 42
injector_commit: "abc1234"
injector_pid: 12345      # sidecar 的 PID（关键证据）
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
同卡抢占的特征：被抢 rank 的 **compute 阶段变慢**（GPU 算力被分走），但 **comm 阶段可能正常或被动变慢**（等慢 rank 同步）。因此：
- L0: 看 step_time 离群（有 straggler）
- L2: 按 rank 比 step_time，找最慢的
- L3: 看该 rank 的 GPU utilization——如果 util 高但 step 慢,且有**非训练 PID 占用**,指向外部抢占
- L4: 确认是 P1(芯片级) × EXT(外部进程)

**关键信号**：`gpu.utilization` 中的 `utilization_other`（非本进程的 GPU 占用）或 `process.gpu_users` 中的外部 PID。

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

-- Step 2: 定位 —— 看 GPU 占用分布
SELECT rank, 
       avg(gpu_utilization) as gpu_util,
       avg(gpu_utilization_other) as gpu_other
FROM gpu.utilization
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank;
-- 判据: gpu_other > 10% → 有外部占用

-- Step 3: 归因 —— 找外部 PID
SELECT pid, cmdline, avg(gpu_util_pct) as pct
FROM process.gpu_users
WHERE rank = <suspect_rank>
  AND pid != <training_pid>
  AND gpu_util_pct > 5
ORDER BY pct DESC;
-- 判据: 存在非训练 PID 且占用 >10% → 确认外部抢占

-- Step 4: 确认 —— culprit vs victim (排除网络)
SELECT rank,
       avg(send_gpu_wait_ns) as send_wait,
       avg(recv_wait_ns) as recv_wait
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>;
-- 如果 send_gpu_wait 高(计算慢导致发送晚) 而 recv_wait 低
-- → 该 rank 是 culprit(自己慢拖别人),不是 victim(被别人拖)
-- → 排除网络问题 → 确认 P1(芯片级)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio (max_avg/median_avg) | ≥1.5 | 触发 D1 |
| gpu_utilization_other | >10% | 指向外部争用 |
| 非训练 PID 存在且占用 >10% | True | 确认 EXT |
| send_gpu_wait 高 + recv_wait 低 | culprit 模式 | 排除网络,确认计算层 |

### 2.4 预期定位路径

```
L0(ratio=2.3, straggler) → L2(rank 7, avg_ms highest) 
→ L3(gpu_other=45%, PID 12345 占用 80%) → L4(P1-EXT: 芯片×外部争用)
```

### 2.5 预期 D-level
**D4**（定位到正确的 27 格坐标）。若实验中能停 PID 后看恢复则 D5。

**Loud2 实测（离线训练埋点，非 SQL）**：D3（victim=rank7）；见 `results/muxi-mohe/20260723_190341-failslow16-loud2/VERDICT_Loud.md`。

**SQL 环境（2026-07-23）**：Probing_plus `0.2.5`（`install_env_to_pods` / 统一镜像配方）。可用：`cpu.utilization`、`gpu.devices`、`python.torch_trace`（需 `PROBING_TORCH_PROFILING=on`）。`gpu.utilization` 采样未自动起表；`process.gpu_users` 主线无表 → D4 EXT 证据仍可能 `TABLE_MISSING` / `SQL_NO_EXT_EVIDENCE`。战役：`campaign_sql_d4.sh`。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast) + 慢组 ≥1.2×中位数 + 计算根因 >2× |
| 预期能到 D 几 | **D3**（能指出哪个 rank 慢、判断是计算类），但无 PID 信息,无法到 D4 |
| 结构性瓶颈 | Greyhound 无 `gpu_utilization_other`/`process.gpu_users` 类接口,不能区分"自己算慢"和"被外部抢" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线,喂 B run 的 step timing parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 → 指出 straggler |
| 预期能到 D 几 | **D2-D3**（能指出谁慢,但无根因信息） |
| 结构性瓶颈 | 无 GPU 进程级信息,无法到 D4 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 异常） |
| 预期能到 D 几 | **D1-D2**（能发现异常,但无自动 RCA） |
| 结构性瓶颈 | 有信号无诊断 |

---

## 4. 执行检查清单

- [ ] sidecar 脚本在目标 GPU 上测试过（Loud 档确认能让 step_time +100%）
- [ ] 预热逻辑已验证（5s 后占用率才真正上去）
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
| sidecar gpu_util 确认 | — | | | 注入器真的在占 |

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
| 2026-07-23 | 初始创建(模板范例) | Claude |
