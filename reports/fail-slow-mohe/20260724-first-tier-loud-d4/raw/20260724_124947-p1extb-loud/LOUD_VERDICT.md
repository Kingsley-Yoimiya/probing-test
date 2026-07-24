# P1-EXT-B Loud — 20260724_124947-p1extb-loud

| 项 | 结果 |
|---|---|
| C1/C0 | **1.74**（PASS，内联 HBM 512MB×48） |
| 离线 | D3 |
| SQL | **D4 / PASS_D4**（`host_mx_smi_hbm_bw`，hbm≈639482 MB/s） |

## 补丁

MetaX 上 `gpu.utilization` 因 CudaBackend 起不来而缺失。对标 P3 `host_psi_*`：`dump_probing_sql.sh` 同窗采 `mx-smi --show-hbm-bandwidth` → `host_gpu.json`；`score_dlevel_sql.py` 回落该证据升 D4。
