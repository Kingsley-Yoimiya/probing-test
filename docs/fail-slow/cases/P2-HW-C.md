# Case P2-HW-C：交换机端口拥塞

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（❌ 卡审批），但检测方案就绪，证明"检测就绪、注入阻塞"。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-HW-C |
| Case 名称 | 交换机端口拥塞（switch port congestion / PFC storm） |
| 27 格坐标 | 位置: P2 互联 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ❌ 网络组审批 + root（流控涉及交换机配置） |

---

## 1. 注入方案

### 1.1 故障机制
某条链路排队延迟骤增、流控暂停风暴（PFC pause frame），造成阶段性通信带宽下降。半开链路、静默丢包——不是硬件 down，而是"功能正确但慢"。真实场景：多 job 共享交换机、hash 冲突、ECN 阈值不当、PFC 风暴。区别于 4A（持续带宽降级）和 6A（外部争用）——这里是交换机硬件层面的排队/流控问题。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 网络工具模拟排队延迟 + 流控效应（tc netem delay/loss） |
| 启动方式 | 训练中途 step 150 触发，对目标链路施加延迟+丢包 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-HW-C/` |
| 依赖 | root + 网络组审批；流控模拟需交换机配置权限 |

**注入器核心逻辑**：用 `tc netem` 对目标网卡注入排队延迟（模拟交换机拥塞）+ 少量随机丢包（模拟流控暂停），造成通信尖刺。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | delay 5ms + loss 1% + PFC pause 模拟 | step_time +100%~200%（通信尖刺严重） |
| **Quiet** | delay 1ms + loss 0.1% | step_time +20%~50% |
| **Masked** | delay 200us + loss 0.01% | step_time +5%~10%，间歇尖峰 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 可选：间歇模式（on 30步/off 20步）模拟真实 PFC 风暴 | PFC 风暴通常间歇性 |
| 注意事项 | 需确认 netem 作用于 RDMA 数据面；只在隔离环境操作 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-HW-C"
target_rank: 7
target_host: "worker-82"
target_port: "mlx5_0:1"
netem_delay_ms: 5
netem_loss_pct: 1.0
t_on_step: 150
t_off_step: 350
intensity: "netem_delay=5ms_loss=1%"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
交换机端口拥塞的特征：**通信延迟有尖刺**（排队延迟 + 流控暂停），且尖刺有**间歇性/突发性**——区别于 4A 的持续带宽降级。多 job 共享时更常见，易与计算 straggler 混淆。

核心检测路径：
- L0: step_time 有尖刺（可能均值不高但 p99 高）
- L2: 按 rank 分解，找通信阶段有尖刺的 rank
- L3: `nccl.proxy_ops` recv_wait_ns 有尖刺（间歇性高）+ `nccl.coll_perf` 带宽间歇下降 + `rdma.mlx_hca` 流控/暂停计数
- L4: 流控统计 + 尖刺的间歇性模式 → P2-HW（排队/流控是交换机硬件层行为）

**关键信号**：
- `recv_wait_ns` 的 p99/p50 gap 大（尖刺型，非持续型）
- `rdma.mlx_hca` 中 `rx_pause_frames` / `tx_pause_frames` 计数上升

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— step_time 尾部检测（均值可能正常但尾部异常）
SELECT rank,
       avg(duration_ms) as avg_ms,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_ms,
       percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) as p50_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: p99/p50 > 3 → 有间歇性通信尖刺（拥塞特征）

-- Step 2: 定位 —— recv_wait 尖刺模式
SELECT rank, step,
       recv_wait_ns / 1e6 as recv_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
ORDER BY recv_wait_ms DESC
LIMIT 20;
-- 判据: recv_wait 出现离散高值（>10× 中位数）
-- 间歇模式（非持续高）→ 区别于 4A 的恒定降速

-- Step 3: 归因 —— 流控/暂停帧统计
SELECT rank, port,
       sum(rx_pause_frames_delta) as rx_pause,
       sum(tx_pause_frames_delta) as tx_pause,
       sum(rx_discards_delta) as rx_discard
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, port;
-- 判据: pause_frames > 0 → 流控暂停（PFC）
-- rx_discards > 0 → 静默丢包
-- → 确认交换机/链路层拥塞

-- Step 4: 排除 —— 确认非计算 culprit
SELECT rank,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>;
-- send_gpu_wait 正常 → 排除计算 culprit → 确认网络层
-- 结合 Step 3 流控证据 → P2-HW（交换机硬件拥塞）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| comm p99/p50 | >3 | 间歇性尖刺（拥塞特征） |
| recv_wait 离散高值 | >10× 中位数 | 突发排队延迟 |
| rx_pause_frames | >0 | PFC 流控证据 |
| rx_discards | >0 | 静默丢包 |
| send_gpu_wait | 正常 | 排除计算 culprit |

### 2.4 预期定位路径

```
L0(p99/p50=5, 尖刺型) → L2(rank 7, recv_wait 间歇高)
→ L3(rx_pause=1200, rx_discard=3, 流控风暴) → L4(P2-HW: 交换机端口拥塞)
```

### 2.5 预期 D-level
**D4**（定位到 P2-HW 坐标 + 流控/端口级证据）。Probing 的 `rdma.mlx_hca` 能提供 PFC 暂停帧等端口级统计。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 通信尖刺 + 慢 rank |
| 预期能到 D 几 | **D2-D3**（能发现通信有尖刺、定位到 rank，但不能区分"拥塞"vs"降速"vs"邻居争用"） |
| 结构性瓶颈 | 无 PFC/流控统计，无法区分 4A/4C/6A 三种网络类故障；间歇性尖刺下变点检测灵敏度下降 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | step timing 尾部异常 |
| 预期能到 D 几 | **D1-D2**（间歇性尖刺在均值统计下信号弱） |
| 结构性瓶颈 | 间歇型对均值方法是盲区；无通信内部分解 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 尖刺 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无诊断深度、无流控视角 |

---

## 4. 执行检查清单

- [ ] ❌ **审批状态**：需网络组审批 + root（当前阻塞）
- [ ] 隔离测试网络环境确认
- [ ] tc netem 脚本测试（验证延迟+丢包对 RDMA 通信的影响）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测方案已冻结（§2 填完）
- [ ] 对手方案已确认（§3 填完）
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / 注入 step 150 / PROBING=2 / rate=1.0

> **当前状态**：检测就绪、注入阻塞。交换机端口拥塞模拟需网络组配合。

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
| step_time p99 (ms) | | | | |
| comm phase p99 (ms) | | | | |
| rx_pause_frames | | | | |

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
