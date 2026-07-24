# Case P3-HW-A：内存 ECC 累积 / 换页代理

> 基于模板 `TEMPLATE.md`。P3 主机硬件退化格，ECC 不可精确注入，用大内存分配代理。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-HW-A |
| Case 名称 | 内存 ECC 累积 / 换页代理（host memory pressure proxy） |
| 27 格坐标 | 位置: P3 主机 × 来源: HW 硬件退化 |
| 梯队 | 第三梯队 |
| 权限要求 | ◐ 需能起大内存进程（锁页可能需提升 ulimit） |

---

## 1. 注入方案

### 1.1 故障机制
主机内存 correctable ECC error 累积触发降频保护，或后台意外大内存分配触发换页（page fault / swap），导致主机侧内存访问骤慢。真实场景：老化 DIMM、内核自动降速保护、邻居容器内存超卖。

由于 ECC 累积不可精确用户态注入，本 case 用**代理方式**：定时触发大内存分配 + mlock 锁页，模拟换页骤增 / 内存压力对训练主机侧的拖慢效果。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程（内存压力生成器） |
| 启动方式 | 外部调度在 step 150 时触发启动，逐步分配并锁定大页 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-HW-A/mem_pressure.py` |
| 依赖 | `stress-ng --vm` 或自写 mmap+mlock 脚本；可能需 `ulimit -l` 提升 |

**注入器核心逻辑**：
1. 启动后按剂量参数逐步 mmap + mlock 大块内存
2. 周期性触碰已分配页面（防止被 OOM killer 回收前就 swap out）
3. 造成系统 page fault 率升高、可用内存下降，间接拖慢训练进程的主机侧内存操作

### 1.3 剂量三档

| 档位 | 内存占用 / 压力参数 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 占用主机 70% 可用内存 + 高频触碰 | +50%~100% | 触发明显换页/OOM 压力 |
| **Quiet** | 占用主机 40% 可用内存 | +15%~30% | 内存紧张但未触发 swap |
| **Masked** | 占用主机 20% 可用内存 | +3%~8% | 轻微压力，接近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 分配过程本身需 5-10s 逐步 mmap | 避免瞬间 OOM |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续内存压力） | |
| 注意事项 | 须确保不触发 OOM killer 杀训练进程；设安全阈值 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-HW-A"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "mem_pressure=70%_available"
dose: "loud"
seed: 42
injector_commit: "TBD"
injector_pid: null  # 运行时填
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
内存压力→主机侧操作变慢（DataLoader 预处理、pin_memory、Python 对象操作）→设备空闲升高。检测路径：
- L0: step_time 出现 straggler
- L2: 定位到具体 rank/host
- L3: 查该 host 的内存指标（RSS、available memory、page fault rate）
- L4: 确认是 P3(主机) × HW(硬件/系统级内存问题)

**关键**：num_workers=2 时 DataLoader 在关键路径上，内存压力会通过 worker 进程的内存操作放大到 step_time。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max(avg_ms) / median(avg_ms) >= 1.3 → 有 straggler

-- Step 2: 定位 —— 看主机侧空闲
SELECT rank, host,
       avg(device_idle_pct) as idle_pct,
       avg(host_gap_ms) as host_gap
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND rank = <suspect_rank>
GROUP BY rank, host;
-- 判据: device_idle_pct 升高 → 主机侧瓶颈

-- Step 3: 归因 —— 查内存指标
SELECT host,
       avg(mem_available_gb) as avail,
       avg(page_fault_rate) as pgfault,
       max(swap_used_mb) as swap
FROM cpu.host_metrics
WHERE step BETWEEN 150 AND 350
  AND host = <suspect_host>;
-- 判据: mem_available 骤降 + page_fault_rate 升高 → 内存压力

-- Step 4: 排除软件泄漏 —— 是否训练进程自身
SELECT host, pid, cmdline, avg(rss_mb) as rss
FROM process.memory
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
ORDER BY rss DESC;
-- 判据: 非训练 PID 占大量内存 → 外部/硬件压力(P3-HW)
--       训练 PID 自身 RSS 增长 → 转向 P3-SW
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.3 | 主机类影响通常不如芯片级大 |
| device_idle_pct 升高 | >5% 绝对增长 | 指向主机侧瓶颈 |
| mem_available 下降 | <30% 基线值 | 内存紧张 |
| page_fault_rate | >2x 基线 | 换页压力 |
| 非训练 PID 大内存 | 存在 | 确认非训练自身泄漏 |

### 2.4 预期定位路径

```
L0(ratio=1.5, straggler) → L2(rank 7, host worker-82)
→ L3(mem_available 骤降, pgfault +3x, 非训练 PID 占 70% 内存)
→ L4(P3-HW: 主机×硬件/内存压力)
```

### 2.5 预期 D-level
**D3-D4**。能定位到主机内存压力层(D4)；但因是代理注入，真实 ECC 根因无法直接验证，可能止步 D3（"主机内存问题"但无法细分 ECC vs 换页）。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组识别；无主机内存信号 |
| 预期能到 D 几 | **D2**（能发现哪个 rank 慢，无主机归因能力） |
| 结构性瓶颈 | 无主机侧内存/换页指标，不能区分"主机内存压力"和其他主机类故障 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | S = mean(nodelay)/mean(noblk) > 1.03 |
| 预期能到 D 几 | **D1-D2**（能指出 straggler 存在） |
| 结构性瓶颈 | 无主机指标，无法归因 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，采集每步各阶段时间 |
| 该 case 能用的判据 | host_gap / 发射间隙异常；可观测到主机侧变慢 |
| 预期能到 D 几 | **D2-D3**（能看到主机侧 gap 异常，但无内存归因） |
| 结构性瓶颈 | 有信号无自动 RCA；不采集内存/换页指标 |

---

## 4. 执行检查清单

- [ ] 内存压力脚本在目标节点测试过（Loud 档确认触发换页、step_time +50%）
- [ ] 确认不会触发 OOM killer 杀训练进程（设安全水位线）
- [ ] ulimit -l 检查/提升（如需 mlock）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测 SQL 在 Loud 档验证过
- [ ] DataLoader 配置确认：num_workers=2, persistent_workers=True
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
| mem_available (GB) | | | | 内存压力生效 |

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
