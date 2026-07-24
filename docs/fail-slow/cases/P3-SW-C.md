# Case P3-SW-C：监控程序自身泄漏（元故障）

> 基于模板 `TEMPLATE.md`。P3 主机软件格，"观测系统自己变成故障源"的反向测试——需全主机视角。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-SW-C |
| Case 名称 | 监控程序自身泄漏（monitor self-leak, meta-fault） |
| 27 格坐标 | 位置: P3 主机 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | ✅ 普通训练用户（起一个泄漏进程即可） |

---

## 1. 注入方案

### 1.1 故障机制
常驻日志/监控/诊断进程本身有内存泄漏，逐渐挤占主机可用内存，**间接**拖慢主训练进程——"观测系统自己变成 fail-slow 根源"。区别于 8A/8B：根因不在训练进程内部，而在训练进程外的同机旁路程序。真实场景：Prometheus exporter 泄漏、日志采集 agent 缓存膨胀、GPU 监控 daemon RSS 增长。

本 case 直接服务论文论点："诊断系统自身开销需单独测量——连监控 agent 的泄漏都能拖慢训练"。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程（模拟泄漏的监控 daemon） |
| 启动方式 | 训练到 step 150 时启动泄漏进程 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-SW-C/monitor_leak.py` |
| 依赖 | 无额外依赖；纯 Python 进程 |

**注入器核心逻辑**：
```python
"""模拟一个泄漏的监控进程"""
import time, mmap, os

_leak = []

def main(leak_rate_mb=10, interval_s=1.0):
    """每 interval 秒分配 leak_rate_mb 内存并持有"""
    while True:
        # 分配并触碰页面（确保物理分配）
        buf = mmap.mmap(-1, leak_rate_mb * 1024 * 1024)
        buf.write(b'\x01' * (leak_rate_mb * 1024 * 1024))
        _leak.append(buf)
        time.sleep(interval_s)
```

- 独立于训练进程运行
- 逐步占用主机内存 → 系统内存压力 → 间接影响训练进程（page cache eviction、swap pressure、malloc 变慢）

### 1.3 剂量三档

| 档位 | 泄漏速率 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 10MB/s（200 步内占 ~60% 可用内存） | +30%~80% | 系统内存压力明显 |
| **Quiet** | 3MB/s（200 步内占 ~20% 可用内存） | +10%~20% | 轻微压力 |
| **Masked** | 1MB/s（200 步内占 ~8% 可用内存） | +2%~5% | 几乎无影响 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 泄漏进程启动即开始分配 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 渐进效应（随累积量增大，影响逐步加重） | |
| 注意事项 | 防止 OOM killer 杀训练进程；设内存上限 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-SW-C"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "external_leak=10MB_per_sec"
dose: "loud"
injector_process: "monitor_leak.py"
seed: 42
injector_commit: "TBD"
injector_pid: null  # 运行时填
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
外部进程泄漏→系统内存压力→训练间接变慢。检测路径：
- L0: step_time 渐进升高（非突发）
- L2: 定位到具体 host
- L3: 全主机视角——找到 RSS 增长最快的**非训练 PID**
- L4: 非训练进程泄漏 → P3-SW（主机软件缺陷，但不在训练内部）

**关键区分**：
- vs P3-SW-A：8A 的泄漏在训练主进程内（RSS 增长是训练 PID）
- vs P3-SW-B：8B 的泄漏在 DataLoader worker（RSS 增长是 worker PID）
- vs P3-HW-A：7A 是硬件级内存压力（ECC/物理问题）
- 本 case：RSS 增长在**训练进程外的独立 PID**

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有渐进 straggler
SELECT rank, step,
       duration_ms,
       avg(duration_ms) OVER (PARTITION BY rank ORDER BY step ROWS 20 PRECEDING) as ma20
FROM python.torch_trace
WHERE step BETWEEN 100 AND 400
  AND phase = 'step';
-- 判据: 某 rank 的 ma20 在 step 150 后单调上升

-- Step 2: 全主机进程 RSS 排名
SELECT host, pid, cmdline,
       max(rss_mb) as peak_rss,
       regr_slope(rss_mb, step) as rss_slope
FROM process.memory
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
GROUP BY host, pid, cmdline
ORDER BY rss_slope DESC;
-- 判据: 非训练 PID 的 rss_slope 最大 → 外部进程泄漏

-- Step 3: 系统内存压力确认
SELECT host,
       avg(mem_available_gb) as avail,
       min(mem_available_gb) as min_avail,
       avg(page_fault_rate) as pgfault
FROM cpu.host_metrics
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350;
-- 判据: mem_available 持续下降 + page_fault 升高

-- Step 4: 相关性确认
-- 泄漏进程 RSS 增长 vs 训练 step_time 增长
SELECT corr(ext_rss, step_time) as correlation
FROM (
    SELECT step,
           p_ext.rss_mb as ext_rss,
           t.duration_ms as step_time
    FROM process.memory p_ext
    JOIN python.torch_trace t USING (step)
    WHERE p_ext.pid = <leaking_pid>
      AND t.rank = <suspect_rank>
);
-- 判据: correlation > 0.7 → 确认因果
-- → P3-SW（主机软件，训练外部进程缺陷）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| step_time 渐进上升 | ma20 斜率 > 0 | 趋势型信号 |
| 非训练 PID RSS slope | 最大且 >> 0 | 定位泄漏源 |
| mem_available 下降 | 持续下降趋势 | 系统压力 |
| 泄漏 PID RSS vs step_time 相关性 | > 0.7 | 因果确认 |
| 训练进程自身 RSS 稳定 | slope ≈ 0 | 排除 8A/8B |

### 2.4 预期定位路径

```
L0(rank 7 step_time 渐进上升) → L2(rank 7, host worker-82)
→ L3(PID=monitor_leak.py RSS slope=10MB/s, 训练 PID 稳定, mem_available↓)
→ L4(P3-SW: 主机×外部软件泄漏/监控自身故障)
```

### 2.5 预期 D-level
**D4**（定位到"非训练外部进程泄漏拖慢训练"）。若能指出具体 PID + cmdline 则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 渐进变慢趋势检测 |
| 预期能到 D 几 | **D1-D2**（能看到变慢，无全主机进程信息） |
| 结构性瓶颈 | 无全机进程 RSS 视角，无法定位到训练外部的泄漏进程 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 渐进趋势 |
| 预期能到 D 几 | **D1** |
| 结构性瓶颈 | 无主机视角 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | host gap 渐进升高 |
| 预期能到 D 几 | **D2**（看到主机侧变慢，但不知为何） |
| 结构性瓶颈 | 不采集全机进程信息；不知道是哪个外部进程 |

---

## 4. 执行检查清单

- [ ] 泄漏进程脚本测试过（Loud 档确认间接拖慢训练 +30%）
- [ ] 确认不触发 OOM killer 杀训练（设内存上限/cgroup）
- [ ] 全机进程 RSS 采集就绪（能看到所有 PID）
- [ ] Ground-truth 记录器就绪
- [ ] Probing 检测 SQL 验证（含全机 PID 排名）
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
| monitor_leak RSS final (MB) | | | | 泄漏进程累积 |
| mem_available final (GB) | | | | 系统压力 |

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

- "诊断系统自身开销"论点验证：
- 与 P3-SW-A/B 的区分效果：

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
