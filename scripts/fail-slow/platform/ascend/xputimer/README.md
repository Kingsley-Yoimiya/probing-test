# XPUTimer Ascend hook（占位）

对标：`~/Codespace/probing-baselines/xputimer-metax/xpu_timer/metax_probe/`。

设备代码到位后：

1. 填上级 `../SYMBOL_MAP.md`  
2. 实现 `build_ascend_hook.sh` → `libxpu_timer_ascend.so`  
3. 单卡 / 2-rank 自测脚本（可从 metax_selftest / metax_dist_test 改）  
4. 扇出到 `$CODE_DIR/xputimer/`

产出物约定：`$XPU_TIMER_DUMP_DIR/*.prom` + `*.jsonl`（保持与 MetaX 可比字段）。
