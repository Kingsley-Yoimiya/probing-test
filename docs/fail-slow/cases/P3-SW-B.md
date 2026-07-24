# Case P3-SW-B：DataLoader Worker 泄漏

> 基于模板 `TEMPLATE.md`。P3 主机软件格，worker 级归因——泄漏在子进程、直接卡数据供给。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-SW-B |
| Case 名称 | DataLoader worker 泄漏/阻塞（worker memory leak / blocking） |
| 27 格坐标 | 位置: P3 主机 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | ✅ 普通训练用户（纯脚本层） |

---

## 1. 注入方案

### 1.1 故障机制
多进程 DataLoader 某个 worker 子进程每 epoch/batch 结束不释放缓存，或被注入可控 sleep/IO delay，阻塞取数/搬运路径。区别于 P3-SW-A：泄漏在**子进程**而非主进程，且直接卡数据供给路径（而非 GC 全局暂停）。真实场景：第三方数据增强库泄漏、worker 内 PIL/OpenCV buffer 未释放、pickle 反序列化缓存膨胀。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | DataLoader worker 内嵌泄漏/延迟逻辑 |
| 启动方式 | 通过 worker_init_fn 或 dataset __getitem__ 在指定 worker_id 注入 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-SW-B/worker_leak.py` |
| 依赖 | 无额外依赖；利用 worker_init_fn + worker_info 定向注入 |

**注入器核心逻辑**：
```python
_worker_leak = []

def leaky_getitem(self, idx):
    data = self._original_getitem(idx)
    worker_info = torch.utils.data.get_worker_info()
    if worker_info and worker_info.id == TARGET_WORKER:
        # 每次取数泄漏一块 buffer
        _worker_leak.append(bytearray(LEAK_SIZE))
        # 可选：注入额外延迟
        if len(_worker_leak) > THRESHOLD:
            time.sleep(DELAY_MS / 1000.0)
    return data
```

- 仅对 worker_id=0 注入（num_workers=2 中的一个）
- 泄漏累积后该 worker 变慢 → prefetch queue 半速 → 间歇数据饥饿

### 1.3 剂量三档

| 档位 | 泄漏速率 / 延迟 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 每 batch 泄漏 2MB + 累积后 sleep 50ms | +50%~100% | 明显数据饥饿 |
| **Quiet** | 每 batch 泄漏 512KB + sleep 10ms | +15%~30% | 偶发空闲 |
| **Masked** | 每 batch 泄漏 128KB，无 sleep | +3%~8% | 仅 RSS 趋势可见 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需；persistent_workers=True 保证 worker 不重启 | |
| 注入触发时机 | step 150（通过共享计数器） | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 泄漏累积效应→后期比前期更慢（渐进加重） | |
| 注意事项 | 仅对 1 个 worker 注入；另一个 worker 正常 → 交替快慢 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-SW-B"
target_rank: 7
target_host: "worker-82"
target_worker_id: 0
t_on_step: 150
t_off_step: 350
intensity: "worker_leak=2MB_per_batch+sleep_50ms"
dose: "loud"
seed: 42
injector_commit: "TBD"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
Worker 泄漏/阻塞 → 数据供给变慢 → GPU 空闲升高 → step_time 上升。检测路径：
- L0: step_time straggler（或间歇性尖峰，因两个 worker 交替服务）
- L2: 定位到具体 rank
- L3: 按 worker PID 分解——哪个 worker 的 RSS 在增长 / 响应变慢
- L4: worker 级泄漏 → P3-SW（主机软件/DataLoader 子进程缺陷）

**关键**：num_workers=2 时有 2 个 worker PID 可区分。泄漏 worker 的 RSS 单调增长、另一个稳定——这是 worker 级归因的关键证据。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有数据饥饿
SELECT rank,
       avg(duration_ms) as avg_ms,
       avg(dataload_ms) as dl_ms,
       avg(device_idle_pct) as idle_pct
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: 某 rank 的 dataload_ms 升高 + idle_pct 升高 → 数据饥饿

-- Step 2: Worker 级 RSS 分解
SELECT host, pid, worker_id,
       min(rss_mb) as rss_start,
       max(rss_mb) as rss_end,
       regr_slope(rss_mb, step) as rss_slope
FROM process.memory
WHERE host = <suspect_host>
  AND cmdline LIKE '%dataloader%worker%'
  AND step BETWEEN 150 AND 350
GROUP BY host, pid, worker_id;
-- 判据: 某 worker 的 rss_slope >> 0 而另一个 ≈ 0 → 定向泄漏

-- Step 3: Worker 响应时间
SELECT worker_id,
       avg(batch_fetch_ms) as fetch_ms,
       stddev(batch_fetch_ms) as fetch_std
FROM python.dataloader_stats
WHERE rank = <suspect_rank>
  AND step BETWEEN 150 AND 350
GROUP BY worker_id;
-- 判据: 泄漏 worker 的 fetch_ms 持续升高

-- Step 4: 排除主进程泄漏
SELECT pid, cmdline, rss_mb, regr_slope(rss_mb, step) as slope
FROM process.memory
WHERE host = <suspect_host>
  AND cmdline LIKE '%train%'  -- 主训练进程
  AND step BETWEEN 150 AND 350;
-- 判据: 主进程 RSS 稳定 → 泄漏在 worker 子进程
-- → 确认 P3-SW（DataLoader worker 软件缺陷）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| dataload_ms 增长 | >2x 基线 | 数据供给瓶颈 |
| worker RSS slope 差异 | 泄漏 worker > 0, 正常 worker ≈ 0 | worker 级定位 |
| worker fetch_ms 差异 | 泄漏 worker > 2x 正常 worker | 响应时间确认 |
| 主进程 RSS 稳定 | slope ≈ 0 | 排除 P3-SW-A（主进程泄漏） |
| device_idle_pct | >10% 增长 | 数据饥饿效应 |

### 2.4 预期定位路径

```
L0(rank 7 dataload_ms +3x, idle +15%) → L2(rank 7)
→ L3(worker_id=0 RSS slope=2MB/step, worker_id=1 稳定; fetch_ms 3x差异)
→ L4(P3-SW: 主机×DataLoader worker 泄漏)
```

### 2.5 预期 D-level
**D4-D5**（能定位到具体 worker + 泄漏模式 = D4；若能指出泄漏对象类型 = D5）。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组；数据饥饿表现为通信等待 |
| 预期能到 D 几 | **D2**（能指出哪个 rank 慢，无 worker 级信息） |
| 结构性瓶颈 | 无 DataLoader worker PID/RSS 信号，无法区分 8A/8B/8C |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 步时间渐进升高趋势 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无主机进程信息 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 数据加载阶段时间异常 |
| 预期能到 D 几 | **D2-D3**（能看到数据加载慢，但不知是哪个 worker） |
| 结构性瓶颈 | 不区分 worker；不采集子进程 RSS |

---

## 4. 执行检查清单

- [ ] Worker 泄漏脚本测试过（Loud 档确认数据饥饿、step_time +50%）
- [ ] 确认 persistent_workers=True（worker 不重启，泄漏持续累积）
- [ ] worker_init_fn=seed_worker 且注入逻辑可按 worker_id 定向
- [ ] Worker RSS 采集确认（能按 PID 区分两个 worker）
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
| worker_0 RSS final (MB) | | | | 泄漏累积 |
| worker_1 RSS final (MB) | | | | 对照（稳定） |

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

- Worker 级归因成功率：
- 与 P3-SW-A 的区分效果：

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
