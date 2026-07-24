# Case P1-SW-C：首次编译 one-shot 尖刺

> 基于模板 `TEMPLATE.md`。本 case 属第二梯队（普通用户，自有 cache 目录 + 数据 shape）。  
> **核心价值**：证明统计方法（变点检测、滑动窗口、均值比较）对单样本事件存在**结构性盲区**。

---

## 0. Case 基本信息

| 字段 | 值 |
|---|---|
| Case ID | P1-SW-C |
| Case 名称 | 首次编译 one-shot 尖刺（First Compilation One-Shot Spike） |
| 27 格坐标 | 位置: P1 芯片 × 来源: SW 软件缺陷 |
| 梯队 | 第二梯队 |
| 权限要求 | 普通用户（自有 cache 目录 + 数据 shape） |

---

## 1. 注入方案

### 1.1 故障机制
首次遇到未缓存的 shape/layout 时，runtime 编译阻塞一或多个 microbatch，cache 命中后恢复正常。**同一实例永不再发生**——这直接违反统计推断的"重复观测"前提。真实场景：PyTorch 2.x `torch.compile` 在 dynamic shapes 下首次遇到新 guard 时触发重编译；MACA runtime 对新 kernel config 的 JIT 编译；TensorRT 首次推理阶段的 engine 构建。

### 1.2 注入方法

| 项 | 说明 |
|---|---|
| 注入器类型 | 隔离 cache 目录 + 在指定 step 喂入未见 shape |
| 启动方式 | 训练脚本启动时设置 `TORCHINDUCTOR_CACHE_DIR` 到专用空目录；在 step 150 通过 dataloader hook 注入一次异常 shape |
| 注入脚本路径 | `project/lab-workspace/scripts/injection/P1-SW-C/oneshot_compile_inject.py` |
| 依赖 | PyTorch 2.x + `torch.compile(dynamic=True)`；或 MACA JIT 编译路径 |

**注入器核心逻辑**：
1. 训练启动前清空/隔离 inductor cache 目录（`TORCHINDUCTOR_CACHE_DIR=/tmp/isolated_cache_<run_id>`），确保 step 150 的新 shape 无缓存命中
2. Step 0-149 使用固定 shape（如 seq_len=128），让 cache 充分 warm up 该 shape
3. Step 150 精确注入一次异常 shape（如 seq_len=173），触发**完整重编译**
4. Step 151+ 恢复 seq_len=128，cache 命中，速度恢复正常
- **重要**：只清自有隔离 cache，绝不删共享用户 cache

### 1.3 剂量三档

| 档位 | 编译范围 | 预期 step_time 变化 | 说明 |
|---|---|---|---|
| **Loud** | 全模型重编译（清空所有 inductor cache） | 单步 30-60s（正常 ~100ms），spike 300x-600x | 所有 layer 的 kernel 需重新编译 |
| **Quiet** | 单 layer 重编译（仅删目标 layer 的 cache） | 单步 3-5s，spike 30x-50x | 仅一个 transformer block 重编译 |
| **Masked** | 单 op 重编译（仅删一个 op 的 cache entry） | 单步 0.5-1s，spike 5x-10x | 单个 attention/matmul op 重编译 |

### 1.4 注入时序

| 参数 | 值 | 备注 |
|---|---|---|
| 注入触发时机 | step 150（精确单步） | warmup 50 步后正常 100 步再触发 |
| 注入持续时长 | **1 步**（one-shot） | 这是本 case 的本质特征 |
| 注入模式 | 单次尖刺，前后完全正常 | 根本区别于所有其他 case |
| 特殊时序 | step 150 单步 spike → step 151 立即恢复 | 无持续、无渐进、无周期 |
| 注意事项 | 必须确认 step 151 已恢复正常（cache 已建立），否则是 cache 机制异常而非注入 |

### 1.5 Ground-truth 记录

