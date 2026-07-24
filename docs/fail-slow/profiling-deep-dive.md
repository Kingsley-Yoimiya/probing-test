# Probing Profiling 全面调研:配置、机制与最新 diff

> 目的:把 Probing(`DeepLink-org/probing`)的 profiling 子系统讲透——它**什么时候开/不开**、暴露给用户**哪些配置**、**SQL 怎么查、查的时候有什么优化**、以及各模块用了哪些**工程 trick**;最后精读一遍 upstream 最新 8 个 commit 干了什么。
>
> 调研基准:upstream `master @ 95c4ad8`(2026-07-19),只读 checkout 在 `/tmp/probing-upstream`;本地 pin 在 `0275cb1`(2026-07-09)。
> 落点仓:`project/lab-workspace/projects/probing`(CUDA 主线)/ `Probing_plus`(沐曦+Ascend 适配分支)。
> 方法:8 路子代理分头读全文件 + 精读 diff,结论互相印证。文中 `file:line` 均指 `/tmp/probing-upstream` 下路径。

---

## 0. 先建立心智模型:一句话总览

Probing 的核心哲学:**训练热路径上只做 O(1) 内存操作,一切序列化 / IO / 符号化 / 解析全部推迟到后台线程或 SQL 查询时**。围绕这一条,它做了三件事:

1. **采集**:用采样(而非全量 tracing)+ 环形缓冲 + 异步落盘,把常态开销压到可测、可控。
2. **存储**:自研列式 memtable(热环形 + 冷压缩段),mmap 暴露给 SQL,DataFusion 做查询引擎。
3. **暴露**:所有遥测都是**可 SQL 查询的关系表**,agent 用 `SELECT`/`JOIN` 消费,而不是给人看火焰图。

> **最重要的一个澄清**:Probing 里有**两套完全不同的 "Torch Profiler"**,不要混淆(第 2、3 节展开):
> - **TorchProbe**(常驻、模块级、采样式)——`PROBING_TORCH_PROFILING` 开关,写 `python.torch_trace` + `python.torch_step_timing`。
> - **Torch Profiler SQL**(按需、短窗、包 `torch.profiler.profile()`)——HTTP/REPL/skill 触发,写 `python.profile_capture` + `python.profile_hotspot`。

---

## 1. 配置全景:什么时候开、怎么开

### 1.1 总开关与激活模型

- **Probing 本体**:通过 `PROBING=1`(或注入)在目标进程内加载;`PROBING_ORIGINAL` 决定是否在子进程中跟随激活(支持 `regex:` 按脚本名匹配)。
- **各子系统默认状态**(这是"什么能开不开"的核心表):

| 子系统 | 默认 | 开关 | 激活方式 |
|---|---|---|---|
| CPU 利用率采样 | **默认开**(1s) | `PROBING_CPU`, `PROBING_CPU_SAMPLE_MS` | 后台线程,启动即采 |
| GPU 利用率采样 | **auto**(检测到后端就开,1s) | `PROBING_GPU`, `PROBING_GPU_SAMPLE_MS` | 后台线程 |
| pprof CPU 栈采样 | 需触发 | `probing.pprof.sample_freq`(默认 100Hz) | SIGPROF / 协作式 |
| **TorchProbe**(模块级) | **默认关**,opt-in | `PROBING_TORCH_PROFILING=on` | 首次 `optimizer.step()` 时装 hook |
| **Torch Profiler SQL** | **默认关**,纯按需 | 无 env,靠 API/REPL/skill | 显式 `start(steps=N)` |
| 训练 phase 追踪 | 默认开(TorchProbe 激活时) | `probing.torch.phases` | forward/step hook 自动挂 |
| NCCL profiler | 需挂插件 | `NCCL_PROFILER_PLUGIN=...` | NCCL 原生插件 API |
| Crash 捕获 | **默认开** | `PROBING_CRASH` | excepthook + 信号 |
| 冷存储压缩 | **默认关**(避免 fork worker 里起线程) | `PROBING_COLD` | 引擎初始化时 |

**关键结论**:两套 torch profiler 都**不是常态自动运行**的。TorchProbe 要显式 `PROBING_TORCH_PROFILING=on`,且即便开了也**采样**(默认只采 5% 的 step);Torch Profiler SQL 完全靠 agent/人显式触发,跑 N 个 step 就停。这是它敢宣称"低开销"的前提。

### 1.2 运行时可否热开关

**可以,且不用重启训练**:
- TorchProbe:`probing.profiling.torch_probe.configure("on,rate=0.5")` 把 spec 写进 Rust 侧持久配置,再通过 `gc.get_objects()` 找到所有活的 tracer 实例**原地改参数**(rate/layer_rate/backward/adaptive/shadow 节奏),下一个 step 生效。
- 采样率 / 冷存储 / RDMA 采样率等也可通过 SQL `SET` 命令改。

---

## 2. TorchProbe:常驻、模块级、采样式(第一套)

**文件**:`python/probing/profiling/torch_probe.py`(1678 行,核心)、`python/probing/tracing/hooks.py`(phase)。

### 2.1 生命周期

