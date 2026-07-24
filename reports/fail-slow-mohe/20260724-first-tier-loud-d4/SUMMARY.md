# 第一梯队 Loud 汇总（2026-07-24）

| Case | 格 | Run | C1/C0 | 离线 | SQL/D4 | 备注 |
|---|---|---|---:|---|---|---|
| P3-EXT-A | 9A | `20260724_090823-p3-live-d4e` | ~2.97 | D3 | **D4**（host_psi_cpu） | 首个 D4 |
| P3-SW-A | 8A | `20260724_115002-p3swa-loud` | 2.17 | D3 | **D4**（cpu.utilization_rss） | 内联 GC+stall |
| P1-EXT-A | 3A | `20260724_112745-p1exta-loud` | 3.78 | D3 | **D4**（host_mx_smi_gpu_util） | mx-smi 旁路补表 |
| P1-EXT-B | 3B | `20260724_124947-p1extb-loud` | 1.74 | D3 | **D4**（host_mx_smi_hbm_bw） | 内联 HBM + mx-smi |
| P3-EXT-B | 9B | bite 系列 | — | — | 暂搁 | IO 未咬进 step_ms |

**D4 已通**：9A、8A、3A、3B（4/5）。  
**暂搁**：9B。

## P1 表缺失补丁（2026-07-24）

MetaX 上 Probing `CudaBackend` 起不来 → `gpu.utilization` / `process.gpu_users` 永不建表。  
对标 P3 `host_psi_*`：`dump_probing_sql.sh` 同窗采 `mx-smi` → `host_gpu.json`；`score_dlevel_sql.py` 回落升 D4。  
见 A5 附注（`projects/probing-test/docs/fail-slow/decisions.md`）。
