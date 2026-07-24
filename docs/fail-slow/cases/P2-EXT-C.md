# Case P2-EXT-C：共享存储带宽争用

> 基于模板 `TEMPLATE.md`。本 case 属第三梯队（◐ 需共享存储 + 邻居容器）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-EXT-C |
| Case 名称 | 共享存储带宽争用（shared storage bandwidth contention） |
| 27 格坐标 | 位置: P2 互联 × 来源: EXT 外部争用 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需共享存储 + 邻居容器（能对共享文件系统发起压力） |

---

## 1. 注入方案

### 1.1 故障机制
DataLoader 预读或 checkpoint 读写与其它作业争用共享存储（如并行文件系统 CephFS/Lustre、对象存储）带宽。间歇性拖慢数据路径——当存储延迟升高时，dataloader 取数变慢导致 GPU 空闲。跨了互联与存储边界——存储网络是共享网络的一部分。真实场景：多作业同时写 checkpoint、数据预取密集、存储节点负载不均。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 邻居容器/进程对共享存储的持续读写压力 |
| 启动方式 | 训练 step 150 时启动邻居的存储压力进程 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-EXT-C/` |
| 依赖 | 共享存储（AFS/CephFS/NFS）+ 邻居容器；不需 root |

**注入器核心逻辑**：邻居容器对共享文件系统持续发起大块顺序写 + 随机读（模拟 checkpoint 写入 + 数据预取争用），打满存储带宽/IOPS。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 邻居打满存储带宽 80%（fio: 4x sequential write 1GB + random read） | step_time +50%~100%（数据饥饿严重） |
| **Quiet** | 邻居占用存储带宽 40% | step_time +15%~30%（间歇饥饿） |
| **Masked** | 邻居占用存储带宽 15% | step_time +3%~8%（微弱信号） |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 存储压力启动后 2-3s 达到稳态 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 可选：间歇模式（模拟 checkpoint 周期性写入） | |
| 注意事项 | 需确认邻居写入与本 job 的 dataloader 共享同一存储路径 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-EXT-C"
target_rank: "all"
target_host: "all"
neighbor_host: "worker-90"
shared_storage: "/afs-a3-weight-share"
neighbor_io_pattern: "seq_write_1GB + random_read"
neighbor_bw_gbps: 8          # 存储带宽争用量
t_on_step: 150
t_off_step: 350
intensity: "storage_pressure=80%_bw"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
共享存储争用的特征：**dataloader 取数变慢 → GPU 空闲升高**。通信本身不直接受影响（与 6A 的纯网络争用不同），但 GPU 空闲/数据饥饿是间接信号。跨了存储与互联的边界——存储网络共用 RDMA 时，通信也可能受间接影响。

核心检测路径：
- L0: step_time 变慢
- L2: GPU 空闲比例升高（数据饥饿模式）+ 通信可能正常或轻微受影响
- L3: dataloader/H2D 边界变长 + 通信 recv_wait 可能轻微升高（存储网络共用时）
- L4: 数据路径慢 + 存储延迟相关 + 通信层面间接影响 → P2-EXT（存储争用跨互联边界）

**关键信号**：
- `send_gpu_wait_ns` 高（GPU 算完了在等数据/通信——但这里是因为数据饥饿导致 step 延长）
- GPU idle/bubble 比例升高
- 存储 IO 延迟指标（如有）

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— step_time 变慢 + 数据饥饿特征
SELECT rank,
       avg(duration_ms) as avg_step_ms,
       avg(gpu_idle_pct) as idle_pct,
       avg(dataloader_wait_ms) as dl_wait_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: idle_pct 升高 + dl_wait_ms 升高 → 数据饥饿

-- Step 2: 定位 —— 是数据路径还是通信路径
SELECT rank,
       avg(recv_wait_ns) / 1e6 as recv_wait_ms,
       avg(send_gpu_wait_ns) / 1e6 as send_wait_ms
FROM nccl.proxy_ops
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 如果 send_gpu_wait 高 + recv_wait 也略高
-- → 数据饥饿导致计算延迟→通信也延迟（间接影响）
-- 区别于纯网络争用(6A): 6A 是 recv_wait 高而 send_wait 正常

-- Step 3: 归因 —— 存储延迟关联
SELECT rank, step,
       avg(dataloader_read_latency_ms) as read_lat,
       avg(h2d_transfer_ms) as h2d_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, step
ORDER BY read_lat DESC;
-- 判据: dataloader_read_latency 显著升高 → 存储慢
-- 存储延迟升高 + GPU 空闲 → 数据饥饿型退化

-- Step 4: 确认 —— 排除硬件/软件问题
SELECT rank, port,
       sum(symbol_error_delta) as sym_err
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
GROUP BY rank, port
HAVING sym_err > 0;
-- 硬件正常 → 排除 P2-HW
-- 通信算法不变 → 排除 P2-SW
-- 数据路径慢 + 间接通信影响 → P2-EXT(存储争用)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| GPU idle_pct 升高 | >2× pre 基线 | 数据饥饿 |
| dataloader_wait 升高 | >2× pre 基线 | 取数慢 |
| recv_wait 轻微升高 | <3× pre（非主因） | 间接影响 |
| send_gpu_wait 升高 | >2× pre | GPU 等数据（数据饥饿导致） |
| 硬件无错误 | sym_err=0 | 排除 P2-HW |
| 存储读延迟升高 | >3× 正常 | 存储争用直接证据 |

### 2.4 预期定位路径

```
L0(step_time +60%, idle_pct↑) → L2(dl_wait↑, GPU 空闲, send_wait↑)
→ L3(storage_read_lat 5×, 硬件正常, 通信间接受影响) → L4(P2-EXT: 存储争用跨互联边界)
```

### 2.5 预期 D-level
**D3-D4**（能定位到 P2-EXT + 存储路径；跨存储边界的归因相对复杂）。若 Probing 有存储 IO 指标则更确定。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + step_time 变慢 |
| 预期能到 D 几 | **D1-D2**（能发现变慢，但 Greyhound hook 的是 NCCL 集合通信——存储争用主要影响数据路径而非通信层，Greyhound 的通信 hook 可能看不到主要信号） |
| 结构性瓶颈 | Greyhound 监控的是 NCCL collective，存储争用的主要影响在 dataloader/H2D 路径——Greyhound 的盲区；通信间接影响信号弱 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | step timing 变慢 |
| 预期能到 D 几 | **D1**（能发现变慢，但无法区分数据饥饿 vs 计算慢 vs 通信慢） |
| 结构性瓶颈 | 无 phase 分解，无存储指标 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | step duration 变慢 + 通信间接影响 |
| 预期能到 D 几 | **D1** |
| 结构性瓶颈 | 监控计算/通信层，对存储路径盲区 |

---

## 4. 执行检查清单

- [ ] 确认有共享存储且邻居容器可访问同一路径
- [ ] 存储压力脚本（fio / dd）测试通过，确认能影响 dataloader 读取
- [ ] 验证 Loud 档下 dataloader_wait 确实升高 >2×
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
| dataloader_wait (ms) | | | | |
| GPU idle_pct | | | | |
| storage read lat (ms) | | | | |

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
