#!/usr/bin/env bash
# 本机打包 → 同步 ais → docker build/push。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/env.defaults"

WHEEL="${WHEEL:-/tmp/probing-full.whl}"
JUMP="${JUMP:-ais-cf3e61a5}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-vc-c550-mohe-241.yaml}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-megatronmuxi-test}"
REMOTE_DIR=/tmp/probing-failslow-image

[ -f "$WHEEL" ] || { echo "need WHEEL=$WHEEL"; exit 2; }

export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY all_proxy || true

echo "── export pull secret $PULL_SECRET_NAME ──"
kubectl --kubeconfig="$KUBECONFIG" get secret "$PULL_SECRET_NAME" \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/dockerconfig-muxi.json
# 不打印内容
wc -c /tmp/dockerconfig-muxi.json

echo "── sync via tar|ssh (ais 无可用 sftp subsystem) ──"
SCRIPTS_ROOT="$(cd "$HERE/.." && pwd)"
ssh "$JUMP" "rm -rf /tmp/probing-failslow-src $REMOTE_DIR && mkdir -p /tmp/probing-failslow-src"
# COPYFILE_DISABLE 去掉 macOS xattr 垃圾
export COPYFILE_DISABLE=1
tar -C "$SCRIPTS_ROOT" -cf - \
  image/Dockerfile image/build.sh image/env.defaults image/README.md \
  train_bench_probe.py sidecar_inject.py sidecar_inject_v2.py \
  dump_probing_sql.sh run_case_pipeline_v4.sh run_case_abc.sh \
  accept_loud.py score_dlevel_offline.py score_dlevel_sql.py \
  collect.py dose_recipes.yaml \
  | ssh "$JUMP" "tar -C /tmp/probing-failslow-src -xf -"
cat "$WHEEL" | ssh "$JUMP" "cat > /tmp/probing-full.whl"
cat /tmp/dockerconfig-muxi.json | ssh "$JUMP" "cat > /tmp/dockerconfig-muxi.json"
REMOTE_DIR=/tmp/probing-failslow-src/image

echo "── remote build ──"
ssh "$JUMP" "bash -s" <<EOF
set -euo pipefail
export WHEEL=/tmp/probing-full.whl
export DOCKER_CONFIG_JSON=/tmp/dockerconfig-muxi.json
export BASE_IMAGE='$BASE_IMAGE'
export IMAGE_REPO='${IMAGE_REPO}'
export IMAGE_TAG='${IMAGE_TAG}'
export IMAGE_OUT='${IMAGE_OUT}'
export PUSH='${PUSH:-1}'
chmod +x $REMOTE_DIR/build.sh
bash $REMOTE_DIR/build.sh
# 清理跳板上的 dockerconfig
rm -f /tmp/dockerconfig-muxi.json
EOF

echo "── cleanup local dockerconfig ──"
rm -f /tmp/dockerconfig-muxi.json
echo "remote_build_ais DONE"
