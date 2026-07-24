# Case P3-EXT-A：抢 CPU 核心

> 基于模板 `TEMPLATE.md`。P3 主机外部争用格，最易落地——起 stress-ng 进程抢 CPU。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P3-EXT-A |
| Case 名称 | 抢 CPU 核心（CPU core contention by co-located process） |
| 27 格坐标 | 位置: P3 主机 × 来源: EXT 外部争用 |
| 梯队 | 第一梯队 |
| 权限要求 | ✅ 普通训练用户（起一个 CPU busy 进程即可） |

---

## 1. 注入方案

### 1.1 故障机制
同机另一容器/进程训练中途开始抢 CPU 核心，DataLoader worker 被抢占调度（context switch 增加、CPU 时间片减少），主机侧发射/预处理变慢。真实场景：多租户共享节点、同机有数据预处理作业、日志压缩/打包任务。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 独立进程（CPU 压测工具） |
| 启动方式 | 训练到 step 150 时启动 stress-ng |
| 注入脚本路径 | `run_case_pipeline_v4.sh` → `INJECT_KIND=stress_cpu`（stress-ng） |
| 训练 mode | **必须 `host_bound`**（`__getitem__` 768×768 CPU matmul；num_workers=2 / prefetch=2 不变） |
| 依赖 | `stress-ng` |

**注入器核心逻辑**（经 `INJECT_ARGS`）：
```bash
# Loud
stress-ng --cpu $(nproc) --cpu-load 90 --timeout 600s

# Quiet
stress-ng --cpu $(awk 'BEGIN{print int('$(nproc)'*0.5+0.5)}') --cpu-load 70 --timeout 600s
# INJECT_ARGS=cpu_frac=0.5,cpu_load=70

# Masked
stress-ng --cpu 2 --cpu-load 50 --timeout 600s
# INJECT_ARGS=cpu_n=2,cpu_load=50
```

- step 350（measure 300）时 kill stress-ng

### 1.3 剂量三档（mohe-241 实测）

| 档位 | `INJECT_ARGS` | 预期 / 实测 C1/C0 | 说明 |
|---|---|---|---|
| **Loud** | （默认全核）`cpu_load=90` | 预期 +60%~120%；**实测 2.94×**（loud2） | 验收 ≥1.3 |
| **Quiet** | `cpu_frac=0.5,cpu_load=70` | 预期 +15%~30% | 验收 ≥1.15 |
| **Masked** | `cpu_n=2,cpu_load=50` | 预期 +3%~8% | 近噪声 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | stress-ng 立即生效 | |
| 注入触发时机 | step 150 | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（持续压测） | |
| 注意事项 | 确保 stress-ng 进程在实验结束后被清理 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P3-EXT-A"
target_rank: 7
target_host: "worker-82"
t_on_step: 150
t_off_step: 350
intensity: "stress_ng_cpu=all_cores_90pct"
dose: "loud"
seed: 42
injector_commit: "TBD"
injector_pid: null  # stress-ng master PID
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
外部 CPU 抢占→DataLoader worker 被调度延迟→数据供给变慢→GPU 空闲升高。检测路径：
- L0: step_time straggler
- L2: 定位到具体 rank/host
- L3: 查主机 CPU 指标——CPU utilization 满但非训练进程占用；运行队列升高；context switch 增加
- L4: 外部 PID 占 CPU + 停止后恢复 → P3-EXT（主机外部争用）

**关键**：num_workers=2 时 DataLoader 是 CPU 密集关键路径。CPU 被抢直接导致 worker 预处理变慢。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 有没有 straggler
SELECT rank, avg(duration_ms) as avg_ms
FROM python.torch_trace
WHERE step BETWEEN 150 AND 350
  AND phase = 'step'
GROUP BY rank
ORDER BY avg_ms DESC;
-- 判据: max(avg_ms) / median(avg_ms) >= 1.5

-- Step 2: 主机 CPU 指标
SELECT host,
       avg(cpu_utilization) as cpu_util,
       avg(cpu_runqueue) as runq,
       avg(context_switches_per_sec) as csw
FROM cpu.host_metrics
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350;
-- 判据: cpu_util 高 + runqueue 高 + csw 高 → CPU 争用

-- Step 3: 按进程分解 CPU 占用
SELECT host, pid, cmdline,
       avg(cpu_pct) as cpu_pct
FROM process.cpu_stats
WHERE host = <suspect_host>
  AND step BETWEEN 150 AND 350
  AND pid NOT IN (<training_pids>, <worker_pids>)
ORDER BY cpu_pct DESC;
-- 判据: 外部 PID (stress-ng) 占大量 CPU → 确认外部争用

-- Step 4: 停止后恢复确认（可选，若 step>350 有数据）
SELECT rank,
       avg(CASE WHEN step BETWEEN 150 AND 350 THEN duration_ms END) as during,
       avg(CASE WHEN step BETWEEN 351 AND 400 THEN duration_ms END) as after
FROM python.torch_trace
WHERE rank = <suspect_rank>;
-- 判据: after ≈ baseline → 停 PID 后恢复 → 确认 P3-EXT
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| straggler ratio | ≥1.5 | 触发 D1 |
| cpu_utilization | >90% 且训练自身只占部分 | CPU 争用 |
| 外部 PID CPU 占比 | >30% | 确认外部进程 |
| runqueue | >2x 核心数 | 调度压力 |
| 停止后恢复 | during/after > 1.3 | 因果确认 |

### 2.4 预期定位路径

```
L0(ratio=2.0, straggler) → L2(rank 7, host worker-82)
→ L3(cpu_util=98%, 外部 PID stress-ng 占 85%, runqueue 高)
→ L4(P3-EXT: 主机×外部 CPU 争用)
```

### 2.5 预期 D-level
**D4-D5**（定位到外部 CPU 抢占 = D4；停 PID 后恢复验证 = D5）。

**Loud2 实测（离线训练埋点）**：D3（max `data_ms` → rank7）。

**SQL 环境（2026-07-23）**：Probing_plus `0.2.5` 下 `cpu.utilization`✅（本进程 scope，**看不到** stress-ng 外部 PID）；`process.cpu_stats` / `cpu.host_metrics`❌。D4 可能停在 `SQL_NO_EXT_EVIDENCE`。统一镜像/灌装见 `scripts/fail-slow/image/`。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 慢组；变点与注入时间对齐 |
| 预期能到 D 几 | **D2-D3**（能指出哪个 rank 慢 + 变点时间，但无 CPU/PID 信息） |
| 结构性瓶颈 | 无主机 CPU 进程级信息，无法区分"CPU 被抢"和"DataLoader 代码慢" |

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
| 该 case 能用的判据 | 发射间隙 / host gap 异常 + 数据加载段变慢 |
| 预期能到 D 几 | **D2-D3**（能看到主机侧慢，但不知是 CPU 争用还是其他原因） |
| 结构性瓶颈 | 不采集 CPU runqueue/外部 PID 信息 |

---

## 4. 执行检查清单

- [ ] stress-ng 在目标节点可用（`which stress-ng`）
- [ ] Loud 档测试过（全核压测确认 step_time +60%）
- [ ] 清理逻辑确认（step 350 或实验结束 kill stress-ng）
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
| stress-ng CPU 确认 | — | | | 压测进程在跑 |

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
