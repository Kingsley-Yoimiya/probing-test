# Greyhound · Ascend 适配笔记

> 更新：2026-07-25 12:14（UTC+8）  
> 开源真相：`project/reading-paper/papers/fail-slow-opensource-study-2026-07/vendors/Greyhound/`  
> 平台脚本：`project/probing-test/scripts/fail-slow/platform/ascend/greyhound/`

## 1. 里程碑（本轮）

| 阶段 | 状态 | 证据 |
|------|------|------|
| S0_ENV | ✅ | g++/gcc、torch_npu、libhccl 可见；worker-1 IDLE |
| S1_LOAD | ✅ | 16 卡 `smoke_allreduce` + LD_PRELOAD 不炸；marker 写入 |
| S2_COLLECT | ✅ | `hcclprobe.collect.jsonl` **336** 行（16×20 AllReduce + 少量其它） |
| S3_RULE | ✅ | Redis :16379 + ACF + **Rbeast `find_performance_drop`**（oracle 合成窗检出 1 变点） |
| S4_DETECT | ✅ | P3 no_bite；**P1-EXT-A Rbeast 自主检出** |

S2：`yjr-as-b-gh-20260724_232223`  
S3（ACF only）：`yjr-as-b-gh-s3-20260724_235443`  
S3（Rbeast）：`yjr-as-b-gh-s3-rbeast-20260725_000302` — `n_changepoints=1` id=41；`global_controller=S3_ANALYZE_OK`  
S4：`yjr-as-b-gh-s4-20260725_002805` — coll=1.058；Rbeast n_cp=0；step_ms 窗比=**1.94**（Case 1.97）；stress held_s=43  
对照 P3：`contrast-p3-ext-a-20260725_114502` — period=**8**；coll=1.048；Rbeast 0/0；step_ms=**1.922**；detect_ok=no  
对照 P1：`contrast-p1-ext-a-20260725_120526` — INLINE 8192×64；coll=1.018 FAIL；Rbeast **C1=2/C0=0 hit**；step_ms=**3.924** dose_OK；detect_ok=**yes** / autonomous；脚本 `contrast_p1exta.sh`  
落盘：`/data/yinjinrun.p-huawei/...` + 本机回拉（**未**写 `/data/yysong`）

## 2. 它实际做什么（以代码为准）

| 层 | 机制 |
|----|------|
| 采集 | `LD_PRELOAD` 拦截 CCL 原语时间戳（开源=NCCL；本适配=`Hccl*`） |
| 控制面 | Rank0 Redis + cpp_redis（**本轮未部署**） |
| 触发 | magic broadcast count=503 int8（未接） |
| 检测 | ACF → Rbeast 变点 → GEMM/P2P（未接） |

本轮 **collect-min**：只做 Hccl* 计时 JSONL，**不改** 1.2× / <10% 等判据。

> **2026-07-25 公平性升级（ACF 喂真实序列）**：原 `run_s3_analyze.py` / `s4_verdict.py`
> 把 16 rank 事件混排、call_id 写成常量 0 或人造 `i%4`——ACF 量不出真实周期，等于没给
> Greyhound 它论文里的输入。已改为共享 `collect_seq.py`：**按 pid 分 rank**、`(op,count)`
> 签名→稳定 call_id、真实 t0→call_time，选事件最多 rank 逐条喂 `find_period`+
> `find_performance_drop`。本机验证（近似 ACF）：真实序列 **period≈8**（acf 0.97，匹配观测到的
> `8,8,8,8,8,9,4,7` 循环），C0 折叠 iter 时长平（tail/base=0.998）、C1 抬升（0.812）——
> Greyhound 自己的算法现在**看得到真实信号**。S4 另加 **C0 假阳性对照**：C1 报变点且 C0 不报
> 才算自主检出（两边都报=假阳性）。这是给对手它自己的最佳算法（rules §三·五A），不改其判据阈值。

## 3. 关键踩坑