1. `PROBING_TORCH_PROFILING` 非空 → 注册全局 `register_optimizer_step_post_hook`。
2. **首次** `optimizer.step()` 触发 → 解析 spec → 建 `TorchProbe` → 给所有顶层 module 装 `forward_pre/forward` hook,给 optimizer 装 `step_pre/step_post` hook。
3. 首个完整 step 只做**模块发现**(登记名字),不写数据;之后才开始采样。

### 2.2 配置语法(`PROBING_TORCH_PROFILING` 的 spec 文法)

```
on/off[, rate=0.05][, layer_rate=1.0][, backward=on][, sync=on]
      [, tracepy=on][, exprs=loss@step][, shadow=4:1][, adaptive=on]
```

也可写紧凑形式 `mode:rate:layer_rate`。**全部字段与默认值**:

| 字段 | 默认 | 含义 |
|---|---|---|
| `enabled` | `False` | 总开关 |
| `rate` | **0.05** | step 级采样率(5%),决定哪些 step 走"重路径" |
| `layer_rate` | **1.0** | 在被采 step 内,每个 module 再按此概率命中 |
| `backward` | `False` | 是否测反向(用 tensor hook,不用 module backward hook) |
| `sync` | `False` | 每个 hook 处是否 `cuda.synchronize()`(精确但贵) |
| `tracepy` | `False` | 是否追 Python 调用 |
| `trace_spans` | `True` | 是否写 trace_event span |
| `exprs` | `""` | 变量追踪,如 `loss@step` |
| `shadow_normal:shadow_baseline` | **4:1** | 影子步节奏(见 overhead 节) |
| `adaptive_rate` | `False` | 是否开自适应率控制器 |

### 2.3 采样机制:确定性、无种子、跨 rank 对齐

- **分层步采样**:周期 = `round(1/rate)`,当 `step_cycle % period == 0` 时采。**纯由 step 序号决定,不用 RNG**——所以**所有 rank 采同样的 step**,保证分布式 trace 对齐、训练可复现。
- **逐层采样**:被采 step 内,每个 module 用 `blake2b(step, module_name)` 生成 [0,1) 确定性浮点,`< layer_rate` 才记录。首个 hook(offset-0 锚点)永远记。
- **异步 GPU event 不阻塞**:采样 step 上的 GPU 计时用 event 对,**不当场 `synchronize()`**,而是丢进延迟队列后台读(见 2.5)。

### 2.4 自适应率控制器(闭环反压)

`_AdaptiveRateController`(`torch_probe.py:67-121`),这是 overhead 控制的执行器:

| 参数 | env | 默认 |
|---|---|---|
| 开关 | `PROBING_TORCH_ADAPTIVE_RATE` | 关 |
| 目标 overhead | `PROBING_TORCH_OVERHEAD_TARGET_PCT` | **5.0%** |
| 高水位 | `PROBING_TORCH_OVERHEAD_HIGH_PCT` | **10.0%** |
| 率下限 | `PROBING_TORCH_RATE_FLOOR` | **0.01**(1%) |

控制律(仅在**影子步**触发,80 步滚动窗):
- overhead > 10% → **率减半**(clamp 到下限)。
- overhead < 5% 且当前 < 初始率 → **率 ×1.25**(涨回,不超初始)。
- 5%~10% 死区不动 → **迟滞防振荡**;"快刹车、慢恢复";率**永不低于 1%**(保底可观测性)。

### 2.5 延迟异步落盘(deferred drain)

**文件**:`python/probing/profiling/deferred_drain.py`。
- 热路径只 `put_nowait(DrainTask)` 进有界队列(`PROBING_TORCH_DEFER_QUEUE_SIZE=4096`),后台 daemon 线程做 `elapsed_time()` + `save()`。
- `PROBING_TORCH_DEFER_ASYNC=1`(默认开)。
- **队列满 → 降级为同步 save,不丢数据**(QoS 降级而非 drop)。`atexit` flush。
- **不变量**:`_record_step_timing()` 必须在 `_drain_deferred()` **之前**(否则前几步的 GPU event 补读会被算进当前 step 墙钟,污染 overhead 测量)。

### 2.6 产出的表

- `python.torch_trace`:模块级 trace(stage/module/duration/memory)。
- `python.torch_step_timing`:每步一行,带 `is_shadow`/`sampled`/`shadow_normal`/`shadow_baseline`/`sample_rate`/`step_duration_sec`——**这是 overhead 计算的数据源**。

---

## 3. Torch Profiler SQL:按需、短窗、结论化(第二套,新特性)

**新特性**(commit `c3f6723`)。文件:`torch_profiler/{controller,adaptor,sql,session_store}.py` + Rust `profile_sql.rs`。

### 3.1 生命周期(严格按需,永不自动跑)

触发:HTTP `POST /apis/pythonext/pytorch/profile/start`、REPL `%pytorch profile steps=N`、MCP、skill(`kernel_bottleneck`)。
- `ProfilerController` 单例,包 `torch.profiler.profile()`,注册 optimizer post-step hook。
- **profiler 上下文不在 start() 时进入,而是第一个 optimizer step 才 `__enter__`**——保证抓的窗口对齐真实训练步。
- 每 step 调 `profiler.step()`;到 N 步 `_finalize_capture()`:退出、编译成 SQL 行、存 SessionStore。可随时提前 stop。

