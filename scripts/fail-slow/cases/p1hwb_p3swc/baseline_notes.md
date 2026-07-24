# Baseline / 对手接入笔记（P1-HW-B / P3-SW-C 隔离战役）

> 红线 5：未穷尽接入前不写 ENV-BLOCKED；记 PENDING + 卡点。

## 在线线（pipeline CONFIGS）

| Config | 工具 | 接入 | 本战役状态 |
|--------|------|------|------------|
| C0 | 无 | `PROBING=0` | 必跑 |
| C1 | 无+注入 | 同上 | 必跑（Loud 咬合） |
| C2 | Probing | `PROBING=2` + gpu | 必跑 |
| C3 | Greyhound | `LD_PRELOAD=$CODE_DIR/greyhound/libmcclprobe.so` + Redis | 从 fs64 战役复制 `.so`；缺 Redis 时 PENDING |
| C4 | XPUTimer | `LD_PRELOAD=$CODE_DIR/xputimer/libxpu_timer_metax.so` | MetaX `.so` 待构建 → PENDING |
| C5 | Flight Recorder | `TORCH_NCCL_TRACE_BUFFER_SIZE` | env 可跑；P1/P3 结构性弱仍记 D-level+代价 |

## Dynolog + HTA（单独 D-run，不进默认 CONFIGS）

- **触发协议（本战役）**：`oracle` — 已知注入窗后开短窗 profile；**不算**自主检出率 / TTD。
- 常驻代价对照：可选健康线挂 daemon 测 step_time 开销（五项代价 #1）。
- 解析：HTA 离线；结果写入 `results/muxi-h3c/<run_id>/dynolog/`。

## 落盘

- kube：weibozhen.p；AFS / 本机：`yinjinrun.p` → `results/muxi-h3c/<run_id>/`
- 禁止写 `/afs-a3-weight-share/weibozhen`

## 2026-07-24 接入实况

- Greyhound `libmcclprobe.so`：从 `yjr-fs64-h144101` 复制到全部 `yjr-1b8c-*`（15616 B）。Redis 依赖：C3 若缺 Redis 记 PENDING，不记 ENV-BLOCKED。
- XPUTimer：在 `yjr-1b8c-h144147` 用 `metax_probe/build_metax_hook.sh` 编出 `libxpu_timer_metax.so`（65784 B），已扇出。
- Flight Recorder：env 线，pipeline C5 已支持。
- Dynolog：oracle 触发协议见上；本战役正式 Loud 先跑 C0–C5，Dynolog 另开短窗。
