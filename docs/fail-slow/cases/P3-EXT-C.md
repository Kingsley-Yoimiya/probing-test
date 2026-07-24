# Case P3-EXT-C：抢内存带宽

> 基于模板 `TEMPLATE.md`。P3 主机外部争用格，内存带宽/NUMA 争用拖慢 pin_memory/H2D/预处理。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-EXT-C |
| Case 名称 | 抢内存带宽 / NUMA 争用（memory bandwidth contention） |
| 27 格坐标 | 位置: P3 主机 × 来源: EXT 外部争用 |
| 梯队 | 第一梯队 |
| 权限要求 | ✅ 普通训练用户（起内存压测进程即可） |

---

## 1. 注入方案

### 1.1 故障机制
邻居进程持续占用主机内存带宽或跨 NUMA 访问，拖慢训练侧主机内存操作（CPU 预处理、pin_memory 拷贝、H2D 数据搬运）。区别于 P3-EXT-A（抢 CPU 算力）和 P3-HW-A（内存容量压力）：本 case 抢的是**内存带宽通道**而非 CPU 时间片或内存容量。真实场景：同 NUMA 节点有大规模 memcpy 作业、向量化处理任务。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程（内存带宽压测工具） |
| 启动方式 | 训练到 step 150 时启动 stress-ng --vm / STREAM benchmark |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-EXT-C/membw_stress.sh` |
| 依赖 | `stress-ng`（--vm / --stream 模式）或手写 STREAM-like loop |

**注入器核心逻辑**：
```bash
# Loud: 全力抢内存带宽，绑到与训练同 NUMA
numactl --cpunodebind=0 --membind=0 \
  stress-ng --stream $(nproc) --stream-l3-size 8M --timeout 0 &

# Quiet: 半数线程
numactl --cpunodebind=0 --membind=0 \
  stress-ng --stream $(($(nproc)/2)) --timeout 0 &

# Masked: 少量线程
stress-ng --stream 2 --timeout 0 &
```

- 关键：绑到与训练进程**同一 NUMA 节点**，才能有效争抢本地内存带宽
- `--stream` 模式是 STREAM triad（连续大块内存读写），最大化带宽消耗

### 1.3 剂量三档

| 档位 | 内存压测参数 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 全核 stream + 同 NUMA 绑定 | +30%~70% | pin_memory/H2D 显著变慢 |
| **Quiet** | 半核 stream + 同 NUMA | +10%~25% | 可观测的搬运延迟 |
| **Masked** | 2 线程 stream，不绑 NUMA | +2%~6% | 轻微争用，接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | stress-ng --stream 立即达峰值带宽 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续带宽压力） | |
| 注意事项 | 确认 NUMA 绑定正确（`numactl -H` 查拓扑）；确保不是容量压力 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-EXT-C"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "stress_ng_stream=all_cores_numa0"
dose: "loud"
numa_node: 0
seed: 42
injector_commit: "TBD"
injector_pid: null  # stress-ng master PID
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
内存带宽争用→pin_memory/H2D/预处理变慢→设备发射间隙增大→step_time 上升。检测路径：
- L0: step_time straggler
- L2: 定位到具体 rank/host
- L3: 查主机内存带宽指标 + 外部进程 + H2D/pin_memory 耗时分解
- L4: 外部进程占内存带宽 + 停止后恢复 → P3-EXT（主机外部内存带宽争用）

**与其他 P3 case 的区分**：
- vs P3-EXT-A：9A 是 CPU 时间片争用（runqueue 高）；本 case 是内存带宽争用（CPU util 可能不高但内存 stall 多）
- vs P3-HW-A：7A 是内存容量压力（available 下降）；本 case 是带宽压力（available 不一定降）

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

-- Step 2: H2D / pin_memory 分解
SELECT rank, host,
       avg(pin_memory_ms) as pin_ms,
       avg(h2d_transfer_ms) as h2d_ms,
       avg(host_gap_ms) as host_gap
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, host;
-- 判据: pin_ms 或 h2d_ms 升高 → 内存搬运瓶颈

-- Step 3: 主机内存带宽指标
SELECT host,
       avg(mem_bandwidth_util_pct) as bw_util,
       avg(llc_miss_rate) as llc_miss,
       avg(numa_remote_access_pct) as numa_remote
FROM cpu.host_metrics
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350;
-- 判据: bw_util 高 / llc_miss 高 / numa_remote 高 → 带宽争用

-- Step 4: 外部进程确认
SELECT host, pid, cmdline,
       avg(mem_bandwidth_mb_s) as bw
FROM process.memory_bandwidth
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
  AND pid NOT IN (<training_pids>)
ORDER BY bw DESC;
-- 判据: 外部 PID (stress-ng --stream) 占大量带宽
-- → 确认 P3-EXT（主机×外部内存带宽争用）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.3 | 触发 D1 |
| pin_memory/H2D 增长 | >2x 基线 | 内存搬运瓶颈 |
| 内存带宽利用率 | >80% | 带宽接近饱和 |
| 外部进程带宽占比 | >40% | 确认外部争用 |
| mem_available 稳定 | 无明显下降 | 排除容量压力(P3-HW-A) |
| CPU runqueue 正常 | <2x 核心数 | 排除 CPU 争用(P3-EXT-A) |

### 2.4 预期定位路径

```
L0(ratio=1.5, straggler) → L2(rank 7, host worker-82)
→ L3(mem_bw_util=90%, pin_memory +3x, 外部 stress-ng --stream 占 60% 带宽)
→ L4(P3-EXT: 主机×外部内存带宽争用)
```

### 2.5 预期 D-level
**D3-D4**。D4 需要能区分"内存带宽争用"和"CPU 争用"和"内存容量压力"。信号较弱（内存带宽指标不如 CPU/IO 直观），可能止步 D3。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组 |
| 预期能到 D 几 | **D2**（能指出谁慢，无内存带宽信息） |
| 结构性瓶颈 | 不采集内存带宽/NUMA 指标 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 步时间离群 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无主机指标 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | H2D 时间 / 发射间隙异常 |
| 预期能到 D 几 | **D2-D3**（能看到 H2D/搬运慢，但不知是带宽争用还是其他） |
| 结构性瓶颈 | 不区分带宽争用 vs 容量压力 vs CPU 争用的具体根因 |

---

## 4. 执行检查清单

- [ ] stress-ng --stream 在目标节点测试过
- [ ] NUMA 拓扑确认（`numactl -H`），绑定到训练同 NUMA 节点
- [ ] Loud 档确认 pin_memory/H2D 变慢（step_time +30%）
- [ ] 确认是带宽压力而非容量压力（mem_available 不显著下降）
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
| pin_memory_ms | | | | |
| mem_bandwidth_util (%) | | | | 带宽压力生效 |

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

- 内存带宽信号强度评估：
- 与 P3-EXT-A / P3-HW-A 的区分效果：

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