### 3.2 `torch.profiler.profile()` 的选项(全硬编码,当前不可配)

| 选项 | 值 |
|---|---|
| activities | CPU 恒开;CUDA 可用则加 |
| `record_shapes` | `True` |
| `with_stack` | `True`(→ 填 `module_hint`) |
| `with_flops` | `True` |
| `profile_memory` | 未开(默认 False) |
| `schedule` | **不用**——手动 `profiler.step()` 按 optimizer 步门控,不是 wait/warmup/active/repeat |

> 工程点:这里没有暴露 `schedule` 给用户,而是自己用 optimizer step 门控窗口。想改 activities/memory 目前得改代码。

### 3.3 从 Kineto 到 SQL 行(结论化,不给原始事件)

`adaptor.py::compile_key_averages()`:吃 `profiler.key_averages()`,按名字分桶 `bucket_kind`(`nccl→collective`、`memcpy`、`cuda*Sync/Launch/Malloc→cuda_runtime`、`aten::/autograd::→cpu_op`、其余 `kernel`),聚合 `self_us/wall_us/calls`,算 `pct_of_capture`,按 `self_us` 降序。
- **事件上限** `PROBING_TORCH_PROFILER_MAX_EVENTS=200000`(超了截断,置 `truncated=1`)。
- **会话上限** `PROBING_TORCH_PROFILER_MAX_SESSIONS=8`(FIFO 淘汰最老 capture 及其 hotspot 行)。

### 3.4 两张表

- **`python.profile_capture`**(一次 capture 一行,联邦 join 锚点):`capture_id, local_step, global_step, rank, world_size, role, trigger, steps_profiled, wall_us, started_at_us, ended_at_us, status(running|completed|failed), truncated, event_count, error`。
- **`python.profile_hotspot`**(结论事实表,一桶一行):`capture_id, local_step, global_step, rank, bucket_kind, bucket_name, self_us, wall_us, calls, pct_of_capture, module_hint`。
- 联邦镜像 `global.python.profile_*` 加 `_host/_addr/_rank/_role`。

### 3.5 懒/急物化 + Python/Rust 边界

- **finalize 时急聚合**(把 Kineto 事件一次性压成结论行,存进程内 SessionStore),**查询时懒服务**(SQL 命中才由 Rust 经 PyO3 调 Python 取行、转 Arrow RecordBatch)。
- **不落 memtable、不持久化**、无谓词下推(数据量小,聚合后每 capture 几百到几千行,靠 `MAX_SESSIONS=8` 兜底)。
- **Python 侧**负责解析/聚合/存储(因为 profiler 对象是 Python 对象);**Rust 侧**只定 Arrow schema + 转换(schema 作为 SSOT,查询规划不用 introspect Python)。

### 3.6 典型查询(文档 Q1–Q8)

```sql
-- Q1 某次 capture 的 GPU 热点
SELECT bucket_name, bucket_kind, self_us, pct_of_capture, calls
FROM python.profile_hotspot
WHERE capture_id = @cid AND bucket_kind IN ('kernel','cpu_op')
ORDER BY self_us DESC LIMIT 20;

-- Q3 跨 rank 慢核对比(联邦 + 中位数)
WITH per_rank AS (
  SELECT _rank, bucket_name, sum(self_us) us FROM global.python.profile_hotspot
  WHERE local_step=@s AND bucket_kind='kernel' GROUP BY _rank, bucket_name),
median AS (SELECT bucket_name, median(us) med FROM per_rank GROUP BY bucket_name)
SELECT p._rank, p.bucket_name, p.us-m.med delta FROM per_rank p
JOIN median m USING(bucket_name) WHERE p.us > m.med*1.2 ORDER BY delta DESC;

-- Q5 kernel 热点 join 回模块级 trace
SELECT t.module, h.bucket_name, h.self_us/1e3 kernel_ms
FROM python.torch_trace t
JOIN python.profile_capture c ON t.local_step=c.local_step
JOIN python.profile_hotspot h ON h.capture_id=c.capture_id
WHERE t.local_step=@s AND t.stage='post forward' ORDER BY t.duration DESC;
```

---

## 4. 数据层与 SQL 引擎:存储 + 查询优化

**文件**:`docs/src/design/data-layer.md`、`probing/memtable/`、`probing/core/src/core/memtable_sql.rs`、`engine.rs`。

### 4.1 存储模型:两层列式自研存储

- **热层 MEMT**:定容**环形缓冲**,64B header(冷区不变 / 热区原子改,避免 false sharing),chunk 带 `generation` 计数 + `min_ts/max_ts`。**单写者、无锁**,读者靠 Release/Acquire + generation 复检保证不读到撕裂行。可选**字符串去重**(chunk 内回引,省 >20%)。三种后端:heap / POSIX shm / **file mmap**(仅 mmap 版对 SQL 可见,Linux 默认 `/dev/shm/probing`)。
- **冷层 MEMC**:不可变、**Pco level-8 压缩**段(单调时间戳压 >4x),整文件淘汰。崩溃恢复:封口段读 footer O(1),未封口段前向扫描到首个坏 checksum 丢尾。