1. **符号必须 C 链接名**：`g++` 无 `extern "C"` 会 mangle → `LD_DEBUG` 显示 `libtorch_npu` 绑到真 `libhccl.so`，dump 恒空。修复：`gcc` + `extern "C"`；`install_collect_min.sh` 校验 `nm -D | grep ' T HcclAllReduce$'`。  
2. **smoke 累乘**：同一 tensor 连续 AllReduce 会 `× world^iters`；已改为每 iter 重置。  
3. **AFS**：pod 内 `/afs-a3-weight-share` 不存在；可写 `/data/yinjinrun.p-huawei/`（自有前缀）+ 回拉本机。  
4. **Redis**：已自编译 `7.2.5` → `/data/yinjinrun.p-huawei/opt/redis/bin/`；`start_redis.sh` 起 **:16379**。  
5. **Rbeast aarch64**：官方 cp310 wheel 含 `U __builtin_readcyclecounter`（clang builtin，GCC 轮未内联）。修复：`libbuiltin_readcyclecounter.so`（`cntvct_el0`）经 `ctypes.RTLD_GLOBAL` / `LD_PRELOAD` 补齐；源文件 `builtin_readcyclecounter_stub.c`。已试失败项：裸 wheel ImportError；`--no-binary` 源码编卡在 build-isolation；错装 cp38 so。  
6. **勿 `import control_plane`**：其 `__init__` 拉 cvxpy；S3 用 `importlib` 直载 `slow_detection.py`。

## 4. 脚本

| 文件 | 作用 |
|------|------|
| `install_stub.sh` / `install_collect_min.sh` | S0–S2 |
| `start_redis.sh` | 自有前缀 Redis :16379 |
| `run_s3_analyze.py` | ACF(+Rbeast) → Redis 键；oracle 合成窗 |
| `collect_seq.py` | **真实 per-rank 序列还原**（按 pid 分 rank、(op,count)→call_id、真实 t0→call_time）；`run_s3_analyze` / `s4_verdict` 共用 |
| `smoke_allreduce.py` / `run_s1s2_worker1.sh` | 短训采集 |

```bash
bash start_redis.sh
PYTHONPATH=/data/yinjinrun.p-huawei/opt/pydeps \
  python3 run_s3_analyze.py --out /data/yinjinrun.p-huawei/results/.../s3
```

## 5. Redis 约定（已落地）

```text
REDIS_HOST=127.0.0.1  REDIS_PORT=16379
bin=/data/yinjinrun.p-huawei/opt/redis/bin
keys: global_controller / control_state / greyhound_s3_summary / failslow_ranks
落盘=yinjinrun.p-huawei；禁止写宋 AFS /data/yysong
```

## 6. S4 踩坑（已修）

1. warmup 勿 `grep step|STEP`（易空等至窗过完才开 stress → held 0s）。认 `warmup_done` / `step_100.marker`。  
2. `tbp_npu` **只**写 `step_100` / `step_300` marker（无 step_1）。  
3. verdict 须 conda `llm_test` + `PYTHONPATH=…/opt/pydeps` + cyclecounter stub，否则缺 matplotlib/Rbeast。  
4. 无效轮 `…001402`：stress 0s（窗竞态）；以 `…002805` 为准。

## 7. 下一步

- S4 能力边界已记（同 XPUTimer）：host CPU 抢占抬 step_ms，Greyhound CCL 路径无咬合；不焊 D4。
- **待 pod 重跑**：`s4_verdict.py` 已升级为真实序列 + C0 假阳性对照，但 `find_period`/
  `find_performance_drop` 依赖 pod 上的 `slow_detection.py`（本机无法跑）。下次上 worker-1
  重跑 `s4_p3exta_contrast.sh` 即可生成新 `S4_VERDICT.md`（含 rbeast_c0/c1、acf_period≈8）。
  本机备份的旧 `S4_VERDICT.md` 是升级前 pod 产物，保留不动。
