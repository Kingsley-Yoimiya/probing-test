# P3-EXT-B Loud Pilot 结论（暂搁）

- PSI-io 冒烟：PASS（fio 可见）
- bite3/4：`injection_ineffective`（C1/C0≈1.08 / 0.99）— fio/ckpt 不在 step_ms 关键路径
- bite5：同盘 payload 读导致 warmup/NCCL 超时，C0/C1 均 FAILED
- **正式 Loud ABC/D4：暂不推进**；需重做「计时内 IO」且不拖垮集合通信

下一 case：P1-EXT-A（串行）