```yaml
case_id: "P1-SW-C"
target_rank: 0               # 所有 rank 同时触发（数据层注入同一 shape）
target_host: "worker-all"
target_gpu: "all"
t_on_step: 150
t_off_step: 150              # 单步！ on=off
intensity: "full_model_recompile"
dose: "loud"
seed: 42
injector_commit: "TBD"
injection_pattern: "one_shot"
trigger_shape: [173]         # 触发编译的异常序列长度
normal_shape: 128
cache_dir: "/tmp/isolated_cache_<run_id>"
cache_state_at_trigger: "warm_for_128_only"
timestamp: "2026-07-23T00:00:00+08:00"
```

---

## 2. 检测方案（Probing 侧）

### 2.1 检测思路
One-shot 编译尖刺的核心特征：**单个极端 outlier**（一个点，非持续），且伴随编译事件标记。统计方法（changepoint、滑动窗口）结构性失效——它们需要多个样本来建立置信度。Probing 的优势在于 per-op trace + 编译事件标记，可以精确定位：
- L0: step_time 序列中找单点极端 outlier（不是均值偏移，不是趋势，就是一个尖刺）
- L2: 确认哪些 rank 出现尖刺（本 case 预期全体 rank 同步）
- L3: 在尖刺 step 检查编译事件——`python.torch_trace` 中寻找异常长的单个 op，辨识编译相关 marker（如 `torch._inductor.compile`、`triton.compile`）。关键验证：**同一 shape 第二次出现时尖刺消失**
- L4: 确认 P1-SW（编译/cache 问题，芯片软件层）

**关键信号**：step 150 的 `python.torch_trace` 中出现超长 op（duration 比同名 op 正常值大 100x+），且 op 名称包含编译相关关键字。

### 2.2 检测 SQL 序列

```sql
-- Step 1: 分诊 —— 寻找单点极端 outlier
SELECT step,
       rank,
       duration_ms
FROM python.torch_trace
WHERE step BETWEEN 100 AND 200
  AND phase = 'step'
ORDER BY duration_ms DESC
LIMIT 10;
-- 判据: 存在单个 step 的 duration >> 其余所有 step (ratio ≥ 10x)
-- 且该 step 前后的 step 完全正常 (step 149 正常, step 151 正常)

-- Step 2: 定位 —— 确认尖刺范围
SELECT rank,
       step,
       duration_ms
FROM python.torch_trace
WHERE step IN (149, 150, 151)
  AND phase = 'step'
ORDER BY rank, step;
-- 判据: step 150 所有 rank 同步尖刺, step 149/151 正常
-- → 全局数据层触发（排除单点硬件故障）

-- Step 3: 归因 —— 尖刺 step 内的 op 分解,找编译事件
SELECT name as op_name,
       duration_us,
       duration_us / 1000.0 as duration_ms
FROM python.torch_trace
WHERE step = 150
  AND rank = 0
  AND phase = 'kernel'
ORDER BY duration_us DESC
LIMIT 20;
-- 判据: 存在 op duration >> 正常值 (100x+)
-- 且 op 名称包含编译相关关键字 (compile/inductor/triton/autotune)
-- 或同名 op 在 step 151 的 duration 回到正常水平

-- Step 4: 确认 —— 对比同一 op 在尖刺步 vs 后续步
SELECT step,
       name as op_name,
       avg(duration_us) as avg_us
FROM python.torch_trace
WHERE step IN (150, 151, 152)
  AND rank = 0
  AND name = '<suspect_op>'
GROUP BY step, name
ORDER BY step;
-- 如果 step 150 的 op 时间 >> step 151/152
-- 且 step 151/152 回到正常 → cache 命中后恢复
-- → 确认: 首次编译 one-shot 尖刺 → P1-SW (芯片×软件缺陷)
```

### 2.3 判据与阈值

| 判据 | 阈值 | 说明 |
|---|---|---|
| 单点 spike ratio (spike_ms / median_ms) | ≥10x（Masked）; ≥30x（Quiet）; ≥300x（Loud） | 确认是极端 outlier |
| spike 前后 step 正常 | step ±1 的 duration 在正常范围内 | 确认是 one-shot |
| 编译相关 op 存在 | duration 100x+ 于同名 op 正常值 | 确认编译事件 |
| 同 shape 第二次正常 | spike step op duration >> 后续同 op | 确认 cache 命中恢复 |
| 通信时间无异常 | comm duration 正常 | 排除网络触发 |

