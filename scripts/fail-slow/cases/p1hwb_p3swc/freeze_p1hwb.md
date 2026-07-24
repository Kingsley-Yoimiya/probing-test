# P1-HW-B 冻结检测草案（探索阶段产出；不含注入窗/rank/PID 答案）

> 正式冻结前须 Loud pilot 咬合通过。本文件只描述**通用**查询能力。

## 信号路径（MetaX）

1. 训练 jsonl：`compute_ms` / `step_ms` 相对健康线变点（D1–D2）
2. 同窗旁路：`dump_probing_sql.sh` → `host_gpu.json` / `host_mx_smi_hbm_bw`（D4 候选）
3. Probing SQL：`cpu.utilization`；GPU util 表若空则不依赖

## 判据骨架（冻结后写进脚本分支，仍禁止焊答案）

- D1：注入配置相对 C0，窗内中位 step_ms 比 ≥ Loud 阈值（剂量配方）
- D2：异常 onset 与真值窗 IoU≥0.5（判分阶段才读真值）
- D3：victim **rank**（P1）= 真值
- D4：根因坐标 = P1×HW×带宽（HBM BW 升高 + 访存 phase 退化谱）

## 与 Greyhound 对照预期

渐进剂量易被 &lt;10% 排除规则漏检 → 记录即可。
