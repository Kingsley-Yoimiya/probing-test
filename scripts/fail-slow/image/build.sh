#!/usr/bin/env bash
# 构建并推送 probing-failslow MetaX 统一镜像。
#
# 前置：
#   1) 本机或跳板有 docker
#   2) 能 pull BASE_IMAGE（用集群 imagePullSecret 登录）
#   3) WHEEL 指向完整 probing-0.2.5 wheel（MD5=fe3b76db996fece61033c3c12480f2e9）
#
# 用法（推荐在 ais-cf3e61a5 上）:
#   scp -r image/ ais-cf3e61a5:/tmp/probing-failslow-image/
#   scp /tmp/probing-full.whl ais-cf3e61a5:/tmp/probing-full.whl
#   # 另把 dockerconfig 写到跳板（勿提交 git）
#   ssh ais-cf3e61a5 'WHEEL=/tmp/probing-full.whl bash /tmp/probing-failslow-image/build.sh'
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/env.defaults"

WHEEL="${WHEEL:-/tmp/probing-full.whl}"
CTX="${CTX:-/tmp/probing-failslow-ctx-$$}"
SCRIPTS_ROOT="$(cd "$HERE/.." && pwd)"
PUSH="${PUSH:-1}"
DOCKER_CONFIG_JSON="${DOCKER_CONFIG_JSON:-}"  # 可选：kube secret 解出的 .dockerconfigjson 路径

die() { echo "FATAL: $*" >&2; exit 2; }

[ -f "$WHEEL" ] || die "missing WHEEL=$WHEEL"
sz=$(wc -c <"$WHEEL" | tr -d ' ')
[ "$sz" -ge 30000000 ] || die "wheel too small ($sz); expect ~30810560"

echo "══ build probing-failslow image ══"
echo "  BASE=$BASE_IMAGE"
echo "  OUT =$IMAGE_OUT"
echo "  WHEEL=$WHEEL ($sz bytes)"

rm -rf "$CTX"
mkdir -p "$CTX/bundle"
cp -f "$WHEEL" "$CTX/probing.whl"
cp -f "$HERE/Dockerfile" "$CTX/Dockerfile"

# 镜像内自洽脚本
for f in \
  train_bench_probe.py sidecar_inject.py sidecar_inject_v2.py \
  dump_probing_sql.sh run_case_pipeline_v4.sh run_case_abc.sh \
  accept_loud.py score_dlevel_offline.py score_dlevel_sql.py \
  collect.py dose_recipes.yaml
do
  [ -f "$SCRIPTS_ROOT/$f" ] && cp -f "$SCRIPTS_ROOT/$f" "$CTX/bundle/"
done
cp -f "$HERE/env.defaults" "$CTX/bundle/env.defaults"

# 登录 registry（优先显式 dockerconfig）
if [ -n "$DOCKER_CONFIG_JSON" ] && [ -f "$DOCKER_CONFIG_JSON" ]; then
  mkdir -p "$HOME/.docker"
  cp -f "$DOCKER_CONFIG_JSON" "$HOME/.docker/config.json"
  echo "  docker config ← $DOCKER_CONFIG_JSON"
fi

echo "── docker pull base ──"
docker pull "$BASE_IMAGE"

echo "── docker build ──"
docker build \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$IMAGE_OUT" \
  "$CTX"

echo "── smoke (no GPU needed for import) ──"
docker run --rm "$IMAGE_OUT" bash -lc '
  export PYTHONPATH=/workspace/probe-bundle/pydeps
  python3.12 -c "import probing; print(probing.__file__)"
  strings /workspace/probe-bundle/pydeps/probing/_core.abi3.so | grep -c mx-smi
  test -x /workspace/probe-bundle/dump_probing_sql.sh
  echo smoke_ok
'

if [ "$PUSH" = "1" ]; then
  echo "── docker push ──"
  docker push "$IMAGE_OUT"
  echo "PUSHED $IMAGE_OUT"
else
  echo "SKIP push (PUSH=0); local tag=$IMAGE_OUT"
fi

echo "$IMAGE_OUT" > "$HERE/.last_image"
echo "DONE → $IMAGE_OUT"
echo "provision: IMAGE=$IMAGE_OUT bash provision_priv_pods.sh apply"
