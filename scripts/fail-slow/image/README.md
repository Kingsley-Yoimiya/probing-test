# probing-failslow MetaX 统一镜像 / 环境

目标：一次备好 **Probing_plus（gpu + mx-smi）+ probe-bundle + stress-ng/fio + 统一环境变量**，之后起 pod 就能测，不再分片传 wheel、不再现场 `pip install probing`（PyPI 0.2.4 无 GPU 表）。

## 底包

```
registry2.d.pjlab.org.cn/ccr-deeplink/megatron-lm:0.12.0-maca.ai3.3.0.11-torch2.6-py312-ubuntu22.04-amd64-driver
```

## 统一变量（`env.defaults` / 镜像 ENV）

| 变量 | 值 |
|---|---|
| `LOCAL_CODE` / `PYTHONPATH` | `/workspace/probe-bundle`、`…/pydeps` |
| `PROBING_GPU` | `on` |
| `PROBING_GPU_SAMPLE_MS` | `1000` |
| `PROBING_TORCH_PROFILING` | `on`（C2） |
| `DUMP_PROBING_SQL` | `1` |
| `SIDECAR_WARMUP` | `8` |

## 路径 A — 立刻灌进现有 pod（推荐先走这条）

本机已有完整 wheel：`/tmp/probing-full.whl`（MD5 `fe3b76db996fece61033c3c12480f2e9`）。

```bash
export KUBECONFIG=~/.kube/config-vc-c550-mohe-241.yaml
export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897
export NO_PROXY=127.0.0.1,localhost
unset ALL_PROXY

PODS=yjr-fs-h14410,yjr-fs-h14411 WHEEL=/tmp/probing-full.whl \
  bash install_env_to_pods.sh
```

内容与 Dockerfile 等价；灌完即可跑 `campaign_sql_d4.sh`。

## 路径 B — 真正打镜像推 registry

```bash
# 需在「能 pull ccr-deeplink」的机器上（集群节点 / 有权限的构建机）
# 注意：ais-cf3e61a5 上 docker login 后对 ccr-deeplink 仍 unauthorized（2026-07-23）
WHEEL=/tmp/probing-full.whl \
IMAGE_REPO=registry2.d.pjlab.org.cn/<你有写权限的前缀>/probing-failslow-metax \
IMAGE_TAG=0.2.5-gpu-mx-YYYYMMDD \
PUSH=1 \
  bash build.sh
```

然后：

```bash
IMAGE=registry2.../probing-failslow-metax:<tag> \
PULL_SECRET=megatronmuxi-test \
NODES=host-...,host-... RUN_ID=... \
  bash ../provision_priv_pods.sh apply
```

文件：

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 底包 + wheel + bundle |
| `env.defaults` | 变量真相源 |
| `build.sh` | 本地/跳板 docker build+push |
| `remote_build_ais.sh` | 本机打包 → ais（tar\|ssh；ais 无 sftp） |
| `install_env_to_pods.sh` | 等价环境灌进 Running pod |

## 说明

- wheel 来自 mohe pod 上源码编译的 Probing_plus `0.2.5`（features=`gpu,gpu-cuda,kmsg`，含 `mx-smi`）。
- `process.gpu_users` 主线仍无；D4 EXT 可能仍是 `SQL_NO_EXT_EVIDENCE`，但 `gpu.utilization` / `cpu.utilization` / SQL dump 链路可用。
- 勿把 `dockerconfig` / wheel 提交 git（见 `.gitignore`）。
