# 昇腾 Fail-Slow 战役终态（对外分享）

> **本目录是给人看的终态包**，在 `probing-test` 仓。  
> 维护者本机原始回拉可仍在别处；**不要把对外终态只放在 myportal**。  
> 台账与排期：`probing-huawei/docs/fail-slow/`（`CASE_QUEUE` / `CONTRAST_QUEUE` / `ledger`）。

战役日：2026-07-25 · 16 卡 hold-exec（`yysong`）· Case@master-0 · GH@worker-1 · XPU@worker-2

## 总览

| 线 | 结果 |
|----|------|
| Probing Case | **14 SCORED**（D2×1 / D3×10 / D4×3）；13 SKIP_PERM；0 PENDING |
| Greyhound 对照 | 14 DONE；`detect_ok=yes` **8**（多为 Rbeast 自主变点） |
| XPUTimer 对照 | 14 DONE；`detect_ok=yes` **0**（剂量多 PASS，自主 flags 不咬） |

## 14 SCORED（完整 run 目录）

| case | run_id | D | 主比 |
|------|--------|---|------|
| P1-EXT-A | `20260725_011129-yjr-as-c-p1-ext-a-loud` | D2 | step 3.87 |
| P1-EXT-B | `20260725_014350-yjr-as-c-p1-ext-b-loud` | D3 | 2.02 |
| P3-EXT-A | `20260725_001251-yjr-as-c-p3-ext-a-loud` | D3 | ≈1.97 |
| P3-EXT-B | `20260725_020212-yjr-as-c-p3-ext-b-loud` | D3 | 2.13 |
| P3-EXT-C | `20260725_021906-yjr-as-c-p3-ext-c-loud` | D3 | 1.59 |
| P3-SW-A | `20260725_012957-yjr-as-c-p3-sw-a-loud` | D4 | 2.93 |
| P1-SW-A | `20260725_114556-yjr-as-c-p1-sw-a-loud` | D3 | 4.20 |
| P1-SW-B | `20260725_115732-yjr-as-c-p1-sw-b-loud` | D3 | 1.36 |
| P1-SW-C | `20260725_121105-yjr-as-c-p1-sw-c-loud` | D3 | tip max 4.63 |
| P2-SW-B | `20260725_122911-yjr-as-c-p2-sw-b-loud` | D3 | comm 1.82 |
| P2-SW-C | `20260725_124102-yjr-as-c-p2-sw-c-loud` | D3 | comm 49.86 |
| P3-SW-B | `20260725_125558-yjr-as-c-p3-sw-b-loud` | D4 | 2.06 |
| P3-SW-C | `20260725_135238-yjr-as-c-p3-sw-c-loud` | D4 | 2.49 |
| P1-HW-B | `20260725_142359-yjr-as-c-p1-hw-b-loud` | D3 | 1.57 |

每目录通常含：`ACCEPT_LOUD.md` / `VERDICT*.md` / `scoring_table*.csv` / rank `jsonl` / `manifest.yaml`。

## Baseline 对照（瘦身包）

路径：`baseline/{greyhound,xputimer}/contrast-*/`

只保留 **VERDICT / SUMMARY / manifest / 小日志**；不入库 GB 级 `ascend_trace` / 原始 collect dump。  
完整原始对照仍在维护者本机回拉盘；判读以 `CONTRAST_VERDICT.md` 与 `probing-huawei/docs/fail-slow/CONTRAST_QUEUE.md` 为准。

| 缺口 | 说明 |
|------|------|
| XPU × P2-SW-B `contrast-p2-sw-b-20260725_131251` | 本机目录缺失；队列与 ledger 有 DONE 摘要，无本地瘦身包 |

## 读法提醒

- Greyhound `detect_ok=yes` ≈ **检出/告警层**（自主 coll 比或 Rbeast），**不是** Probing D3/D4。  
- 剂量与公平性：`scripts/fail-slow/platform/ascend/` + `dose_recipes.yaml`。
