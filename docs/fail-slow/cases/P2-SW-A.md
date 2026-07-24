# Case P2-SW-A：健康检查触发低速回退

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（◐ 需通信库插件开发能力）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-SW-A |
| Case 名称 | 健康检查触发低速回退（health check → slow fallback transport） |
| 27 格坐标 | 位置: P2 互联 × 来源: SW 软件缺陷 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需通信库插件开发能力（不需 root，但要能 hook 通信库） |

---

## 1. 注入方案

### 1.1 故障机制
通信库训练中途因一次瞬时错误触发健康检查，静默切换到低速备用路径（如某 RDMA 适配器故障后透明改路到 TCP fallback 或另一个低速适配器），有效带宽腰斩但功能正确——无 error、无 crash，只是慢了。真实场景：RDMA CM 瞬断、适配器固件 reset、NCCL NET plugin 自动 failover。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 通信库插件/环境变量强制切换 transport |
| 启动方式 | 训练到 step 150 时通过信号触发 transport 切换（或预埋 hook） |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-SW-A/` |
| 依赖 | 能 hook NCCL/通信库（LD_PRELOAD 或修改 NET plugin）；若 RDMA 直通则标记"平台不支持" |

**注入器核心逻辑**：在指定 step 后强制 NCCL 切换 transport（如从 RDMA 切到 Socket，或从高速适配器切到低速适配器），模拟健康检查触发的 fallback。可通过环境变量 `NCCL_NET_DISABLE` 或自定义 NET plugin 实现。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | RDMA→Socket fallback（带宽降 90%） | step_time +200%~500% |
| **Quiet** | 高速适配器→低速适配器（带宽降 50%） | step_time +30%~80% |
| **Masked** | 部分 channel 切换（1/4 channel 走慢路径） | step_time +5%~15% |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 需确认 transport 切换后新连接建立完成 | 切换有短暂建连开销 |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | 切换后不会自动恢复（模拟真实 fallback） |
| 特殊时序 | 切换发生在 step 150 的通信间隙 | |
| 注意事项 | 需验证 fallback 后集合通信仍能正确完成（不 hang） | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-SW-A"
target_rank: 7
target_host: "worker-82"
original_transport: "RDMA/IB"
fallback_transport: "Socket/TCP"
trigger_event: "forced_health_check_fail"
t_on_step: 150
t_off_step: 350
intensity: "transport_fallback=socket"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
健康检查触发 fallback 的特征：**step N 后通信持续变慢**（一次性切换，不恢复），且有 transport 切换事件。区别于硬件降速（4A）：这里是**软件层**的路径选择变化。

核心检测路径：
- L0: step_time 在某步后持续升高（变点）
- L2: recv_wait_ns 在变点后持续高（非间歇）
- L3: `nccl.coll_perf` 带宽在变点后恒定低于期望 + transport 日志出现切换事件
- L4: transport 切换事件与带宽下降对齐 → P2-SW（软件层路径选择）

**关键信号**：
- 变点后 `recv_wait_ns` 持续高（非间歇型）= 持续网络退化
- `nccl.coll_perf` 中 transport 类型字段变化
- 通信库日志中 health check / fallback 事件

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 变点检测（step N 后持续变慢）
SELECT step,
       avg(duration_ms) as avg_comm_ms
FROM python.comm_collective
WHERE step BETWEEN 100 AND 350
GROUP BY step
ORDER BY step;
-- 判据: step 150 后 avg_comm_ms 阶跃上升且不恢复 → 变点

-- Step 2: 定位 —— 哪些 rank 的通信持续退化
SELECT rank,
       avg(CASE WHEN step < 150 THEN duration_ms END) as pre_avg,
       avg(CASE WHEN step >= 150 THEN duration_ms END) as post_avg,
       avg(CASE WHEN step >= 150 THEN recv_wait_ns END) / 1e6 as post_recv_wait_ms
FROM nccl.proxy_ops
GROUP BY rank
HAVING post_avg / pre_avg > 1.5;
-- 判据: 持续退化（非间歇）→ 区别于拥塞(4C)

-- Step 3: 归因 —— 实测带宽下降 + transport 信息
SELECT rank,
       avg(algo_bw_gbps) as measured_bw,
       any_value(transport_type) as transport
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank;
-- 判据: measured_bw 显著低于期望 + transport 从 RDMA 变为 Socket
-- → 确认是 transport 切换导致

-- Step 4: 确认 —— 排除硬件层（端口无异常）
SELECT rank, port,
       sum(symbol_error_delta) as sym_err,
       sum(link_downed_delta) as link_down
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, port;
-- 判据: 硬件计数正常（无 sym_err/link_down）→ 排除 P2-HW
-- 带宽降 + 硬件正常 + transport 切换 → P2-SW 确认
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 变点后通信 avg 上升 | post/pre > 1.5 | 持续退化（非间歇） |
| recv_wait_ns 持续高 | >2× pre 基线 | 网络层持续退化 |
| transport 类型变化 | RDMA→Socket | 软件层切换证据 |
| 硬件端口统计正常 | sym_err=0, link_down=0 | 排除 P2-HW |
| send_gpu_wait 正常 | 无变化 | 排除计算 culprit |

### 2.4 预期定位路径

```
L0(step 150 变点, comm 阶跃) → L2(rank 7, recv_wait 持续高)
→ L3(transport: RDMA→Socket, bw 降 90%, 硬件正常) → L4(P2-SW: 软件 fallback)
```

### 2.5 预期 D-level
**D4**（定位到 P2-SW + transport 切换事件）。Probing 能通过 transport 日志 + 硬件正常的组合判断是软件层问题。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测(Rbeast) 发现通信阶跃 + 慢 rank + 通信根因 |
| 预期能到 D 几 | **D3**（能发现变点、定位 rank、判断是通信层问题） |
| 结构性瓶颈 | 无 transport 类型信息；不能区分"硬件降速(4A)"和"软件 fallback(5A)"——两者在 Greyhound 视角表现一样（通信变慢） |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | step timing 变点 |
| 预期能到 D 几 | **D2**（能发现变点，但无法归因到通信/transport 层） |
| 结构性瓶颈 | 无通信内部分解 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 变点 |
| 预期能到 D 几 | **D2** |
| 结构性瓶颈 | 无 transport 信息 |

---

## 4. 执行检查清单

- [ ] 通信库 hook/插件开发完成（能在指定 step 触发 transport 切换）
- [ ] 验证 fallback 后训练不 hang（集合通信仍正确）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测方案已冻结（§2 填完）
- [ ] 对手方案已确认（§3 填完）
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / 注入 step 150 / PROBING=2 / rate=1.0

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
| comm phase mean (post-150) | | | | |
| transport type | | | | 应从 RDMA 切到 Socket |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |

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
