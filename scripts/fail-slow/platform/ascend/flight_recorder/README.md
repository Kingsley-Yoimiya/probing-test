# Flight Recorder / TorchComms（Ascend）

> trade-off **「极轻极窄」极点**（outline-v5 §1.2）。角色见 `../COVERAGE_MATRIX_PLAN.md` 表 A。

## 定位（进覆盖率表 A，但只 P2）

- 触发类型 = **autonomous**（环形缓冲常驻，开销极低）。
- **只记 collective 元数据**（op/seq/shape/state）→ 归因深度上界 **D1**（"哪个 collective 卡了"）。
- **结构盲区**：P1（芯片）/ P3（主机）类它物理上无信号 → 覆盖率表里记 `structural_na`（**≠ D0**）。
- 只做 hang/desync 诊断；纯 fail-slow（慢 20% 但没挂）它**不检测** → 那类 P2 也应回落 D0。

## 27-case 覆盖率读法

| 格 | FR 记法 |
|---|---|
| P2×{HW,SW,EXT}（9 格） | 真跑 → hang/desync 可到 D1；纯 fail-slow→D0 |
| P1×*、P3×*（18 格） | `structural_na`（不采该类信号，不算它失败） |

→ 覆盖率写 `k/9 (P2 only) · 18 N/A`，**不写 k/27**，报告标 "collective-only"。

## 接入（pipeline C5 via `config_denv_ascend.sh`）

- `TORCH_HCCL_TRACE_BUFFER_SIZE`（若 Ascend PyTorch 栈识别）；`TORCH_NCCL_*` 作兼容探测。
- 验证三步：① env 是否被读取；② 超时/人工 dump 是否落盘；③ `fr_trace` 解析能否给出可用 timeline。
- **env 生效但内容空 → PENDING**，不伪造成 D（`BASELINE_PORTING.md` §3）。

## 判分脚本

- `s4_verdict.py --case <C> --fr-dump <dir>` → `coverage_row.jsonl`
  （P1/P3 自动 `structural_na`；P2 有记录→D1 占位，待接 desync 判据分 D0/D1）。
- 汇总：`../baseline_coverage_matrix.py`。

## 本轮先做（离线优先）

- 把已回拉的 P2 run（如 P2-SW-B 的 comm trace）离线喂 `fr_trace`，产 P2 那 9 格第一版。
- P1/P3 直接记 N/A，不跑（结构盲区是能力事实，不是没跑）。
