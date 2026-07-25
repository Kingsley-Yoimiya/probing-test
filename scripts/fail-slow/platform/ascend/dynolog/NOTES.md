# Dynolog + PyTorch Profiler + HTA（Ascend）

> trade-off **「极深极贵」极点**（outline-v5 §1.2）。角色见 `../COVERAGE_MATRIX_PLAN.md` 表 B。

## 定位（不进默认 C0–C5，不进覆盖率表 A）

- 触发类型 = **oracle**：Meta 实践是按需开几秒 profiling，不常驻（常驻 +20~44% 且 OOM）。
- 因此**不算自主检出率**（rules §三·五 B）：不进 `M/27` 分子/分母。
- 只比两轴：① 触发后 HTA 事后诊断到 D 几（预期 D3–D4，kernel 级）；② 代价（常驻开销% / onset 前空白）。

## 触发协议（oracle，写死）

1. 用 case 已知注入窗 `[100,300]` **之后**，人工/脚本按需开 profiling 几秒~几十秒。
2. 注入窗**只决定触发时机，不进检出判定**——本工具本就不声称自主检出（不违红线 2）。
3. 产物在 `results/ascend-ais/baseline/dynolog/<run_id>/`；HTA 事后分解另跑。

## 接入路径（昇腾）

- Dynolog daemon + `KINETO_USE_DAEMON=1`；或 MSProf / Ascend PyTorch profiler（Kineto-NPU）。
- HTA（Holistic Trace Analysis）离线解析 kineto/msprof trace → temporal breakdown。
- 未趟通记 PENDING，不写 ENV-BLOCKED（红线 5）。

## 判分脚本

- `s4_verdict.py --case <C> --hta-out <dir> --resident-overhead-pct <p>` → `coverage_row.jsonl`
  （`trigger_type=oracle`；汇总脚本据此只放表 B）。
- 汇总：`../baseline_coverage_matrix.py`。

## 本轮先做（离线优先）

- 把已回拉的 run（如 P2-SW-B、P3-EXT-A）的 kineto/msprof trace 离线喂 HTA，产触发后诊断深度第一版。
- 常驻开销：另起 C2 位挂 profiler 短测，实测复核 outline 引用的 +20~44%。
