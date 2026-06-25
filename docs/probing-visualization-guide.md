# Probing 可视化与展示方式指南

> **文档版本**：2026-06-25（完整 Web UI 版）  
> **素材目录**：[`assets/latest/`](assets/latest/)  
> **环境**：Probing v0.2.5 源码构建、Dioxus Web UI 已构建、4× RTX A6000

本文档汇总 Probing 全部主要展示方式：**CLI 终端**、**Web 工作台**、**实时 Span 日志**，含用法说明与本次重跑实验的**真实截图**。可直接转发。

---

## 1. 展示方式总览

| # | 方式 | 入口 | 典型用途 |
|---|------|------|----------|
| 1 | 进程列表 | `probing list` | 发现 PID / HTTP 端口 |
| 2 | SQL 查询 | `probing query` | span、显存、通信等 memtable |
| 3 | 表目录 | `probing tables` | 探索可查询表 |
| 4 | 内存时序 | `probing memory` | CPU RSS + GPU 显存 |
| 5 | 混合栈回溯 | `probing backtrace` | 定位卡住 / 慢栈 |
| 6 | 诊断 Skill | `probing skill run …` | Playbook 结构化诊断 |
| 7 | Span 实时日志 | `PROBING_SPAN_BACKENDS=logger` | stderr 实时 phase |
| 8 | 火焰图 | `probing flamegraph` / Web Profiling | pprof / torch |
| 9 | Dashboard | Web `/` | CPU/GPU/RSS/线程 |
| 10 | Distributed Spans | Web `/spans` | trace_event 层级树 |
| 11 | Training | Web `/training` | 单卡 step 柱状图；多卡 **Step×Rank 热力图**（straggler） |
| 12 | Analytics | Web `/analytics` | 跨表分析 |
| 13 | Python Live Trace | Web `/python` | 函数级 live 变量 |
| 14 | Investigate Agent | Web `/agent` 或 ⌘J | Playbook + 可选 LLM |
| 15 | SQL REPL | Web ⌘K | 浏览器 live SQL |
| 16 | Cluster 联邦 | `probing cluster query` | 多 rank 合并 SQL |

---

## 2. 环境准备（一次性）

### 2.1 构建 Web UI

本机 glibc 较旧时，用 Docker 构建（已验证）：

```bash
bash scripts/build_frontend_docker.sh
# 产物：probing/web/dist/ 与 probing/python/probing/bundled_web/
```

### 2.2 启用 Probing

```bash
source probing/.venv/bin/activate
unset PROBING_CLI_MODE CONDA_PREFIX   # 重要：CLI_MODE 会阻止注入

PROBING=1 PROBING_PORT=8765 \
  PROBING_ASSETS_ROOT=/home/yjr/probing-test/probing/web/dist \
  python train.py
```

终端会打印：

```
probing server is available on: 0.0.0.0:8765
```

浏览器访问：`http://127.0.0.1:8765/`

### 2.3 一键重建文档素材

```bash
bash scripts/setup_visualization_docs.sh
```

---

## 3. CLI 展示方式

### 3.1 进程列表 — `probing list`

```bash
probing list -v
```

![CLI list](assets/latest/cli_list.png)

---

### 3.2 SQL 查询 — `probing query`

```bash
probing -t <pid> query "
SELECT s.name, s.phase,
       round((e.time - s.time)/1e6, 2) AS ms
FROM python.trace_event s
JOIN python.trace_event e
  ON s.span_id=e.span_id AND e.record_type='span_end'
WHERE s.record_type='span_start'
ORDER BY s.time DESC LIMIT 15"
```

支持 `--format json|csv`。默认输出 ASCII 表格：

![CLI query trace](assets/latest/cli_query_trace.png)

---

### 3.3 表目录 — `probing tables`

![CLI tables](assets/latest/cli_tables.png)

---

### 3.4 内存时序 — `probing memory`

Host RSS + GPU 显存双表：

![CLI memory](assets/latest/cli_memory.png)

---

### 3.5 混合栈回溯 — `probing backtrace`

Python 帧 + C/C++ 帧混合输出：

![CLI backtrace](assets/latest/cli_backtrace.png)

---

### 3.6 诊断 Skill — `probing skill`

```bash
probing -t <pid> skill list
probing -t <pid> skill run module_bottleneck
```

![CLI skill help](assets/latest/cli_skill_help.png)

![CLI skill list](assets/latest/cli_skill_list.png)

---

## 4. 实时 Span 日志（stderr）

```bash
PROBING=1 PROBING_SPAN_BACKENDS=memtable,logger python scripts/demo_train_viz.py
```

![Span logger](assets/latest/cli_span_logger.png)

---

## 5. Web 工作台（Dioxus 真实 UI）

### 5.1 Dashboard — `/`

进程概览、CPU 柱状图、Top 线程表（可点 Stack / Spans / Profile）：

![Web Dashboard](assets/latest/web_dashboard.png)

---

### 5.2 Distributed Spans — `/spans`

`python.trace_event` 层级 span，支持 step / trace 过滤：

