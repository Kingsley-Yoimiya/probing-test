# Case P3-SW-A：对象泄漏 → GC 骤停

> 基于模板 `TEMPLATE.md`。P3 主机软件格，**趋势型检测的核心标杆案例**：从单调增长预警骤停。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-SW-A |
| Case 名称 | 对象/张量泄漏 → GC 骤停（object leak → GC stall） |
| 27 格坐标 | 位置: P3 主机 × 来源: SW 软件缺陷 |
| 梯队 | 第一梯队 |
| 权限要求 | ✅ 普通训练用户（纯脚本层，最易注入） |

---

## 1. 注入方案

### 1.1 故障机制
训练进程内某个对象/张量每 step 轻微多留一份引用（如向全局 list 追加未释放的小张量），累积到 Python GC 阈值或内存限额才触发一次明显的 GC 暂停（数秒级 stop-the-world）。**天然渐进→骤变**模式：前 N 步无差异，跨阈值后骤停。真实场景：第三方库的 hook 累积、全局 tensor 缓存未清、分布式通信 buffer 泄漏。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 训练循环内嵌泄漏逻辑（每 step 追加对象到全局 list） |
| 启动方式 | 训练脚本 step 150 起开始泄漏（通过环境变量/flag 控制） |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P3-SW-A/object_leak.py` |
| 依赖 | 无额外依赖；纯 Python |

**注入器核心逻辑**：
```python
_leak_store = []  # 全局引用，GC 不可回收

def leak_per_step(step, dose="loud"):
    if step < 150:
        return
    # 每 step 追加若干小张量到全局 list
    size_map = {"loud": 1024, "quiet": 256, "masked": 64}  # 对象数/step
    for _ in range(size_map[dose]):
        _leak_store.append(torch.zeros(1024))  # 每个 4KB
