# Dynolog 接入备注（本战役）

管线 `run_case_pipeline_v4.sh` 的 CONFIGS 只有 C0–C5（无 Dynolog）。

本轮计划：
1. 先跑完 C0–C5（Probing / Greyhound / XPUTimer / Flight Recorder）。
2. Dynolog 按 `project/reading-paper/writing/probing-paper/BASELINE-SETUP-PLAYBOOK.md`
   与 `SOP-COMPATIBILITY-DYNOLOG-FLIGHT-RECORDER.md` 在同批 `yjr-p1c64` pod 上单独开窗。
3. 触发协议默认标 **oracle 触发**（已知注入窗后采 trace）——只能比诊断深度与代价，
   不算自主检出率 / trigger 延迟（rules §三·五 B）。
4. 接入穷尽前不写 `ENV-BLOCKED`。
