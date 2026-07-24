# P3-SW-C 冻结检测草案（探索阶段产出）

## 信号路径

1. 训练 jsonl：`data_ms` / host gap / `step_ms`（须 `host_bound`）
2. 全主机 RSS：非训练进程 RSS 趋势（监控泄漏进程）
3. Probing：`cpu.utilization` rss 字段；PSI 可选但不升 P3-SW D4 主证据

## 判据骨架

- D1：C1/C0 超噪声
- D2：窗 IoU
- D3：**host** 命中（同机即可）
- D4：根因 = 进程外监控泄漏层（非训练进程 RSS 与退化相关）

## 论证价值

服务 OUTLINE「诊断系统自身开销」——监控 agent 泄漏可拖慢训练。