```

- Loud: 每 step 泄漏 ~4MB，200 步累积 ~800MB → 触发 GC 或 OOM 压力
- Quiet: 每 step ~1MB，累积 ~200MB → 缓慢增长，晚期可能触发 GC
- Masked: 每 step ~256KB，累积 ~50MB → 仅微量增长

### 1.3 剂量三档

| 档位 | 泄漏速率 | 预期效果 | 说明 |
|---|---|---|---|
| **Loud** | 1024 obj/step × 4KB = 4MB/step | 200 步后触发 GC 骤停（数秒级暂停） | RSS 单调增长 → 明显骤停 |
| **Quiet** | 256 obj/step = 1MB/step | 晚期可能触发 GC，step_time 渐进升高 | 趋势明显但骤停不保证在 500 步内 |
| **Masked** | 64 obj/step = 256KB/step | 仅 RSS 缓慢增长，step_time 几乎无变化 | 考验趋势外推能力 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需；泄漏即刻开始累积 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步（持续泄漏） | |
| 特殊时序 | GC 骤停时机不确定（取决于累积量和 GC 阈值） | Loud 档约 step 300-350 触发 |
| 注意事项 | 仅对单 rank 注入；其他 rank 正常 → 同步等待拖慢全局 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-SW-A"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350  # 泄漏持续到此；但 GC 骤停可能在此窗口内某处
intensity: "leak_rate=1024_obj_per_step_4KB_each"
dose: "loud"
seed: 42
injector_commit: "TBD"
gc_trigger_step: null  # 运行时记录实际触发 step
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
**本 case 的核心检测价值是趋势型早警**：在 GC 骤停发生之前，从 RSS 单调增长趋势提前预警。这区别于只能看"此刻在 GC"的采样检测。

检测路径：
- L0: step_time 中后期出现突发尖峰（GC 骤停时）或渐进升高
- L2: 定位到具体 rank
- L3: 查该 rank 的 RSS 时间序列 → **单调上升趋势** → 斜率外推预警
- L4: RSS 增长 + GC 事件 → P3-SW（主机软件/内存管理）

**早警逻辑**：RSS 斜率回归，外推到 GC 阈值的剩余步数 < N → 提前告警。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 趋势检测 —— RSS 单调增长（核心）
SELECT rank, step,
       rss_mb,
       rss_mb - LAG(rss_mb, 10) OVER (PARTITION BY rank ORDER BY step) as rss_delta_10
FROM process.memory
WHERE rank = <all_ranks>
  AND step BETWEEN 150 AND 350;
-- 判据: 某 rank 的 rss_delta_10 持续 > 0（单调增长）

-- Step 2: 斜率回归 —— 外推何时触发
SELECT rank,
       regr_slope(rss_mb, step) as slope_mb_per_step,
       max(rss_mb) as current_rss,
       (gc_threshold_mb - max(rss_mb)) / regr_slope(rss_mb, step) as steps_to_gc
FROM process.memory
WHERE rank = <suspect_rank>
  AND step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: slope > 0 且 steps_to_gc < 200 → 早警

-- Step 3: 确认 GC 事件（如果已发生）
SELECT rank, step, gc_pause_ms, gc_generation
FROM python.gc_events
WHERE rank = <suspect_rank>
  AND gc_pause_ms > 100;
-- 判据: 存在数秒级 GC 暂停 → 确认泄漏→骤停

-- Step 4: 对象分类 —— 什么在泄漏
SELECT rank,
       object_type,
       count_delta
FROM python.object_stats
WHERE rank = <suspect_rank>
  AND step BETWEEN 150 AND 350
ORDER BY count_delta DESC;
-- 判据: 特定类型对象数单调增长 → 定位泄漏源
-- → 确认 P3-SW（主机软件内存管理缺陷）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| RSS 单调增长 | slope > 0 持续 50+ 步 | 趋势型核心信号 |
| 斜率外推到 GC | steps_to_gc < 200 | 早警触发 |
| GC 暂停时长 | > 1000ms | 确认骤停（事后验证） |
| 对象计数单调增长 | delta > 0 持续 | 泄漏源定位 |
| 训练 PID 内部问题 | RSS 增长在训练进程内 | 区分 P3-SW vs P3-HW/EXT |

### 2.4 预期定位路径

```
L0(趋势: rank 7 RSS 单调增长 4MB/step) → L2(rank 7)
→ L3(slope=4MB/step, steps_to_gc≈50, 对象类型=torch.Tensor)
→ L4(P3-SW: 主机×软件内存泄漏→GC骤停)
早警: 在 GC 骤停前 ~50 步发出预警
```

### 2.5 预期 D-level
**D4-D5**。趋势外推能在骤停前预警(D4+时间维度加分)；若能定位到具体泄漏对象类型则 D5。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测；只能在骤停发生后才看到通信延迟尖峰 |
| 预期能到 D 几 | **D1-D2**（骤停后能检出异常，但无法提前预警，无内存信号） |
| 结构性瓶颈 | **无趋势预警能力**——只看通信时序，看不到 RSS 增长；只能"事后发现" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线分析 |
| 该 case 能用的判据 | 尖峰检测（骤停对应的 step_time 跳变） |
| 预期能到 D 几 | **D1**（事后指出有异常步） |
| 结构性瓶颈 | 无内存/GC 信息，无法归因 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | host gap 骤升（GC 暂停时主机侧停顿） |
| 预期能到 D 几 | **D2-D3**（能看到主机侧暂停，但不知是 GC 还是其他原因） |
| 结构性瓶颈 | 无 RSS/GC 指标；**无趋势预警** |

---

## 4. 执行检查清单

- [ ] 泄漏脚本测试过（Loud 档确认 200 步内触发 GC 暂停）
- [ ] RSS 采集确认能观测到单调增长趋势
- [ ] GC 事件采集就绪（gc.get_stats / gc callback）
- [ ] 确认泄漏仅在目标 rank（其他 rank 正常）
- [ ] Ground-truth 记录器就绪（含 gc_trigger_step 自动记录）
- [ ] Probing 趋势检测 SQL 验证
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
| target rank RSS (MB) final | | | | 泄漏累积生效 |
| GC 暂停 (ms) | | | | 骤停发生 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 早警(骤停前?) | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | 是/否 | | |
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

- 早警提前了多少步？
- 趋势检测 vs 阈值检测的对比：

---

## 6. 版本记录

| 日期 | 修改内容 | 修改人 |
|---|---|---|
| 2026-07-23 | 初始创建 | Claude |
