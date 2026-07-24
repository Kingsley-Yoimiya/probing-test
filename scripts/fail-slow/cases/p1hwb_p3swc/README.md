# P1-HW-B（1B）+ P3-SW-C（8C）隔离战役

多 Agent 并行时，本目录承载这两个 case 的配方与入口，**尽量不改**共享的 `run_case_abc.sh` / `dose_recipes.yaml` / `run_campaign.sh`。

| 文件 | 用途 |
|------|------|
| `dose_recipes.yaml` | 本战役剂量（Loud/Quiet/Masked） |
| `run_abc.sh` | 入口：映射 CASE → INJECT_KIND，再调 `run_case_pipeline_v4.sh` |
| `env.sh` | kube / pods / 规模默认 |
| `registry_fragment.txt` | 纠正后的 campaign 行（勿与共享 registry 的 `freq` 混淆） |
| `baseline_notes.md` | 对手 .so / Dynolog 触发协议 |
| `score_cases.py` | 本战役 case → grid/kind 登记（评分时 import） |

OUTLINE：`1B` 显存带宽渐进衰减；`8C` 监控程序自身泄漏。
