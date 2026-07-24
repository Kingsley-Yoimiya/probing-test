# Host 旁路（对标 dump_probing_sql 里的 mx-smi）

待实现（接入后）：

| MetaX | Ascend |
|-------|--------|
| `mx-smi` 利用率/HBM | `npu-smi info` / `-t usages` 等 |
| `/proc/pressure/*` | 同（若内核有） |
| process GPU users | 昇腾进程列表接口 |

输出仍建议：`host_gpu.json` / `host_pressure.json` 等稳定文件名，便于 score 脚本复用。
