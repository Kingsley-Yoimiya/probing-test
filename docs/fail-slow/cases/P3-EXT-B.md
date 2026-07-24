# Case P3-EXT-B：抢磁盘 IO

> 基于模板 `TEMPLATE.md`。P3 主机外部争用格，IO 压测进程抢盘带宽拖慢 DataLoader/checkpoint。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-EXT-B |
| Case 名称 | 抢磁盘 IO（disk IO contention by co-located process） |
| 27 格坐标 | 位置: P3 主机 × 来源: EXT 外部争用 |
| 梯队 | 第一梯队 |
| 权限要求 | ✅ 普通训练用户（起 IO 压测进程即可） |

---

## 1. 注入方案

### 1.1 故障机制
邻居容器/进程持续大量磁盘写入（或随机读），拖慢 DataLoader 预读和 checkpoint 写入的 IO 路径。区别于 P3-EXT-A（抢 CPU）和 P3-HW-C（盘硬件退化）：根因是**外部进程的 IO 争用**而非盘本身慢。真实场景：同节点有数据写入作业、日志归档压缩、checkpoint 并发写入。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程（IO 压测工具） |
| 启动方式 | 训练到 step 150 时启动 fio / dd 循环写 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-EXT-B/io_stress.sh` |
| 依赖 | `fio`（推荐）或 `dd` |

**注入器核心逻辑**：
```bash
# Loud: 持续随机读写打满盘
fio --name=io_stress --rw=randrw --bs=4k --size=10G \
    --numjobs=4 --time_based --runtime=0 \
    --directory=/data/stress_tmp &

# Quiet: 顺序写，中等强度
fio --name=io_stress --rw=write --bs=1M --size=5G \
    --numjobs=2 --time_based --runtime=0 \
    --directory=/data/stress_tmp &

# Masked: 轻量写
fio --name=io_stress --rw=write --bs=1M --size=2G \
    --numjobs=1 --rate=50M --time_based --runtime=0 \
    --directory=/data/stress_tmp &