写吞吐(M4 release):无锁流式 ~29.9M rows/s(比加锁 +59%)。

### 4.2 查询引擎:DataFusion

- `Engine` 包 `SessionContext`,默认 catalog/schema=`probe`,开 `information_schema`。
- 插件以 `Namespace`(整 schema,可 `provide_catalog` 包裹整个 catalog 做动态发现)或 `Table` 注册。
- `DynamicMmapCatalog` + `MmapFileSchemaProvider`:查询时从 mmap 文件动态发现表(`acme.actors` → schema `acme` / table `actors`)。

### 4.3 查询优化(vs 朴素 "dump to sqlite")

1. **三级时间剪枝**(一个 SQL 时间谓词同时剪两层):段级(不 mmap 直接跳)→ 页级(页目录 ts 范围)→ chunk 级(chunk min/max ts + generation 复检)。
2. **谓词下推**:`supports_filters_pushdown` 把过滤推进 `scan()`,用于时间范围提取 + FilterExec。
3. **投影下推**:`scan()` 只物化查询用到的列。
4. **limit 下推**:够行即早停。
5. **懒物化**:`RingMmapTable` 延迟到 `scan()` 才 mmap + 剪枝 + 转 Arrow(不是注册时急拷)。
6. **零拷贝读**:mmap 只按需 fault 页;环形多数 chunk 可能没被触碰。
7. **热冷去重**:`cold_scan()` 返回已压缩的 `(chunk,gen)` 集,热侧排除之,每行恰好计一次。

| 维度 | Probing | SQLite 式 |
|---|---|---|
| 写路径 | mmap 环形零分配追加 | 行序列化 + WAL |
| 内存 | 有界环形 + 有界冷预算 | 无界增长 |
| 时间剪枝 | 三级结构化(段/页/chunk min-max ts) | B-tree 索引扫 |
| 并发 | 无锁读、单写 | WAL 读写锁 |
| 崩溃 | generation 复检 + 前向扫描 | WAL 回放 |

### 4.4 冷存储分层(`PROBING_COLD_*`)

`ColdCompactor` 进程级单例后台线程:重发现 ring 文件 → 抽干封口 chunk(转列、Pco 压)→ 写 MCPG 页 → 段到 `target_segment_bytes`(默认 64MiB)或 `max_age`(300s)滚动 → 按字节预算/TTL 删最老段。**跨重启 exactly-once**(`prime_from_cold()` 重建 watermark)。

| env | 含义 | 默认 |
|---|---|---|
| `PROBING_COLD` | 开压缩 | 关 |
| `PROBING_COLD_DIR` | 冷段目录 | `$DATA_DIR/<pid>/cold` |
| `PROBING_COLD_TARGET_MB` | 段滚动大小 | 64 |
| `PROBING_COLD_MAX_TOTAL_MB` | 冷存字节预算 | 无限 |
| `PROBING_COLD_TTL_SECS` | 冷段 TTL | 无 |
| `PROBING_COLD_POLL_MS` | 抽干轮询间隔 | 2000 |
| `PROBING_COLD_MAX_AGE_SECS` | 空闲段封口 | 300 |

### 4.5 结果 DataFrame 与联邦

- 线格式 `probing_proto::DataFrame`:**列式**(`Seq` 每列一个),内部用 Arrow RecordBatch 跑 DataFusion,**传输时转 Seq 列**(有拷贝,Arrow 只在引擎内)。
- 联邦:`global.schema.table` 路由到所有节点;`/apis/cluster/query` 扇出;**聚合下推**到各节点再合;`ensure_global_scan_limit` 限行,`federation_columns=[_host,_addr,_rank,_role]` 标识来源。

---

## 5. Overhead 度量与自适应控制(新子系统)

**文件**:`docs/src/design/overhead.md` + `overhead-invariants.md`;`web/src/overhead/{metrics.rs,sql.rs}`;`web/src/components/overhead/panel.rs`。

### 5.1 定义:影子步基线

```
overhead_pct = (median(probed_step) / median(shadow_step) - 1) * 100
```
- **影子步(shadow)**:hook 立即返回、不记录,但仍写 `is_shadow=1` 的 timing 行——**零开销基线**。默认节奏 4:1(4 探针步 + 1 影子步)。
- **采样步(sampled)**:走全量 module trace flush 的重路径。
- 分层指标:`dispatch_overhead_pct`(非采样探针 vs 影子,**主报警指标,噪声低**)/ `sampled_overhead_pct`(重路径)/ `amortized`(按率加权混合,UI 显示的"有效开销")。

### 5.2 六条不变量(测试强制,AGENTS.md 明令不许回归)

- **I1** 主指标用**中位数比**,禁止 `mean(probed)/mean(shadow)`(抖动下会从 ~2% 炸到 >300%,有真实回归案例)。
- **I2** amortized = `(1-rate)*dispatch + rate*sampled`,不是均值摊销。
- **I3** `_close_step_wall` 里 `_record_step_timing()` 必须在 `_drain_deferred()` 之前。
- **I4** deferred drain 默认异步。
- **I5** 稳定性门:`shadow_n≥5`、`dispatch_n≥16` 才算数。
- **I6** UI 软化:`|pct|<0.5%` 显示 `≈0%`,`<5%` 显示 `~N%`。

