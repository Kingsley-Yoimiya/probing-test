# Case P2-SW-C：拓扑映射漂移

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（✅ 普通用户权限，改环境变量即可）。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P2-SW-C |
| Case 名称 | 拓扑映射漂移（topology mapping drift） |
| 27 格坐标 | 位置: P2 互联 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | ✅ 普通训练用户（改环境变量/拓扑文件） |

---

## 1. 注入方案

### 1.1 故障机制
环境变量或 rank→device 映射漂移（如 `CUDA_VISIBLE_DEVICES` / 亲和性设置错误），导致通信走非最优拓扑路径——初始化快照与实际转发不一致。某些 rank-pair 的通信绕远路，实测带宽低于拓扑期望。真实场景：容器重启后环境变量未恢复、调度器重新分配 GPU 但未通知通信库、手动改拓扑文件后未重启。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 环境变量/拓扑文件修改 |
| 启动方式 | 训练中途（step 150）修改拓扑文件或 rank-mapping 配置，触发部分通信走非最优路径 |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P2-SW-C/` |
| 依赖 | 无额外依赖；需能修改 NCCL 拓扑文件或亲和性配置 |

**注入器核心逻辑**：修改 `NCCL_TOPO_FILE` 或通信库的 rank→NIC 映射，使部分 rank-pair 的通信经过非最优路径（如跨 NUMA、跨 switch、绕远路）。可通过在 step 150 修改进程的亲和性或写入错误拓扑文件触发。

### 1.3 剂量三档

| 档位 | 具体参数 | 预期效果（step_time 变化） |
|---|---|---|
| **Loud** | 全部 rank 映射打乱（随机 shuffle） | step_time +50%~100%（所有通信绕远） |
| **Quiet** | 部分 rank-pair 映射错误（2/8 rank 绕远） | step_time +15%~30% |
| **Masked** | 单个 rank 映射偏移（跨 NUMA 但同机） | step_time +3%~8% |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 预热 | 无需预热 | |
| 注入触发时机 | step 150（修改拓扑文件/亲和性） | |
| 注入持续时长 | 200 步 | |
| 特殊时序 | 无（一旦映射改变，持续影响） | |
| 注意事项 | 需确认修改生效（某些通信库只在初始化时读拓扑，中途改可能无效→此时需在 step 150 重新初始化 process group） | |

### 1.5 Ground-truth 记录

```yaml
case_id: "P2-SW-C"
target_rank: [2, 5]           # 映射被打乱的 rank
target_host: "worker-82"
original_mapping: "rank2→GPU2, rank5→GPU5"
drifted_mapping: "rank2→GPU5, rank5→GPU2"  # 交换了映射
affected_pairs: ["(2,5)", "(2,3)", "(5,6)"]
t_on_step: 150
t_off_step: 350
intensity: "rank_swap_2_5"
dose: "quiet"
seed: 42
injector_commit: "abc1234"
timestamp: "2026-07-24T14:30:22+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
拓扑映射漂移的特征：**某些 rank-pair 通信带宽低于拓扑期望**，而其他 pair 正常。且受影响的 pair 有拓扑关系（绕远路的对）。

核心检测路径：
- L0: step_time 变慢
- L2: 不是所有通信都慢，而是**特定 rank-pair** 的通信慢
- L3: `nccl.coll_perf` 中 rank-pair 带宽矩阵偏离拓扑期望 + 初始化拓扑日志 vs 实际路径不一致
- L4: 拓扑期望离群 + 无硬件异常 → P2-SW（软件拓扑映射错误）

**关键信号**：
- rank-pair 带宽矩阵中离群对的分布与拓扑结构匹配
- `recv_wait_ns` 在特定 pair 方向高

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 通信有异常
SELECT rank,
       avg(duration_ms) as avg_comm_ms