```

- 关键：写入目录必须与训练数据**同一块物理盘**
- step 350 时 kill fio 并清理临时文件

### 1.3 剂量三档

| 档位 | IO 压测参数 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 4 job × 4K 随机读写（打满 IOPS） | +60%~120% | 盘完全饱和 |
| **Quiet** | 2 job × 1M 顺序写 | +15%~30% | 带宽争用但 IOPS 未满 |
| **Masked** | 1 job × rate-limited 50MB/s | +3%~8% | 轻微争用 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | fio 立即开始 IO | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续 IO 压力） | |
| 注意事项 | 确保与训练数据同盘；清理临时文件 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-EXT-B"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "fio_randrw_4k_4jobs"
dose: "loud"
target_disk: "/dev/sda"  # 或对应 mount point
seed: 42
injector_commit: "TBD"
injector_pid: null  # fio master PID
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
外部 IO 压力→盘 IOPS/带宽被抢→DataLoader 读数据变慢→GPU 数据饥饿。检测路径：
- L0: step_time straggler
- L2: 定位到具体 rank/host
- L3: 查盘 IO 指标（IO util、延迟、IOPS）+ 外部进程 IO 用量
- L4: 外部 PID 大量 IO + 停止后恢复 → P3-EXT（主机外部 IO 争用）

**与 P3-HW-C 的区分**：P3-HW-C 无外部 IO 进程（盘自身退化）；本 case 有明确的外部 IO 进程。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 数据加载变慢
SELECT rank,
       avg(duration_ms) as avg_ms,
       avg(dataload_ms) as dl_ms,
       avg(device_idle_pct) as idle_pct
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: dataload_ms 升高 + idle_pct 升高 → 数据供给瓶颈

-- Step 2: 磁盘 IO 指标
SELECT host,
       avg(disk_io_util_pct) as io_util,
       avg(disk_read_latency_ms) as read_lat,
       avg(disk_write_iops) as write_iops
FROM cpu.host_metrics
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350;
-- 判据: io_util > 90% + read_lat 升高 → 盘饱和

-- Step 3: 按进程分解 IO
SELECT host, pid, cmdline,
       avg(io_bytes_write) as io_write,
       avg(io_bytes_read) as io_read
FROM process.io_stats
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
  AND pid NOT IN (<training_pids>)
ORDER BY (io_write + io_read) DESC;
-- 判据: 外部 PID (fio) 大量 IO → 确认外部争用

-- Step 4: 停止后恢复
SELECT rank,
       avg(CASE WHEN step BETWEEN 150 AND 350 THEN dataload_ms END) as during,
       avg(CASE WHEN step BETWEEN 351 AND 400 THEN dataload_ms END) as after
FROM python.torch_trace
WHERE rank = <suspect_rank>;
-- 判据: after 回到基线 → 确认 P3-EXT（停即恢复）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.5 | 触发 D1 |
| disk_io_util | >90% | 盘饱和 |
| 外部 PID IO 占比 | >50% 总 IO | 确认外部进程 |
| read_latency 升高 | >5x 基线 | IO 延迟效应 |
| 停止后恢复 | during/after > 1.5 | 因果确认 |

### 2.4 预期定位路径

```
L0(ratio=2.0, dataload +4x) → L2(rank 7, host worker-82)
→ L3(io_util=98%, fio PID 写 200MB/s, read_lat +10x)
→ L4(P3-EXT: 主机×外部 IO 争用)
```

### 2.5 预期 D-level
**D4-D5**（定位到外部 IO 进程 = D4；停 fio 后恢复验证 = D5）。

### 2.6 PSI-io 旁路证据（2026-07-24 短标定）
`cpu.tasks` / `process.io_stats` 可能只采到被 attach 的训练进程，不能保证看见 pod 外的 `fio`。因此 C2 注入窗的
`dump_probing_sql.sh` 同时采 `/proc/pressure/io` 的 `some.total`，用相邻采样差分计算阻塞时间速率（单位 us/s）：

- `fio randrw` × 8、4 KiB、pod overlay（与训练工作目录同一挂载）下，基线 **22.7 us/s**，压力窗 **148,778.5 us/s**，冷却 **0.7 us/s**，压力/基线约 **6,554×**。
- P3-EXT-B 默认 `HOST_PSI_IO_RATE_THRESH=50,000` us/s；该值低于此次压力窗约 3 倍、高于基线约 2,200 倍。正式战役应在真实 C2 注入窗复验；若盘型或 fio 并发改变，重新标定并通过环境变量覆盖。
- 判分只接受 dump 同窗的 `host_pressure.json` 中 `host_psi_io` 命中，作为 P3 外部 IO 争用证据；`injection.log` 与裸 `pgrep fio` 仅作运行旁证，不单独升 D4。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组 |
| 预期能到 D 几 | **D2**（能指出谁慢，无 IO 信息） |
| 结构性瓶颈 | 不采集磁盘 IO / 进程 IO 指标 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 步时间离群 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无 IO 信号 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 数据加载段时间异常 |
| 预期能到 D 几 | **D2-D3**（能看到 DataLoader 慢，但不知是盘争用还是其他） |
| 结构性瓶颈 | 不区分 IO 争用 vs 盘退化 vs DataLoader 代码问题 |

---

## 4. 执行检查清单

- [ ] fio 在目标节点可用（`which fio`）
- [ ] 确认 fio 写入目录与训练数据同盘
- [ ] Loud 档测试过（确认盘 IO util 接近 100%，step_time +60%）
- [ ] 清理逻辑确认（kill fio + 删临时文件）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测 SQL 验证
- [ ] DataLoader 配置：num_workers=2, worker_init_fn=seed_worker, persistent_workers=True
- [ ] 训练配置：GPT-2 124M / 500 步 / warmup 50 / seed 42 / PROBING=2 / rate=1.0
- [ ] 节点列表确认

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
| disk_io_util (%) | | | | IO 压力生效 |
| fio 带宽确认 | — | | | |

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