### 5.3 暴露的指标与 SQL

- 表:`python.torch_step_timing`(见 2.6)。
- overhead SQL(`web/src/overhead/sql.rs`):`WINDOW_STEPS=80` 滚动窗;`summary()` 出 dispatch/probed/sampled/shadow 各自中位数+均值+计数;`TRAIN_STEP_MEDIAN` join `trace_event` 的 `train.step` span 得纯计算基准;`recent_steps()` 出最近 24 步给时间线。
- Web 面板轮询 2000ms,单卡无 NCCL 表时优雅降级。
- `health_overview` skill:`dispatch_overhead_pct>5` 告警。

### 5.4 反压手段(唯一执行器 = 降采样率)

超阈值时:**自适应率减半**(第 2.4 节)→ 更少重路径步;deferred 队列满 → 同步兜底(不丢);率下限 1% 保底。**设计上不静默丢事件、不自动禁探针**——率是唯一 actuator,其余靠人配。CI 里 `soak_assert.py` 在 `hook_tax_pct>75%` 硬失败(构建门,非运行时)。

---

## 6. NCCL / HCCL Collective 观测

**文件**:`docs/src/design/nccl-profiler.md`;`probing/extensions/nccl-profiler/src/`;`python/probing/profiling/collective/`;`probing/extensions/hccl-shim/`。

### 6.1 挂钩机制:NCCL 原生 profiler 插件 API(非 LD_PRELOAD)

- 编译成 `libprobing_nccl_profiler.so`,导出 `ncclProfiler_v4`(NCCL≥2.27,有 GPU globaltimer / SendPeerWait / 每 comm 元数据)+ `ncclProfiler_v3`(2.26 回退)两个 vtable,NCCL 自己协商版本。
- 用户设 `NCCL_PROFILER_PLUGIN=$(python -m probing.nccl --plugin-path)` + `NCCL_PROFILE_EVENT_MASK=94`(默认 = Coll|P2P|ProxyOp|ProxyStep|KernelCh;bit128 NetPlugin/IB QP 是 opt-in)。

### 6.2 NCCL wait 分解

NCCL 的 `stopEvent` 只标 host enqueue 完成;插件用**引用计数子事件**重建真实执行时间:子事件(ProxyOp/KernelCh)start 时 `live_children++`,stop 时折叠时间窗并 `--`;coll 在 `stopped && live_children==0` 时完成。`exec_time_ns` 按信号质量优先级选:`kernel_gpu`(v4 device 时钟,最好)> `kernel_ch` > `proxy` > `enqueue`(回退)。ProxyStep 的 wait 按状态入场时间戳分解(Send 链:`SendGpuWait→SendPeerWait→SendWait`;Recv 链:`RecvWait→RecvFlushWait→RecvGpuWait`),**首次入场为准**。

### 6.3 结果表

- **`nccl.proxy_ops`**:每 proxy op 一行,关键列 `send_gpu_wait_ns`(**culprit 信号**:本地 GPU 没准备好)、`recv_wait_ns`(**victim 信号**:等对端)、`send_peer_wait_ns`(v4:等接收方 credit),含 `tp/pp/dp_rank`、`comm_hash`、`coll_func`、`trans_bytes`。
- **`nccl.coll_perf`**:每 collective 一行,`exec_time_ns`/`enqueue_time_ns`/`timing_source`/`algobw_gbps`/`algo`/`proto`/`msg_size_bytes`/`pool_events_dropped`(数据质量信号)。
- **`nccl.inflight_ops`**:看门狗周期快照 start 了没 stop 的 op(hang 信号),`age_ns`。
- **`nccl.net_qp`**:IB QP 完成计时(opt-in)。
- **`nccl.profiler_counters`**:健康自检(pool_exhausted / rows_written / ring 回收等 24 列)。

> 三个 collective 数据源勿混:NCCL 插件(`nccl.*`,原生重建时间)/ Torch-API tracer(`python.comm_collective`,Python 墙钟,带 `global_step`)/ PyTorch Flight Recorder 桥(`python.torch_nccl_flight_record`)。插件激活时 Torch-API tracer 默认关,避免时间冲突。

### 6.4 Slot-pool 架构(热路径零分配)

预分配定容 slot 池 + free-list 栈,O(1) alloc/free,slot 内嵌 packed 索引(handle 回调直接取索引不扫池):

| 池 | 默认容量 | env |
|---|---|---|
| coll | 512 | `PROBING_NCCL_MAX_COLL_SLOTS` |
| proxy_op | 8192 | `PROBING_NCCL_MAX_PROXY_OP_SLOTS` |
| proxy_step | 32768 | `PROBING_NCCL_MAX_PROXY_STEP_SLOTS` |
| kernel_ch | 8192 | `PROBING_NCCL_MAX_KERNEL_CH_SLOTS` |
| net | 4096 | `PROBING_NCCL_MAX_NET_SLOTS` |

