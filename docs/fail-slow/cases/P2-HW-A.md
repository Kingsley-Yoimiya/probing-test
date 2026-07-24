# Case P2-HW-A：光模块误码率↑降速重协商

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（❌ 卡审批），但检测方案就绪，证明"检测就绪、注入阻塞"。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-HW-A |
| Case 名称 | 光模块误码率上升→降速重协商（optics BER → speed downgrade） |
| 27 格坐标 | 位置: P2 互联 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ❌ 网络组审批 + root（改限速需 root；需交换机侧端口计数真值） |

---

## 1. 注入方案

### 1.1 故障机制
光模块随温度或老化导致误码率（BER）上升，链路自动从高速档降速重协商（如 200G→100G），有效带宽腰斩但功能正确——集合通信仍完成、无错误日志，只是慢了。真实场景：长期运行集群中光模块老化、散热不良、连接器氧化。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 网络限速工具（tc/wondershaper）模拟带宽降级 |
| 启动方式 | 训练中途（非开始前）用定时任务在 step 150 触发限速 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-HW-A/` |
| 依赖 | root 权限 + 隔离测试网络/虚拟网卡对；禁止碰宿主物理管理口或共享生产网卡 |

**注入器核心逻辑**：训练中途对目标节点的 RDMA 网卡施加 tc 限速，模拟链路从 200Gbps 降到 100Gbps/50Gbps。只能在隔离环境操作。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 带宽限至原始 25%（如 200G→50G） | step_time +100%~300%（通信主导） |
| **Quiet** | 带宽限至原始 50%（如 200G→100G） | step_time +30%~80% |
| **Masked** | 带宽限至原始 75%（如 200G→150G） | step_time +5%~15%，接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热，限速即时生效 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续限速） | 真实场景中降速协商后不会自动恢复 |
| 注意事项 | 只能在隔离网络操作；需确认限速作用于 RDMA 数据面而非管理面 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-HW-A"
target_rank: 7
target_host: "worker-82"
target_nic: "mlx5_0"        # 被限速的网卡
original_bw_gbps: 200
limited_bw_gbps: 50
t_on_step: 150
t_off_step: 350
intensity: "tc_rate_limit=50Gbps"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
光模块降速的特征：**通信阶段变慢**（有效带宽下降），**计算阶段不受影响**。涉及该链路的所有集合通信都会变慢，且受害方向有方向性（与拓扑相关）。

核心检测路径：
- L0: step_time 离群 → 有 straggler
- L2: 按 rank 分解，找通信阶段最慢的 rank(s)
- L3: 看 `nccl.proxy_ops` 的 `recv_wait_ns` 高（网络 victim 模式）+ `nccl.coll_perf` 实测带宽下降
- L4: `rdma.mlx_hca` 端口错误/带宽计数 + 方向对称性偏离 → 确认 P2-HW

**关键信号**：
- `recv_wait_ns` 高 = 网络 victim（等对端数据到达）
- `send_gpu_wait_ns` 正常 = 排除计算 culprit
- `nccl.coll_perf` 实测带宽 vs 拓扑期望带宽的比值

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max(avg_ms) / median(avg_ms) ≥ 1.3 → 通信层有 straggler

-- Step 2: 定位 —— 哪条链路慢（recv_wait 指向 victim）
SELECT rank,
       avg(recv_wait_ns) / 1e6 as recv_wait_ms,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
GROUP BY rank
ORDER BY recv_wait_ms DESC;
-- 判据: recv_wait 高 + send_gpu_wait 正常 → 网络 victim 模式
-- → 排除计算 culprit（若 send_gpu_wait 高则是计算慢）

-- Step 3: 归因 —— 实测带宽 vs 拓扑期望
SELECT rank, peer_rank,
       avg(algo_bw_gbps) as measured_bw,
       avg(bus_bw_gbps) as bus_bw
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, peer_rank;
-- 判据: measured_bw / expected_bw < 0.6 → 带宽显著退化
-- 方向性: 特定 rank-pair 退化而非全局

-- Step 4: 确认硬件层 —— RDMA HCA 端口统计
SELECT rank, port,
       sum(rx_bytes_delta) as rx_bytes,
       sum(tx_bytes_delta) as tx_bytes,
       sum(symbol_error_delta) as sym_err,
       sum(link_downed_delta) as link_down
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, port;
-- 判据: symbol_error 上升 / link_downed 事件 → 硬件链路层问题
-- 结合 Step 3 的方向性 → P2(互联) × HW(硬件退化)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| comm straggler ratio | ≥1.3 | 通信层存在异常 |
| recv_wait_ns 偏离 | >2× 中位数 | 网络 victim 模式 |
| send_gpu_wait_ns | 正常范围 | 排除计算 culprit |
| measured_bw / expected_bw | <0.6 | 带宽显著退化 |
| symbol_error / link_downed | >0 | 硬件链路层证据 |

### 2.4 预期定位路径

```
L0(comm straggler ratio=2.5) → L2(rank 7, recv_wait highest)
→ L3(algo_bw=50Gbps vs expected 200Gbps, sym_err↑) → L4(P2-HW: 互联×硬件退化)
```

### 2.5 预期 D-level
**D4**（定位到 P2-HW 坐标 + 具体链路）。Probing 有 `rdma.mlx_hca` 端口级统计，能区分硬件退化 vs 软件配置。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503，hook NCCL 集合通信 |
| 该 case 能用的判据 | 变点检测(Rbeast) 发现通信变慢 + 慢组 rank 集合 + 方向性判断 |
| 预期能到 D 几 | **D3**（能发现通信变慢、定位到 rank、判断是网络层问题） |
| 结构性瓶颈 | 无 `rdma.mlx_hca` 端口统计，无法区分"硬件降速"vs"软件配置错误"vs"拥塞"；到 D3(网络层)但不到 D4(具体硬件机理) |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | step timing 离群检测 + 通信阶段占比变化 |
| 预期能到 D 几 | **D2**（能发现谁慢，但无法判断是通信还是计算，更无法定位链路） |
| 结构性瓶颈 | 无通信内部分解信息（proxy_ops / coll_perf），无硬件端口统计 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信阶段 duration 异常 |
| 预期能到 D 几 | **D2**（知道通信变慢了，但无链路级定位） |
| 结构性瓶颈 | 有信号无诊断深度 |

---

## 4. 执行检查清单

- [ ] ❌ **审批状态**：需网络组审批 + root 权限（当前阻塞）
- [ ] 隔离测试网络环境确认（禁止在生产网络操作）
- [ ] tc 限速脚本测试（在隔离环境验证限速确实作用于 RDMA 数据面）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测方案已冻结（§2 填完）
- [ ] 对手方案已确认（§3 填完）
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / 注入 step 150 / PROBING=2 / rate=1.0

> **当前状态**：检测就绪、注入阻塞。待审批通过后可立即执行。

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
| target rank recv_wait | | | | |

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