FROM python.comm_collective
WHERE step BETWEEN 150 AND 350
GROUP BY rank
ORDER BY avg_comm_ms DESC;
-- 判据: 某些 rank 通信明显慢

-- Step 2: 定位 —— rank-pair 带宽矩阵
SELECT src_rank, dst_rank,
       avg(algo_bw_gbps) as pair_bw
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
GROUP BY src_rank, dst_rank
ORDER BY pair_bw ASC;
-- 判据: 特定 pair 带宽显著低于同拓扑位置的期望
-- 如 (2,5) bw=20GB/s 而同机其他 pair=200GB/s → 绕远路

-- Step 3: 归因 —— 对比拓扑期望
SELECT src_rank, dst_rank,
       avg(algo_bw_gbps) as measured_bw,
       expected_bw_from_topo(src_rank, dst_rank) as expected_bw,
       measured_bw / expected_bw as ratio
FROM nccl.coll_perf
WHERE step BETWEEN 150 AND 350
GROUP BY src_rank, dst_rank
HAVING ratio < 0.5;
-- 判据: measured/expected < 0.5 的 pair → 拓扑映射问题
-- 这些 pair 的拓扑关系（如"本应同 NVSwitch 但实际跨机"）

-- Step 4: 确认 —— 排除硬件（只有特定 pair 受影响、硬件正常）
SELECT rank, port,
       sum(symbol_error_delta) as sym_err
FROM rdma.mlx_hca
WHERE step BETWEEN 150 AND 350
GROUP BY rank, port
HAVING sym_err > 0;
-- 判据: 无硬件错误 → 排除 P2-HW
-- 特定 pair 低 + 硬件正常 + 拓扑期望偏离 → P2-SW(拓扑映射)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 特定 pair 带宽/期望 | <0.5 | 显著绕远路 |
| 受影响 pair 数量 | <总 pair 50% | 非全局（区别于 5B） |
| 硬件端口统计 | 正常 | 排除 P2-HW |
| 受影响 pair 的拓扑关系 | 可解释 | 映射错误可追溯 |

### 2.4 预期定位路径

```
L0(step_time +25%) → L2(rank 2,5 通信慢)
→ L3(pair(2,5) bw=20GB/s vs expected 200GB/s, 其他 pair 正常) → L4(P2-SW: 拓扑映射漂移)
```

### 2.5 预期 D-level
**D4-D5**（定位到 P2-SW + 具体错误映射；若能指出正确映射则 D5）。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD + magic broadcast count=503 |
| 该 case 能用的判据 | 变点检测 + 通信变慢的 rank |
| 预期能到 D 几 | **D2-D3**（能发现通信变慢、定位到哪些 rank 受影响） |
| 结构性瓶颈 | 无 rank-pair 粒度的带宽矩阵；无拓扑期望对比；看到"rank X 慢"但不知道是"pair(X,Y) 绕远路" |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 trace parquet |
| 该 case 能用的判据 | 受影响 rank 的 step timing 异常 |
| 预期能到 D 几 | **D2**（能指出谁慢） |
| 结构性瓶颈 | 无通信 pair 级分解 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 通信 duration 异常 |
| 预期能到 D 几 | **D1-D2** |
| 结构性瓶颈 | 无拓扑感知 |

---

## 4. 执行检查清单

- [ ] 确认目标环境中修改 NCCL_TOPO_FILE / 亲和性能即时生效
- [ ] 验证 Loud 档打乱映射后带宽确实下降
- [ ] 确认修改后训练不 hang（通信仍能完成）
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
| B (injection) | 42 | | quiet | | |
| C (Probing) | 42 | | quiet | | |
| D (Greyhound) | 42 | | quiet | | |

### 5.2 注入生效性验证

| 指标 | A 线 | B 线 | 差异 | 结论 |
|---|---|---|---|---|
| step_time mean (ms) | | | | |
| affected pair bw (GB/s) | | | | |
| unaffected pair bw (GB/s) | | | | 应不变 |

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