### 2.4 预期定位路径

```
L0(step 150 spike=35s, ratio=350x, 单点) → L2(全体 rank 同步, 全局触发)
→ L3(torch._inductor.compile duration=30s, 正常<1ms; step 151 恢复) → L4(P1-SW: 芯片×软件,编译 cache 未命中)
```

### 2.5 预期 D-level
**D4**（定位到 P1-SW: 编译 cache miss + one-shot 恢复模式）。本 case 核心价值不在 D-level 高低，而在**证明统计方法对 one-shot 事件结构性失效**。

---

## 3. 对手检测方案

### 3.1 Greyhound

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD，训练每步插入 magic broadcast(count=503) |
| 该 case 能用的判据 | 变点检测(Rbeast)；但变点检测需多个样本建立置信度 |
| 预期能到 D 几 | **D0-D1**：Loud 档单步 spike 够大可能被看到（一个点偏移窗口均值），但 changepoint 算法需要"变化持续"才能判定，单点 spike 不构成 changepoint；归因不可能 |
| 结构性瓶颈 | **根本盲区**：changepoint detection 的前提是"变化后维持新水平"——one-shot spike 违反此前提。即使检测到异常点也无法归因（无编译事件信息） |

### 3.2 StragglerAnalysis

| 项 | 说明 |
|---|---|
| 接入方式 | 离线，喂 B run 的 step timing parquet |
| 该 case 能用的判据 | 均值比较 S = mean(nodelay)/mean(noblk) |
| 预期能到 D 几 | **D0**（结构性失效）：单步 spike 对 350 步的均值贡献极小（Loud: +35s/350步 ≈ +100ms/step ≈ 均值偏移 ~100%，可能 D1；Masked: +0.5s/350步 ≈ +1.4ms → 噪声内 → D0） |
| 结构性瓶颈 | **根本盲区**：基于均值的统计量将单点事件稀释到噪声水平；"重复观测"前提被违反 |

### 3.3 XPUTimer

| 项 | 说明 |
|---|---|
| 接入方式 | LD_PRELOAD |
| 该 case 能用的判据 | 常驻信号（step duration 中看到一个尖刺） |
| 预期能到 D 几 | **D0-D1**（能看到 spike 信号，但无法归因） |
| 结构性瓶颈 | 有信号无诊断；对"为什么这一步慢"没有任何答案；单点事件无统计支撑 |

---

## 4. 执行检查清单

- [ ] 隔离 cache 目录方案验证：确认 `TORCHINDUCTOR_CACHE_DIR` 生效，step 150 触发编译
- [ ] 验证 step 151 恢复正常（cache 已建好），spike 确实是 one-shot
- [ ] Loud 档 spike 幅度确认：单步 30-60s（300x+）
- [ ] Masked 档 spike 幅度确认：单步 0.5-1s（5-10x），仍可在 trace 中检出
- [ ] 训练配置确认：GPT-2 124M / 500 steps / warmup 50 / seed 42
- [ ] Probing 配置：PROBING=2, PROBING_TORCH_PROFILING=on:rate=1.0
- [ ] Ground-truth 记录器写到 injection/ground_truth.yaml
- [ ] Probing SQL 在 Loud 档验证：能定位 spike step + 识别编译 op
- [ ] 确认不会误删共享 cache（只操作隔离目录）
- [ ] Greyhound 在 Loud 档验证：是否能检测到 spike（预期最多 D1）

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
| step 150 duration (ms) | | | | spike 倍率 |
| step 151 duration (ms) | | | | 恢复确认 |
| 编译事件 marker 存在 | — | | | 编译触发确认 |

### 5.3 检测能力结果

| 工具 | D-level | 触发 step | 定位对象 | 27 格坐标 | 关键证据 |
|---|---|---|---|---|---|
| Probing | | | | | |
| Greyhound | | | | | |
| StragglerAnalysis | | | | | |
| XPUTimer | | | | | |

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
