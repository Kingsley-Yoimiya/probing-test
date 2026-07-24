# Case P2-EXT-A：邻居持续网络压力

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（◐ 需第二 job + 隔离/共享网络环境）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-EXT-A |
| Case 名称 | 邻居持续网络压力（neighbor sustained network pressure） |
| 27 格坐标 | 位置: P2 互联 × 来源: EXT 外部争用 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需第二个 job 配额 + 隔离/共享网络环境 |

---

## 1. 注入方案

### 1.1 故障机制
同交换机的另一租户/作业持续进行大规模 AllReduce 或数据传输，持续抢占共享网络带宽。本 job 的集合通信阶段性变慢，但单独看本 job 的硬件指标全绿——根因在"看不到"的邻居。真实场景：多租户共享 IB 交换机、fat-tree 拥塞、对端大作业启动。区别于 4C（交换机硬件问题）——这里是正常的带宽争用。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 邻居 job 的网络压力 sidecar（持续大流量 AllReduce/ib_write_bw） |
| 启动方式 | 定时任务延迟到训练 step 150 后启动邻居网络压力 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-EXT-A/` |
| 依赖 | 第二个 job 配额 + 共享同一交换机/网络；不需 root |

**注入器核心逻辑**：在共享网络的邻居节点上启动持续的 `ib_write_bw` / `ib_send_bw` 或 NCCL allreduce_perf，打满共享链路带宽。训练 step 150 时通过定时器触发启动。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 邻居打满共享链路 90%（持续 ib_write_bw） | step_time +80%~150% |
| **Quiet** | 邻居占用共享链路 50% | step_time +20%~50% |
| **Masked** | 邻居占用共享链路 20% | step_time +5%~10% |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 邻居压力进程启动后 3s 达到稳态流量 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 持续压力（区别于 6B 的突发） | |
| 注意事项 | 需确认邻居流量与本 job 共享同一网络路径（同 leaf switch） | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-EXT-A"
target_rank: "all"           # 全局受影响（共享网络）
target_host: "all"
neighbor_job_id: "neighbor-stress-001"
neighbor_hosts: ["worker-90", "worker-91"]
shared_switch: "leaf-switch-12"
neighbor_traffic_gbps: 180   # 邻居流量
t_on_step: 150
t_off_step: 350
intensity: "neighbor_bw=180Gbps_sustained"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
邻居持续网络压力的特征：**本 job 通信变慢，但硬件全绿、无错误**。问题在于"争用"——本 job 的带宽被挤占。检测需要**跨 job 视角**或至少能看到共享链路的总流量。

核心检测路径：
- L0: step_time 变慢
- L2: 通信阶段变慢，recv_wait_ns 升高
- L3: `rdma.mlx_hca` 端口字节计数 + 无错误 + `nccl.coll_perf` 带宽下降但无算法/transport 变化
- L4: 硬件正常 + 软件配置不变 + 带宽下降 + 端口总流量超出本 job 份额 → P2-EXT（外部争用）

**关键信号**：
- `recv_wait_ns` 持续高（网络 victim）
- `rdma.mlx_hca` 端口 rx/tx_bytes 总量高于本 job 理论流量 → 有第三方流量
- 本 job 硬件无错误（排除 P2-HW）、软件配置不变（排除 P2-SW）

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 通信变慢
SELECT step,
       avg(duration_ms) as avg_comm_ms
FROM python.comm_collective
WHERE step BETWEEN 100 AND 350
GROUP BY step
ORDER BY step;
-- 判据: step 150 后 avg_comm_ms 持续升高

-- Step 2: 定位 —— recv_wait 确认网络 victim
SELECT rank,
       avg(recv_wait_ns) / 1e6 as recv_wait_ms,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: recv_wait 全局升高（不是单 rank）+ send_gpu_wait 正常
-- → 全局网络退化（非计算 culprit）

-- Step 3: 归因 —— 排除硬件和软件
SELECT rank, port,
       sum(symbol_error_delta) as sym_err,
       sum(link_downed_delta) as link_down,
       sum(rx_bytes_delta) / 1e9 as rx_gb,
       sum(tx_bytes_delta) / 1e9 as tx_gb
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
GROUP BY rank, port;
-- 判据: sym_err=0, link_down=0 → 硬件正常（排除 P2-HW）
-- rx_gb + tx_gb > 本 job 理论流量 → 有外部流量争用

-- Step 4: 确认外部争用 —— 算法/transport 不变
SELECT rank,
       any_value(algorithm) as algo,
       any_value(transport_type) as transport,
       avg(algo_bw_gbps) as bw
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: algorithm 和 transport 未变 → 排除 P2-SW
-- 硬件正常 + 软件不变 + 带宽下降 → P2-EXT(外部争用)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 通信变点后持续退化 | post/pre > 1.3 | 持续压力（非间歇） |
| recv_wait 全局升高 | 所有 rank >1.5× pre | 全局网络退化 |
| 硬件端口无错误 | sym_err=0 | 排除 P2-HW |
| 算法/transport 不变 | 与 pre 一致 | 排除 P2-SW |
| 端口总流量超出本 job | >1.3× 理论值 | 外部流量证据 |

### 2.4 预期定位路径

```
L0(comm 退化, step 150 变点) → L2(全局 recv_wait↑, send_wait 正常)
→ L3(硬件正常, 算法不变, 端口总流量超额) → L4(P2-EXT: 外部网络争用)
```

### 2.5 预期 D-level
**D3-D4**（定位到 P2-EXT 坐标；若能通过流量分析指出邻居 job 则 D4-D5）。跨 job 视角是 Probing 的结构性挑战——本 job 内只能看到间接证据。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 全局通信变慢 |
| 预期能到 D 几 | **D2-D3**（能发现通信变慢、判断是全局网络问题） |
| 结构性瓶颈 | 与 Probing 同样缺乏跨 job 视角；无法区分 P2-HW/P2-SW/P2-EXT（只知道"网络慢了"）；但 Greyhound 连"硬件正常"都不能确认 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 全局 step timing 变慢 |
| 预期能到 D 几 | **D1**（全局退化时 S 指标不触发——没有 straggler） |
| 结构性瓶颈 | 无 straggler 信号（全体等幅退化） |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 升高 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无诊断深度 |

---

## 4. 执行检查清单

- [ ] 确认有第二个 job 配额可用
- [ ] 确认邻居节点与本 job 共享同一 leaf switch
- [ ] 邻居压力脚本（ib_write_bw / allreduce_perf）测试通过
- [ ] 验证 Loud 档下本 job 通信确实退化 >50%
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
| comm phase mean (ms) | | | | |
| 邻居流量 (Gbps) | — | | | 邻居确实在打 |

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