- **分片** `PROBING_NCCL_POOL_SHARDS=8`(1–64):按 `comm_hash % shards` 分,每片独立 `parking_lot::Mutex`,降回调锁竞争。
- **耗尽**:限流告警(≤1/10s)+ `pool_exhausted++`,父 coll 记 `pool_events_dropped`,handle 置空(no-op,不崩)。

### 6.5 其他旋钮

- **环形缓冲**(非 NCCL 内部分块):`PROBING_NCCL_CHUNK_BYTES=65536` × `PROBING_NCCL_NUM_CHUNKS=64` = 每表 4MiB。
- **inflight 看门狗** `PROBING_NCCL_INFLIGHT_THRESHOLD_SECS=10`(0 关):后台线程 `try_lock` 各片(持锁则跳,**绝不阻塞通信**),超龄 op 快照进 `nccl.inflight_ops`。
- **过滤** `PROBING_NCCL_MIN_MSG_BYTES=0`:小于此的 collective 丢弃(降噪),记 `filtered`。
- `PROBING_NCCL_MOCK`(macOS 造假数据测 skill)、`PROBING_NCCL_VERBOSE`、`PROBING_NCCL_PROFILER`(插件路径)。

### 6.6 HCCL(Ascend)路径:库劫持 shim

- NCCL 用**插件 API**(NCCL 调进来);HCCL 用**库插桩**——`probing-hccl-shim` 导出与 CANN `libprofapi.so` 同名符号(MSProf API),放 `LD_LIBRARY_PATH` 前面拦截,再**转发**给真库。
- `PROBING_HCCL_PROFAPI_REAL` 指真 `libprofapi.so`(找不到则 stub 返回 0,训练照跑);`PROBING_HCCL_SHIM` / `PROBING_HCCL_SHIM_LOG`;`PROBING=2` 启用。
- 两条路产出同类 collective 数据,喂同一批下游 skill。

---

## 7. 采集机制 trick 合集

| 机制 | 文件 | 关键 trick |
|---|---|---|
| **Flight Recorder** | `flight_recorder.py` | **不是自建 ring,而是桥接 PyTorch 内置** `torch._C._distributed_c10d._dump_nccl_trace()`,只在 crash/watchdog(`PROBING_FR_ON_WATCHDOG=auto`)时读一次,**零常态开销** |
| **Deferred drain** | `deferred_drain.py` | 热路径 `put_nowait`,后台 daemon `save()`;满则同步兜底;`atexit` flush |
| **CUDA-event timing gate** | `timing/gates.py` + `_cuda_runtime_ffi.py` | **流值门控**:`cuStreamWaitValue32` 在独立 wait_stream 上挂起,把 start/workload/end 全 enqueue 完再 `cuStreamWriteValue32` 释放——排除 host enqueue 延迟,独立 stream 防死锁;每设备单例;**Ascend 类比 `_ascendcl_ffi.py` 目前不存在,仅 CUDA 有** |
| **Phase tracker** | `tracing/hooks.py` | 模块 ID `frozenset` 缓存(O(1) 命中);用 tensor `register_hook` 而非 module backward hook(避免 UserWarning + 边界错);phase 切换只是 Rust span 栈 push/pop |
| **pprof 采样** | `stacktrace/tracers/pprof.rs` | 双模式:SIGPROF(Linux 默认)/ 协作式 eval-frame(macOS 默认,避 Apple libc SIGILL);**Vyukov 无锁 MPMC ring(512 slot)**,signal handler 就地填充(大 snapshot 不上被中断栈);独立 altstack;fingerprint 聚合(最多 2^17 唯一栈);fold 延迟到导出 |
| **Tracing spans** | `tracing/span.py` | **deferred close**:`__enter__` 不写盘,`__exit__` 才写(短命 span 一次写);`PROBING_SPAN_BACKENDS=none` 快路径只留栈操作;`record_span` 不进栈直接写闭区间 |
| **CPU/GPU 周期采样** | `cc/.../cpu/collector.rs`, `gpu/.../collector.rs` | 独立 daemon 线程读 `/proc` / NVML,写 ring buffer(定容),1s 间隔,不碰 CUDA stream |

**统一哲学**:ring buffer 随处可见 · deferred everything · sampling over tracing · signal-safe 路径只做无锁入队 · single writer 无锁写 · 固定内存预算不 OOM。

---

## 8. 全量环境变量参考(~117 个功能变量,按子系统)

> 完整读点见各子代理报告;此处按组给最常用/最影响行为的。原始 grep ~135 含 `PROBING_AUTH_`/`PROBING_NCCL_MAX_` 等前缀伪命中。

**核心/服务**:`PROBING_ENABLED` · `PROBING_ORIGINAL`(子进程跟随,支持 `regex:`)· `PROBING_PORT`/`PROBING_ADDRESS` · `PROBING_DATA_DIR`(默认 `/dev/shm/probing`)· `PROBING_BASE_PATH`(反代前缀)· `PROBING_ASSETS_ROOT` · `PROBING_ENGINE_FAIL_FAST` · `PROBING_TABLE_DEFAULT_MB=20` · `PROBING_MCP_ALLOW_WRITE`(默认关,开才允许 MCP 写)。

