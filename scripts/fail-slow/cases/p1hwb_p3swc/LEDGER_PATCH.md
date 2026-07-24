# 战役台账补丁（隔离目录，避免与共享 ledger 并行冲突）

执行 Agent 维护；合并进共享 `docs/fail-slow/ledger.md` 时再人工合。

## 环境

| 项 | 值 |
|---|---|
| 集群 | vc-c550-h3c-test（1024 卡面） |
| kube | weibozhen.p |
| 落盘 | yinjinrun.p → `results/muxi-h3c/<run_id>/` |
| pods | `yjr-1b8c-h144147..162`（8×8=64） |
| reserve | host-10-12-144-164/165（只记账） |
| 代码 | `scripts/fail-slow/cases/p1hwb_p3swc/`（隔离） |

## 对手

| 工具 | 状态 |
|---|---|
| Greyhound `.so` | ✅ 已扇出 |
| XPUTimer MetaX `.so` | ✅ g++ 直编扇出 |
| Flight Recorder | ✅ C5 env |
| Dynolog | oracle 触发协议（不算自主检出） |

## Runs

| run_id | case | 阶段 | 备注 |
|---|---|---|---|
| `20260724_180014-p1hwb-loud-ramp` | P1-HW-B | Loud pilot C0/C1 | **PASS** C1/C0=1.35；注入=渐进 inline HBM（外挂 1b 与 pipeline 约定不齐） |
| `20260724_180721-p1hwb-loud-formal` | P1-HW-B | Loud 正式 C0–C5 | C1/C0=1.37；C4 XPUTimer FAILED→PENDING；C2 有 probing dump（含 host_mx_smi_hbm） |
| `20260724_185509-p3swc-loud-pilot` | P3-SW-C | Loud pilot | C0 OK；C1 **7/8 rendezvous 失败** |
| `20260724_192038-p3swc-loud-pilot2` | P3-SW-C | Loud pilot2 | C0 fired 后**集群中断** |
| 检查点 | — | — | `results/muxi-h3c/20260724_campaign-p1hwb-p3swc-checkpoint/CAMPAIGN_CHECKPOINT.md` |

## 平台 know-how（本战役）

- MetaX 上 OUTLINE 1B 用**隔离** `train_bench_probe_1b_ramp.py`（copies 6→48）代理外挂 sidecar。
- 外挂 `sidecar_inject_v2 --case 1b` 打 `SIDECAR_1B_START`，与共享 pipeline 的 `SIDECAR_START`/injection.log 门闩不齐；未改共享脚本。


## Case 映射纠正

共享 `run_campaign.sh` 中 `P1-HW-B|freq` **错误**；本战役用 `1b`（见 `registry_fragment.txt`）。
