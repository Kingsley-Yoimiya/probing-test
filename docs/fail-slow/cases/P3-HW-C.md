# Case P3-HW-C：本地盘读延迟上升

> 基于模板 `TEMPLATE.md`。P3 主机硬件退化格，盘级 fail-slow 映射到 DataLoader 数据饥饿。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-HW-C |
| Case 名称 | 本地盘读延迟上升（local disk read latency degradation） |
| 27 格坐标 | 位置: P3 主机 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需盘级配合（dm-delay 需 root；FUSE 可用户态） |

---

## 1. 注入方案

### 1.1 故障机制
本地 SSD/HDD 老化或后台 GC（SSD TRIM/垃圾回收），导致数据盘读延迟逐渐上升。DataLoader 从本地读训练数据的速度下降，造成 GPU 数据饥饿、设备空闲升高。真实场景：SSD 写放大导致 GC 风暴、磁盘坏道导致重试、RAID 降级模式。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | IO 延迟注入层（dm-delay / FUSE passthrough with delay / tc-like IO scheduler） |
| 启动方式 | 训练到 step 150 时激活延迟注入，逐步加大读延迟 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-HW-C/disk_delay.sh` |
| 依赖 | 方案 A: `dm-delay`（需 root）；方案 B: FUSE passthrough（用户态，但需数据路径经 FUSE） |

**注入器核心逻辑**：
- 方案 A（dm-delay，需 root）：在数据盘设备映射层插入延迟，对所有读操作增加指定毫秒延迟
- 方案 B（FUSE，用户态）：用 passthrough FUSE 挂载数据目录，对 read 调用插入 sleep
- 方案 C（简易代理）：后台持续对同盘做随机读写（fio），间接拖慢 DataLoader 的 IO

### 1.3 剂量三档

| 档位 | 读延迟增加 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | +50ms per read op | +80%~150% | DataLoader 严重饥饿 |
| **Quiet** | +10ms per read op | +15%~30% | 可观测的数据供给变慢 |
| **Masked** | +2ms per read op | +3%~8% | 接近噪声，仅偶发空闲 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | dm-delay 即时生效；FUSE 需提前挂载 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 可选：逐步增大延迟（模拟渐进退化） | |
| 注意事项 | 确保数据路径确实经过注入层；persistent_workers=True 意味着 worker 不重启 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-HW-C"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "disk_read_delay=50ms"
dose: "loud"
injection_method: "dm-delay"  # or "fuse" or "fio_proxy"
seed: 42
injector_commit: "TBD"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
盘延迟↑ → DataLoader 取数变慢 → GPU 数据饥饿 → 设备空闲升高 → step_time 上升。检测路径：
- L0: step_time straggler
- L2: 定位到具体 rank/host
- L3: 查该 host 的磁盘 IO 延迟 + DataLoader 取数边界时间
- L4: 盘延迟↑与空闲窗对齐 → P3-HW（主机盘硬件）

**关键**：num_workers=2 + persistent_workers=True，DataLoader worker 持续从盘读数据。盘变慢直接导致 prefetch queue 排空。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max(avg_ms) / median(avg_ms) >= 1.3

-- Step 2: 定位 —— 看数据加载段
SELECT rank, host,
       avg(dataload_ms) as dl_ms,
       avg(device_idle_pct) as idle_pct
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, host;
-- 判据: dataload_ms 明显升高 → DataLoader 瓶颈

-- Step 3: 归因 —— 磁盘 IO 指标
SELECT host,
       avg(disk_read_latency_ms) as read_lat,
       avg(disk_io_util_pct) as io_util,
       avg(disk_read_iops) as iops
FROM cpu.host_metrics
WHERE step BETWEEN 150 AND 350
  AND host = <suspect_host>;
-- 判据: read_latency 升高 + io_util 升高 → 盘级问题

-- Step 4: 排除外部 IO 争用
SELECT host, pid, cmdline, avg(io_bytes_read) as io_read
FROM process.io_stats
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
  AND pid != <training_pid>
ORDER BY io_read DESC;
-- 判据: 无外部大 IO 进程 → 盘自身退化(P3-HW)
--       有外部 IO 进程 → 转向 P3-EXT-B
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.3 | 触发 D1 |
| dataload_ms 增长 | >3x 基线 | 数据供给瓶颈 |
| disk_read_latency | >5x 基线 | 盘延迟退化 |
| disk_io_util | >80% | 盘接近饱和 |
| 无外部 IO 大进程 | True | 排除 P3-EXT |

### 2.4 预期定位路径

```
L0(ratio=2.0, straggler) → L2(rank 7, host worker-82)
→ L3(disk_read_lat +50ms, dataload_ms +5x, 无外部 IO 进程)
→ L4(P3-HW: 主机×盘硬件退化)
```

### 2.5 预期 D-level
**D4**（能定位到"本地盘读延迟导致数据饥饿"）。若能区分是 SSD GC 还是物理退化则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组识别 |
| 预期能到 D 几 | **D2**（能发现 straggler，无 IO 归因） |
| 结构性瓶颈 | 不采集磁盘 IO 指标 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 步时间离群 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无主机 IO 信号 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 发射间隙 / 数据加载时间异常 |
| 预期能到 D 几 | **D2-D3**（能看到数据加载段变慢，但不知是盘还是其他原因） |
| 结构性瓶颈 | 不采集盘延迟指标 |

---

## 4. 执行检查清单

- [ ] 盘延迟注入方案选定并测试（dm-delay / FUSE / fio 代理）
- [ ] Loud 档确认 DataLoader 可见饥饿（step_time +80%）
- [ ] 数据路径确实经过注入层（检查训练数据目录挂载点）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测 SQL 验证
- [ ] DataLoader 配置：num_workers=2, worker_init_fn=seed_worker, persistent_workers=True
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / seed 42 / PROBING=2 / rate=1.0
- [ ] 节点列表确认，硬件健康

---

## 5. 实验结果（跑后填写）

### 5.1 Run 记录

| Run | Seed | 日期 | 剂量 | 状态 | Run ID |
|---|---|---|---|---|---|
| A (baseline) | 42 | | — | | |
| B (injection) | 42 | | loud | | |
| C (Probing) | 42 | | loud | | |
| D (XPUTimer) | 42 | | loud | | |

### 5.2 注入生效性验证

| 指标 | A 线 | B 线 | 差异 | 结论 |
|---|---|---|---|---|
| step_time mean (ms) | | | | |
| target rank step_time | | | | |
| disk_read_latency (ms) | | | | 盘延迟注入生效 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |
| XPUTimer | | | | | |

### 5.4 开销影响

| 指标 | A 线 | C 线(Probing) | 开销% | D 线(XPUTimer) | 开销% |
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