![Web Spans](assets/latest/web_spans.png)

---

### 5.3 Training — `/training`

Training 页的核心不是 Profiling 那种 Chrome trace **时间线**，而是 **step 耗时矩阵**：

| 场景 | UI 形态 | 说明 |
|------|---------|------|
| **单进程 / 单 rank** | 柱状图（Step timings） | 每个 step 一根竖条，红色表示超过窗口均值 1.2× |
| **多 rank（DDP/torchrun）** | **Step straggler heatmap** | 行=rank、列=step，颜色越深越慢，红圈=outlier |
| 任意 | Module Hotspots / Collective | 模块 hook 排行、NCCL collective 表 |

多卡热力图需要：

1. `probing.attach_training_phases(model, optimizer)` 写入 `train.step` span  
2. `WORLD_SIZE > 1`（如 `torchrun --nproc_per_node=2`）  
3. Web UI 切到 **Cluster** 并扫描，或调用 `GET /apis/training/step_matrix?cluster=true`

**单卡 demo（柱状图）：**

![Web Training demo](assets/latest/web_training.png)

**2-GPU DDP straggler 热力图**（数据来自 live `step_matrix` API，rank 1 人为加慢模拟 outlier）：

![Step straggler heatmap](assets/latest/web_training_heatmap.png)

复现热力图素材：

```bash
bash scripts/capture_training_heatmap.sh
# 或一键：bash scripts/setup_visualization_docs.sh（含完整采集）
```

---

### 5.4 Profiling — `/profiling/*`

| 路由 | 内容 |
|------|------|
| `/profiling/pprof` | CPU 火焰图 |
| `/profiling/trace` | Chrome trace 时间线 |

![Profiling pprof](assets/latest/web_profiling_pprof.png)

![Profiling trace](assets/latest/web_profiling_trace.png)

---

### 5.5 Analytics — `/analytics`

![Web Analytics](assets/latest/web_analytics.png)

---

### 5.6 Python — `/python`

函数级 live trace / eval：

![Web Python](assets/latest/web_python.png)

---

### 5.7 Investigate Agent — `/agent`

Playbook 快捷按钮 + 自然语言诊断（可选 LLM）：

![Web Agent](assets/latest/web_agent.png)

---

### 5.8 SQL REPL — ⌘K

任意页面按 **⌘K / Ctrl+K** 打开 Command Panel，输入 SQL 即查 memtable（与 `probing query` 等价）。

---

## 6. Megatron gpt345m 实测

```bash
PROBING=1 PROBING_PORT=8766 PROBING_ASSETS_ROOT=probing/web/dist \
  torchrun --nproc_per_node=1 pretrain_gpt.py ... --train-iters 40
```

**Dashboard**（可见 torchrun / pt_elastic 线程 CPU）：

![Megatron Dashboard](assets/latest/web_megatron_dashboard.png)

**Training 页**（未挂 `attach_training_phases` 时 step matrix API 可能 500，属预期）：

![Megatron Training](assets/latest/web_megatron_training.png)

---

## 7. 实验复现命令

| 脚本 | 作用 |
|------|------|
| `scripts/build_frontend_docker.sh` | Docker 内构建 Web UI |
| `scripts/demo_train_viz.py` | 带 phase hook 的小训练（span 最全） |
| `scripts/capture_viz_demo.sh` | 自动采集 CLI + Web 截图 |
| `scripts/capture_training_heatmap.sh` | 2-GPU DDP + Step×Rank 热力图截图 |
| `scripts/setup_visualization_docs.sh` | 上述全部一键执行 |

Demo 训练：

```bash
unset PROBING_CLI_MODE
PROBING=1 PROBING_PORT=8765 PROBING_SPAN_BACKENDS=memtable,logger \
  PROBING_ASSETS_ROOT=probing/web/dist \
  python scripts/demo_train_viz.py
```

官方示例：

```bash
PROBING=1 python probing/examples/tracing.py
```

---

## 8. 已知限制

| 问题 | 建议 |
|------|------|
| Megatron 无 `train.step` | 调用 `probing.attach_training_phases(model, optimizer)` |
| `PROBING_TORCH_PROFILING=on` 在 Megatron 导入时可能 panic | 训练稳定后再开 profiling |
| `PROBING_CLI_MODE=1` 阻止探针注入 | 跑训练前 `unset PROBING_CLI_MODE` |
| 多卡 collective | 设 `NCCL_IB_DISABLE=1`、空闲 GPU、`MASTER_ADDR=127.0.0.1` |

---

## 9. 参考

- [probing/probing/server/API.md](../probing/probing/server/API.md)
- [probing/web/DESIGN.md](../probing/web/DESIGN.md)
- Megatron 矩阵报告：[logs/megatron_matrix_20260625_003950/REPORT.md](../logs/megatron_matrix_20260625_003950/REPORT.md)

**本次采集时间戳**：见 [`assets/latest/meta.txt`](assets/latest/meta.txt) 中的 `CAPTURE_ID`