**鉴权**:`PROBING_AUTH_TOKEN`(空=关)/ `PROBING_AUTH_USERNAME=admin` / `PROBING_AUTH_REALM`。

**TorchProbe**:`PROBING_TORCH_PROFILING`(spec)· `PROBING_TORCH_ADAPTIVE_RATE` · `..._OVERHEAD_TARGET_PCT=5` · `..._OVERHEAD_HIGH_PCT=10` · `..._RATE_FLOOR=0.01` · `..._DEFER_ASYNC=1` · `..._DEFER_QUEUE_SIZE=4096` · `..._PROFILER_MAX_EVENTS=200000` · `..._PROFILER_MAX_SESSIONS=8`。

**NCCL/HCCL**:见第 6 节(slots / shards=8 / chunk 64KiB×64 / min_msg_bytes / inflight=10s / mock / verbose / profiler 路径 / hccl shim + profapi_real)。

**采样/计时**:`PROBING_CPU`(默认开)/ `PROBING_CPU_SAMPLE_MS=1000` / `PROBING_CPU_THREAD_TOP_N=8` · `PROBING_GPU=auto` / `PROBING_GPU_SAMPLE_MS=1000` / `PROBING_GPU_BACKEND=auto` · `PROBING_RDMA_SAMPLE_RATE` · `PROBING_PPROF_COOPERATIVE` / `PROBING_PPROF_SIGPROF`。

**冷存储**:见 4.4(`PROBING_COLD*`)。

**集群/联邦**:`PROBING_CLUSTER_REPORT`(心跳)/ `..._INTERVAL_SEC=10` / `..._MAX_INTERVAL_SEC=120` / `..._BACKOFF`(默认开)· `PROBING_CLUSTER_STALE_SEC=25` · `PROBING_CLUSTER_FANOUT_HIERARCHICAL`(默认开)· `PROBING_FANOUT_CONCURRENCY=128` · `PROBING_FANOUT_STRICT`(默认关,失败给部分结果)· `PROBING_GLOBAL_SCAN_MAX_ROWS=10000` · `PROBING_REQUIRE_BROADCAST_LIMIT`。

**崩溃/飞行记录**:`PROBING_CRASH`(默认开)· `PROBING_CRASH_GRACE_SEC=20` / `..._NO_GRACE` / `..._HOLD` / `..._SPILL`(默认开)/ `..._NO_RESOLVE` · `PROBING_FR_ON_WATCHDOG=auto`。

**分布式 rank/拓扑**:`PROBING_{TP,PP,DP,EP,CP}_RANK`(默认 -1,回退 Megatron 命名)· `PROBING_{TP,PP,DP}_SIZE` · `PROBING_ROLE_<NAME>=<int>`(自定义并行维)· `PROBING_MICRO_BATCHES=1`。

**Span/集成**:`PROBING_SPAN_BACKENDS=memtable`(可 logger/otel/none)· `PROBING_SPAN_LOCATION`(贵)· `PROBING_MEGATRON`/`PROBING_VLLM`=auto · `PROBING_ENGINE_SCRAPE`=1 / `..._INTERVAL=5`。

---

## 9. 最新 diff 精读:`0275cb1 → 95c4ad8`(8 commit)

**规模**:+37076 / −7448,430 文件。表面看重心在 web/RL,**实质是一次 profiling/telemetry 成熟化**。

| SHA | PR | profiling 相关负载 |
|---|---|---|
| `ab84e18` | #57 | torch_probe 影子/采样引擎(+989);nccl `pool_pressure.rs`(新);bench 工具 |
| `a5705db` | #60 | **删死代码 `core/src/tracing.rs`(−874)**;nccl state.rs 测试(+152);soak |
| `6e2a243` | #65 | **runtime.rs 多级回退(+216)**;**memtable row.rs panic→Option(+170)**;`deferred_drain.py`(新);overhead 文档+SQL;**AGENTS.md +158** |
| `7f6271c` | #66 | Megatron/vLLM 例子 + soak;env 文档 |
| `c3f6723` | #67 | **Torch Profiler SQL**(profile_sql.rs + torch_profiler/ 包 + 两张表) |
| `7591d6e` | #68 | profiling 文档 |
| `a7cb35a` | #70 | **profiler 大重构**:扁平 `features/*.rs` → `stacktrace/·python/·torch/·flamegraph/` 子树 |
| `95c4ad8` | #71 | **RL/slime** 在线观测(旁支,复用 span 设施) |

### 深挖(profiling 相关)

1. **`tracing.rs` 删除(−874)= 死代码清理,非搬迁**:`trace/` 模块早已存在,`git grep crate::tracing` 空。span 单一真相源 = `core/src/trace/`(Rust)+ `python/probing/tracing/`(Python,可插 backend)。

2. **profiler 重构(`a7cb35a`)**:`features/pprof.rs`(−1016)→ `stacktrace/tracers/pprof.rs`(+1180);新增文档化流水线 `fill → StackSnapshot → parse → fold → FoldedStacks`;三个 tracer 共用一个 Python 帧源(vm=eval-frame / pprof=SIGPROF / dynamic=SIGUSR2);新 `flamegraph/distributed.rs` 支持**跨 rank 火焰图合并**。优化点:in-signal 捕获、off-signal 解析、无锁 ring、fingerprint 去重。

