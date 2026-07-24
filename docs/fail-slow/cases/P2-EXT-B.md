# Case P2-EXT-B：邻居突发上传

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（◐ 需共享网络出口）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-EXT-B |
| Case 名称 | 邻居突发上传（neighbor burst upload / checkpoint storm） |
| 27 格坐标 | 位置: P2 互联 × 来源: EXT 外部争用 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需共享网络出口（能起一次大传输） |

---

## 1. 注入方案

### 1.1 故障机制
邻居 job 训练中途单次触发大文件传输（如 checkpoint 上传到远程存储），瞬间抢占共享网络出口——**突发一次性**，区别于 6A 的持续压力。几秒到几十秒后结束，通信恢复。真实场景：大模型 checkpoint 上传（几十 GB）、模型导出、日志批量上传。这是"稀疏事件"，类似 2C 的单样本挑战。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 大文件传输进程（scp/dd + 网络 pipe） |
| 启动方式 | 在训练 step 150 时触发一次大文件传输 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-EXT-B/` |
| 依赖 | 共享网络出口 + 远端接收节点；不需 root |

**注入器核心逻辑**：在 step 150 时从邻居节点向远端存储传输一个大文件（如 10GB），打满共享出口带宽。传输完成后网络恢复——整个事件只持续几秒到几十秒。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 传输 20GB，打满出口 10s+ | 受影响的 2-5 步 step_time +200%~500% |
| **Quiet** | 传输 5GB，持续 3-5s | 受影响的 1-2 步 step_time +50%~100% |
| **Masked** | 传输 1GB，持续 <2s | 单步 +10%~20%，接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 仅 2-15s（突发） | 与 6A 的 200 步持续不同 |
| 特殊时序 | **一次性突发**——传输完即结束 | 类似 2C 的稀疏事件 |
| 注意事项 | 需确认传输与训练通信共享同一网络路径 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-EXT-B"
target_rank: "all"
target_host: "all"
neighbor_host: "worker-90"
transfer_size_gb: 20
transfer_dest: "remote-storage:9000"
transfer_duration_sec: 12
t_on_step: 150
t_off_step: 153            # 只持续约 3 步
intensity: "burst_upload=20GB"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
突发上传的特征：**单次通信尖刺**（1-5 步），之后恢复。这是稀疏事件——均值方法可能稀释信号，需要尾部检测。

核心检测路径：
- L0: step_time 有单次尖刺（p99 高但均值接近正常）
- L2: recv_wait_ns 出现单次离散高值（尖刺步内）
- L3: `rdma.mlx_hca` 端口流量在尖刺窗口异常高 + 硬件无错误 + 算法不变
- L4: 单次尖刺 + 外部流量 + 硬件/软件正常 → P2-EXT（突发外部争用）

**关键信号**：
- 单步 `recv_wait_ns` 离散高（>10× 中位数），但前后步正常
- `rdma.mlx_hca` 端口 rx/tx_bytes 在尖刺步异常高

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 尾部检测（均值正常但有尖刺）
SELECT rank,
       avg(duration_ms) as avg_ms,
       max(duration_ms) as max_ms,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY duration_ms) as p99_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 200
GROUP BY rank;
-- 判据: max/avg > 5 → 有离散尖刺（而非持续退化）

-- Step 2: 定位 —— 找尖刺步
SELECT step,
       avg(duration_ms) as avg_ms,
       max(recv_wait_ns) / 1e6 as max_recv_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 148 AND 155
GROUP BY step
ORDER BY avg_ms DESC;
-- 判据: 某个 step 的 avg_ms 是其他步的 5× 以上
-- 且前后步正常 → 突发事件

-- Step 3: 归因 —— 尖刺步的端口流量
SELECT rank, port,
       sum(rx_bytes_delta) / 1e9 as rx_gb,
       sum(tx_bytes_delta) / 1e9 as tx_gb,
       sum(symbol_error_delta) as sym_err
FROM rdma.mlx_hca
WHERE step = <spike_step>
GROUP BY rank, port;
-- 判据: rx/tx_bytes 异常高（>2× 正常步）+ sym_err=0
-- → 有外部流量但无硬件错误

-- Step 4: 确认 —— 排除内部原因
SELECT step,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms,
       any_value(algorithm) as algo
FROM nccl.proxy_ops
WHERE step = <spike_step>
GROUP BY step;
-- send_gpu_wait 正常 → 非计算 culprit
-- algorithm 未变 → 非软件切换
-- 单次 + 外部流量 + 硬件/软件正常 → P2-EXT(突发)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 尖刺步 max/avg | >5 | 离散尖刺（非持续） |
| 尖刺持续步数 | <5 步 | 突发（区别于 6A 持续） |
| 尖刺步端口流量 | >2× 正常步 | 外部流量证据 |
| 硬件错误 | =0 | 排除 P2-HW |
| send_gpu_wait / algorithm | 正常/不变 | 排除计算/软件 |

### 2.4 预期定位路径

```
L0(step 150-152 尖刺, max/avg=8) → L2(全局 recv_wait 尖刺, 3 步内)
→ L3(端口流量 2.5×, 硬件正常, 算法不变) → L4(P2-EXT: 突发外部上传)
```

### 2.5 预期 D-level
**D3-D4**（能定位到 P2-EXT + 突发时间窗；因为是一次性事件，完整归因比持续场景难）。稀疏事件对统计方法是结构性挑战。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测——但突发事件可能不触发 Rbeast 变点（持续时间太短） |
| 预期能到 D 几 | **D1-D2**（短暂尖刺可能被滑窗稀释；若窗口恰好覆盖则 D2） |
| 结构性瓶颈 | Rbeast 变点检测对"一次性 2-3 步尖刺"不敏感（需要持续变化才能识别变点）；与 2C 类似的稀疏事件盲区 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 尖刺步的 timing 异常 |
| 预期能到 D 几 | **D0-D1**（均值方法完全稀释 2-3 步尖刺） |
| 结构性瓶颈 | 均值/中位数方法对稀疏事件结构性盲区 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 尖刺 |
| 预期能到 D 几 | **D1**（能看到尖刺但不知道为什么） |
| 结构性瓶颈 | 无根因信息 |

---

## 4. 执行检查清单

- [ ] 确认有共享网络出口可用
- [ ] 大文件传输脚本测试（验证能打满出口）
- [ ] 确认传输与训练通信共享路径
- [ ] 验证 Loud 档确实能造成 >3× 通信尖刺
- [ ] Ground-truth 记录器就绪（需记录精确传输时间窗）
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
| spike step_time (ms) | | | | |
| 非 spike step_time (ms) | | | | 应与 A 一致 |
| 传输实际持续 (s) | — | | | |

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
