# SUMMARY · P3-EXT-B stress_io Loud · SCORED D3

| 项 | 值 |
|----|-----|
| 状态 | **SCORED** |
| run_id | `20260725_020212-yjr-as-c-p3-ext-b-loud` |
| pod | `yysong-master-0`（hold-exec） |
| world | 16（1×16） |
| dose | fio nj=16 iodepth=64 size=4G + `ckpt_every=20` + `io_read_kb=1024`（同盘 payload）；无 apt 时回退 stress-ng hdd+iomix |
| inject | `stress_io` host_bound；dir=`/data/yinjinrun.p-huawei/probe-bundle/io_stress` |
| C0 / C1 / C2 med step_ms | 84.67 / 180.51 / 148.95 |
| C1/C0 | **2.13**（thr 1.3）→ Loud **PASS** |
| **最高 D** | **D3**（窗 IoU=1；SQL attach 失败 + PSI IO 未过阈 → 不升 D4） |
| jsonl | 48 |

## 三问

1. **边界**：manifest（16 卡、host_bound、stress_io、victim_lr=7、C0–C2）
2. **跑通**：jsonl 48 + fio SIDECAR_START + ACCEPT PASS
3. **检出**：如实 **D3**（不焊答案；SQL 无外证停 D3）

## 标定笔记

- 沐曦曾 ineffective；昇腾首轮 Loud 即咬合（加密 ckpt + 同盘 pread 关键）
- 镜像现有 `/usr/bin/fio`；hold_exec 优先 fio，否则 stress-ng
