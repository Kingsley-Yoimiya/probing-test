# Case P2-SW-B：通信算法切换阈值不当

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（✅ 普通用户权限，已有实测基础）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-SW-B |
| Case 名称 | 通信算法切换阈值不当（algorithm switch threshold mismatch） |
| 27 格坐标 | 位置: P2 互联 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | ✅ 普通训练用户（改环境变量/message size） |

---

## 1. 注入方案

### 1.1 故障机制
NCCL 等通信库对不同 message size 选择不同算法（如 ring/tree/collnet），切换阈值由环境变量或自动调优决定。当 message size 恰好跨过切换阈值时，可能选中次优算法——某档 message size 一直走慢算法。真实场景：模型升级改变 tensor size、通信库版本升级改阈值默认值、用户配置遗留。已有实测：强制某档配置后带宽从 81.8 降到 38.2 GB/s（降 53%）。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 环境变量注入（修改 NCCL 算法切换阈值） |
| 启动方式 | 训练启动时即设置错误阈值，或中途通过 wrapper 改 message size 分桶 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-SW-B/` |
| 依赖 | 无额外依赖，纯环境变量控制 |

**注入器核心逻辑**：通过 `NCCL_ALGO` / `NCCL_TREE_THRESHOLD` 等环境变量强制某档 message size 走次优算法。或改变训练中的 gradient bucket size 使其跨过阈值边界。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 强制所有 collective 走 ring（禁 tree/collnet） | step_time +50%~100%（大消息走 ring 效率低） |
| **Quiet** | 仅部分 size 档位走次优（调 threshold 使主要 tensor 刚好跨界） | step_time +15%~30% |
| **Masked** | 极少量 tensor 跨阈值（调 bucket 使 5% 的通信走次优） | step_time +3%~8% |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热（环境变量启动时生效） | |
| 注入触发时机 | step 150（通过 wrapper 在 step 150 动态改环境变量或 bucket size） | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（一旦阈值改变，持续影响所有后续通信） | |
| 注意事项 | 需确认目标集群的默认阈值，注入后需验证算法确实切换了 | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-SW-B"
target_rank: "all"           # 全局配置，影响所有 rank
target_host: "all"
original_algo: "tree"
forced_algo: "ring"
threshold_change: "NCCL_TREE_THRESHOLD=0 (force all ring)"
affected_msg_sizes: ">256KB"
t_on_step: 150
t_off_step: 350
intensity: "force_ring_all_sizes"
dose: "loud"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
算法切换阈值不当的特征：**特定 message size 的集合通信明显偏慢**，而其他 size 正常。实测带宽在阈值附近出现断崖。关键：不是某个 rank 慢——是**所有 rank 的某类通信都慢**。

核心检测路径：
- L0: step_time 全局变慢（所有 rank 类似幅度）
- L2: 不是某个 rank 的问题，而是**某类 collective 操作**变慢
- L3: `nccl.coll_perf` 按 message size 分桶，发现特定 size 带宽断崖 + 算法选择日志
- L4: 带宽-size 曲线断点 + 算法名对比 → P2-SW（软件配置/算法选择）

**关键信号**：
- `nccl.coll_perf` 中 `algo_bw_gbps` 按 `msg_size` 分桶的双峰
- 所有 rank 等幅退化（非单点故障）
- `send_gpu_wait_ns` 和 `recv_wait_ns` 都适度升高（等待通信完成）

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 全局通信变慢（非单 rank）
SELECT step,
       avg(duration_ms) as avg_comm_ms,
       stddev(duration_ms) / avg(duration_ms) as cv
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
GROUP BY step;
-- 判据: avg 升高但 CV 低（所有 rank 等幅变慢）→ 全局配置问题

-- Step 2: 定位 —— 按 message size 分桶看带宽
SELECT msg_size_bucket,
       avg(algo_bw_gbps) as avg_bw,
       count(*) as cnt
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
GROUP BY msg_size_bucket
ORDER BY msg_size_bucket;
-- 判据: 大 message size 带宽异常低（如 >256KB 的 bw 从 80GB/s 降到 38GB/s）
-- 小 message size 可能不受影响

-- Step 3: 归因 —— 对比注入前后 + 算法信息
SELECT msg_size_bucket,
       avg(CASE WHEN step < 150 THEN algo_bw_gbps END) as pre_bw,
       avg(CASE WHEN step >= 150 THEN algo_bw_gbps END) as post_bw,
       any_value(CASE WHEN step >= 150 THEN algorithm END) as algo_used
FROM nccl.coll_perf
GROUP BY msg_size_bucket
HAVING post_bw / pre_bw < 0.7;
-- 判据: 特定 size 带宽断崖 + 算法从 tree 变成 ring
-- → 算法切换导致

-- Step 4: 确认 —— 排除硬件/外部（全 rank 等幅、硬件正常）
SELECT rank,
       avg(duration_ms) as avg_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
GROUP BY rank;
-- 判据: 所有 rank 退化幅度相近（CV<0.2）→ 非单点硬件故障
-- 结合 Step 3 算法证据 → P2-SW（软件配置缺陷）
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 全局通信退化 CV | <0.2 | 所有 rank 等幅（配置问题） |
| 特定 size 带宽降幅 | >30% | 算法选择不当 |
| 带宽-size 曲线断点 | 存在 | 阈值边界 |
| 算法名变化 | tree→ring 等 | 软件层证据 |
| 硬件端口统计 | 正常 | 排除 P2-HW |

### 2.4 预期定位路径

```
L0(全局 step_time +53%, CV低) → L2(非单 rank, 所有 rank 等幅慢)
→ L3(msg>256KB: bw 81→38 GB/s, algo=ring←tree) → L4(P2-SW: 算法切换阈值不当)
```

### 2.5 预期 D-level
**D4-D5**（定位到 P2-SW + 具体算法/阈值配置；若能指出修复方法则 D5）。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 全局通信变慢（所有 rank） |
| 预期能到 D 几 | **D2-D3**（能发现通信变慢、判断是全局问题，但无 message size 分桶/算法名信息） |
| 结构性瓶颈 | Greyhound hook 的是 collective 整体 duration，无法按 msg_size 分桶；不知道走的是什么算法。看到"全局慢"但不知道为什么 |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 全局 step timing 变慢 |
| 预期能到 D 几 | **D1**（全局等幅变慢时 S 指标可能不触发——S = mean(nodelay)/mean(noblk) 在等幅退化下接近 1） |
| 结构性瓶颈 | straggler 检测器在"全局退化"场景下结构性失灵（没有 straggler） |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 升高 |
| 预期能到 D 几 | **D1-D2**（能发现慢了，但不知道为什么） |
| 结构性瓶颈 | 无算法选择/msg_size 视角 |

---

## 4. 执行检查清单

- [ ] 确认目标集群的 NCCL 默认算法阈值
- [ ] 验证 `NCCL_ALGO=Ring` 或 `NCCL_TREE_THRESHOLD=0` 确实强制切换算法
- [ ] 验证 Loud 档带宽降幅（预期 >40%）
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
| large msg bw (GB/s) | | | | 预期 81→38 |
| algorithm used | | | | tree→ring |

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
