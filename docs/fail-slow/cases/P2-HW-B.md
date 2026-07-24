# Case P2-HW-B：机内链路带宽漂移

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（❌ 卡审批），但检测方案就绪，证明"检测就绪、注入阻塞"。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-HW-B |
| Case 名称 | 机内链路带宽漂移（intra-node link bandwidth drift） |
| 27 格坐标 | 位置: P2 互联 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ❌ root + 硬件/固件接口（真实机内链路降级无法纯软件注入，只能代理） |

---

## 1. 注入方案

### 1.1 故障机制
机内高速互联连接器（如 NVLink/NVSwitch、PCIe）接触不良或老化，带宽随时间从满血漂移到约七成。区别于 4A 的跨机光模块降速——这是**机内**链路问题，影响张量并行（TP）组内的 P2P 通信。真实场景：连接器氧化、热膨胀松动、PCIe retrain。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 软件限速代理（cgroup 网络限速/tc 对虚拟设备） |
| 启动方式 | 训练中途 step 150 触发，对机内 P2P 路径施加限速 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-HW-B/` |
| 依赖 | root 权限 + 硬件/固件接口；软件只能用限速代理模拟 |

**注入器核心逻辑**：对目标节点内 GPU 间的 P2P 路径施加带宽限制。真实链路降级需固件接口（如 NVLink 降速），软件侧只能用限速代理近似模拟。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 机内 P2P 带宽限至 30%（如 600GB/s→180GB/s） | step_time +80%~150%（TP 通信主导） |
| **Quiet** | 机内 P2P 带宽限至 60%（如 600GB/s→360GB/s） | step_time +20%~50% |
| **Masked** | 机内 P2P 带宽限至 80%（如 600GB/s→480GB/s） | step_time +5%~10% |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 可选：渐进漂移（每 50 步降 10%）模拟真实老化 | |
| 注意事项 | 需确认限速作用于 GPU 间 P2P 路径而非 host 网络 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-HW-B"
target_rank: [4, 5, 6, 7]   # 同一机内 TP 组
target_host: "worker-82"
target_link: "nvlink_0-1"    # 被限速的机内链路
original_bw_gbps: 600
limited_bw_gbps: 180
t_on_step: 150
t_off_step: 350
intensity: "intra_node_bw_limit=30%"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
机内链路漂移的特征：**机内 P2P/AllGather 变慢**，但跨机通信正常。影响的是张量并行组内的通信，拓扑可能显示意外路径。

核心检测路径：
- L0: step_time 离群
- L2: 按 rank 分解，找通信阶段慢的——且慢 rank 集中在**同一台机器内**
- L3: `nccl.proxy_ops` 的 recv_wait_ns 高（网络 victim）+ `nccl.coll_perf` 中**机内通信**带宽低于期望
- L4: 机内 vs 机间带宽比值偏离拓扑期望 → 确认 P2-HW（机内硬件）

**关键信号**：
- 机内 P2P 带宽 vs 机间带宽的比值异常（正常应 >>1，降级后接近 1）
- `recv_wait_ns` 在 TP 组内通信时高

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 通信阶段有没有异常
SELECT rank, avg(duration_ms) as comm_avg_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
  AND collective_type IN ('all_gather', 'reduce_scatter')
GROUP BY rank
ORDER BY comm_avg_ms DESC;
-- 判据: 某些 rank 的通信显著慢于其他

-- Step 2: 定位 —— 机内 vs 机间分离
SELECT rank, peer_rank,
       CASE WHEN floor(rank/8) = floor(peer_rank/8) THEN 'intra' ELSE 'inter' END as locality,
       avg(algo_bw_gbps) as measured_bw
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
GROUP BY rank, peer_rank, locality;
-- 判据: intra 带宽显著低于期望 + inter 带宽正常
-- → 问题在机内链路

-- Step 3: 归因 —— proxy_ops 确认 victim 模式
SELECT rank,
       avg(recv_wait_ns) / 1e6 as recv_wait_ms,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank IN (<intra_group_ranks>)
GROUP BY rank;
-- recv_wait 高 + send_gpu_wait 正常 → 网络 victim（机内链路慢）

-- Step 4: 确认 —— 机内链路错误计数
SELECT rank, port,
       sum(symbol_error_delta) as sym_err,
       sum(link_error_recovery_delta) as recovery_cnt
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
  AND rank IN (<intra_group_ranks>)
GROUP BY rank, port;
-- 机内链路错误/恢复计数 → P2-HW 确认
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 机内通信 straggler | 同组内 max/median ≥1.3 | TP 组内通信异常 |
| intra_bw / expected_intra_bw | <0.7 | 机内带宽退化 |
| inter_bw 正常 | 在期望范围 | 排除跨机问题 |
| recv_wait_ns 偏离 | >2× 正常值 | 网络 victim |
| 机内链路错误计数 | >0 | 硬件退化证据 |

### 2.4 预期定位路径

```
L0(step straggler) → L2(rank 4-7 同机, comm 阶段慢)
→ L3(intra_bw=180GB/s vs expected 600GB/s, inter_bw 正常) → L4(P2-HW: 机内互联硬件漂移)
```

### 2.5 预期 D-level
**D4**（定位到 P2-HW 坐标 + 具体机内链路）。Probing 能区分机内 vs 机间通信带宽。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测(Rbeast) + 慢 rank 集中在同机 + 通信根因 |
| 预期能到 D 几 | **D3**（能发现通信变慢、能判断影响同一机器的 rank 组） |
| 结构性瓶颈 | 无机内/机间通信分离视角；无端口级统计；不能区分"机内链路降级"vs"机内拥塞"vs"TP 配置错误" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 同机 rank 群体变慢 |
| 预期能到 D 几 | **D2**（能发现谁慢，但无机内/机间分离能力） |
| 结构性瓶颈 | 无通信细粒度分解 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 异常 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无拓扑感知 |

---

## 4. 执行检查清单

- [ ] ❌ **审批状态**：需 root + 硬件/固件接口（当前阻塞）
- [ ] 确认软件代理能近似模拟机内带宽降级
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测方案已冻结（§2 填完）
- [ ] 对手方案已确认（§3 填完）
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / 注入 step 150 / PROBING=2 / rate=1.0

> **当前状态**：检测就绪、注入阻塞。真实机内链路降级无法纯软件注入。

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
| intra-node P2P bw (GB/s) | | | | |
| inter-node bw (GB/s) | | | | 应不变 |

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