3. **Torch Profiler SQL(`c3f6723`)= 头号新特性**(见第 3 节)。优化本质:**结论化**——finalize 时一次聚合成 hotspot 表,不暴露原始事件,率上限截断。

4. **Overhead 子系统(`6e2a243`+`ab84e18`)= 让自身开销可测**(见第 5 节)。含 `deferred_drain.py`(异步落盘)、`web/overhead/`、不变量 + 回归测试。

5. **nccl state.rs +152 = 纯新增单测**:验证 v4 `trans_bytes` 只从权威状态取、`trans_size=0` 不覆盖真值、inflight drain 保留 pending。新 `pool_pressure.rs` 做限流告警。

6. **数据/运行时韧性(`6e2a243`)**:
   - `runtime.rs`:`block_on` **永不伪造数据**——删掉 `bool→false`/`Vec→empty` 等"假空"回退,改 `DataFusionError::External` 保留因果链,4 级运行时降级并 `error!` 日志,降级返回 `Err` 而非空。
   - `memtable/row.rs`:读路径 **panic→Option**——`read_*`→`try_read_*` 返回 `Option`,陈旧 chunk 读到返回**零/默认而非崩溃**(这些读发生在被 profile 的应用内,并发回收时的陈旧读绝不能拖垮训练)。

7. **AGENTS.md(+158)= 项目自订不变量**:新增 **"TorchProbe overhead 不许回归"** 硬块(改 overhead 公式 / `_close_step_wall` 顺序 / deferred 默认必须先读 `overhead-invariants.zh.md` 并更测试);codify "`block_on` 永不伪造数据——诊断工具里静默'无数据'比明确失败更糟";模块化契约(`ProbeDataSource`/`ProbeExtension`/`@table`/skills 只经发布契约交互,禁跨 collector 调用,用 SQL JOIN)。

**优化主旨一句话**:①采样做到便宜且正确(in-signal + 无锁 ring + 确定性无种子跨 rank + 异步 drain + 处处上限);②开销做到可测(影子步 + 中位数比 SQL + Web 面板 + 不变量测试);③结论优于原始事件(profiler 聚合成 SQL 表);④热路径韧性(读降级不崩、运行时降级返 Err 不造假);⑤可维护(删死码、重构成文档化流水线)。

---

## 10. 对我们推进工程的启示

1. **两套 profiler 分工清楚了**:常态诊断用 TorchProbe(采样、低开销、可跑长期);要 kernel 级热点就按需触发 Torch Profiler SQL 跑几十步。别指望后者常开。
2. **沐曦落地的具体缺口**(呼应上一轮):`gpu.utilization` 靠 NVML/mx-smi(适配分支已补 fallback);**collective 观测**沐曦走 NCCL 兼容——理论上 `NCCL_PROFILER_PLUGIN` 那套能复用(沐曦 MCCL 若兼容 profiler v3/v4 vtable),值得实测;Ascend 则走 HCCL shim。这条是"性能/通信观测"能不能在国产卡打通的关键。
3. **overhead 框架现成**:上一轮说"沐曦没 overhead 数据"——现在主线有 `python.torch_step_timing` + 影子步 + 中位数比 SQL,可直接拿来在沐曦上量 Probing 自身开销,不用自己造。
4. **改 profiling 核心要守 AGENTS.md 不变量**:overhead 公式 / hook 顺序 / deferred 默认 / `block_on` 不造假——碰这些要连带更新回归测试,否则 CI/soak 会拦。
5. **适配分支落后主线**:`Probing_plus` 基于旧版,主线已重构 `features/*` → `stacktrace/` 子树 + 新增 profile_sql + overhead。若要把沐曦适配 rebase 到新主线,重构面不小但结构同构(见上一轮 backend 抽象结论)。

---

### 附:核心文件索引(`/tmp/probing-upstream`)

- 设计文档:`docs/src/design/{profiling,torch-profiler-sql,overhead,overhead-invariants,nccl-profiler,data-layer,tracing-spans}.md`(多有 `.zh.md`)
- TorchProbe:`python/probing/profiling/torch_probe.py`、`tracing/hooks.py`、`deferred_drain.py`
- Torch Profiler SQL:`python/probing/profiling/torch_profiler/{controller,adaptor,sql,session_store}.py`、`probing/extensions/python/src/extensions/python/profile_sql.rs`
- 数据层:`probing/memtable/src/{memtable,row,cache,discover}.rs`、`probing/core/src/core/{memtable_sql,engine,semantic_catalog}.rs`、`probing/core/resources/tables.yaml`
- NCCL:`probing/extensions/nccl-profiler/src/{state,plugin,pool,shard,pool_config,writer,tables}.rs`
- Overhead:`web/src/overhead/{metrics,sql}.rs`、`web/src/components/overhead/panel.rs`
- 计时门:`python/probing/timing/{gates,timer,backend,_cuda_runtime_ffi}.py`
