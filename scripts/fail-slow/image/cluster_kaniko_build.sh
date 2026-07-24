#!/usr/bin/env bash
# 占位：集群内 Kaniko 构建（跳板对 ccr-deeplink unauthorized 时用）。
# 当前推荐两步：
#   1) bash install_env_to_pods.sh   # 立刻灌进现有 pod，开测
#   2) 有 registry 写权限的节点上 bash build.sh / remote_build_ais.sh
#
# 完整 Kaniko Job 待 registry 推送路径确认后再补。
set -euo pipefail
echo "Use: bash $(dirname "$0")/install_env_to_pods.sh"
echo "Or:  bash $(dirname "$0")/build.sh   # where docker can pull BASE_IMAGE"
exit 2
