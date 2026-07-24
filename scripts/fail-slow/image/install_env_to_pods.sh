#!/usr/bin/env bash
# 把「统一镜像」等价环境灌进已有特权 pod（分片传 wheel，避开大文件 EOF）。
# 环境内容与 image/Dockerfile 对齐：Probing_plus 0.2.5 + probe-bundle 脚本 + 变量。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/env.defaults"

export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"
unset ALL_PROXY all_proxy || true
export KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"

WHEEL="${WHEEL:-/tmp/probing-full.whl}"
PODS="${PODS:?need PODS csv}"
NS="${NS:-default}"
SCRIPTS_ROOT="$(cd "$HERE/.." && pwd)"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"

[ -f "$WHEEL" ] || { echo "need WHEEL=$WHEEL"; exit 2; }
md5=$(md5 -q "$WHEEL" 2>/dev/null || md5sum "$WHEEL" | awk '{print $1}')
[ "$md5" = "fe3b76db996fece61033c3c12480f2e9" ] || echo "WARN: wheel md5=$md5 (expected fe3b76db…)"

rm -rf /tmp/wparts_env && mkdir -p /tmp/wparts_env
split -b 4m -d "$WHEEL" /tmp/wparts_env/p
export COPYFILE_DISABLE=1

IFS=',' read -r -a ARR <<< "$PODS"
for pod in "${ARR[@]}"; do
  echo "══ install → $pod ══"
  kubectl -n "$NS" exec "$pod" -- mkdir -p "$LOCAL_CODE/pydeps" "$LOCAL_CODE/out" /tmp/wparts_env
  # scripts
  tar -C "$SCRIPTS_ROOT" -cf - \
    train_bench_probe.py sidecar_inject.py sidecar_inject_v2.py \
    dump_probing_sql.sh run_case_pipeline_v4.sh run_case_abc.sh \
    accept_loud.py score_dlevel_offline.py score_dlevel_sql.py \
    collect.py dose_recipes.yaml \
    | kubectl -n "$NS" exec -i "$pod" -- tar -C "$LOCAL_CODE" -xf -
  kubectl -n "$NS" exec -i "$pod" -- bash -c "cat > $LOCAL_CODE/env.defaults" < "$HERE/env.defaults"
  # wheel parts
  for p in /tmp/wparts_env/p*; do
    bn=$(basename "$p")
    echo "  ↑ $bn"
    for try in 1 2 3 4 5 6; do
      if kubectl -n "$NS" cp "$p" "$pod:/tmp/wparts_env/$bn"; then break; fi
      echo "    retry $try"; sleep 2
      [ "$try" = "6" ] && exit 1
    done
  done
  kubectl -n "$NS" exec "$pod" -- bash -lc "
set -e
cat /tmp/wparts_env/p* > /tmp/probing-0.2.5-cp38-abi3-linux_x86_64.whl
echo size=\$(wc -c </tmp/probing-0.2.5-cp38-abi3-linux_x86_64.whl)
PYDEPS=$LOCAL_CODE/pydeps
rm -rf \$PYDEPS/probing \$PYDEPS/probing-*.dist-info \$PYDEPS/probing.pth \$PYDEPS/probing_hook.py
/opt/conda/bin/python3.12 -m pip install --target=\$PYDEPS --no-deps /tmp/probing-0.2.5-cp38-abi3-linux_x86_64.whl
strings \$PYDEPS/probing/_core.abi3.so | grep -q mx-smi
strings \$PYDEPS/probing/_core.abi3.so | grep -q gpu.utilization
# site-packages 挂 hook：仅 PYTHONPATH 时 .pth 不会被 site 加载
SP=/opt/conda/lib/python3.12/site-packages
ln -sfn \$PYDEPS/probing \$SP/probing
ln -sfn \$PYDEPS/probing-0.2.5.dist-info \$SP/probing-0.2.5.dist-info
ln -sfn \$PYDEPS/probing_hook.py \$SP/probing_hook.py
cp -f \$PYDEPS/probing.pth \$SP/probing.pth
# 禁止把 maca cu-bridge libcuda 塞进 LD_LIBRARY_PATH：cudarc 缺符号会 SIGSEGV
command -v stress-ng >/dev/null || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stress-ng fio) || true
cat > /etc/profile.d/probe-bundle.sh <<'EOT'
export LOCAL_CODE=/workspace/probe-bundle
export LOCAL_OUT=/workspace/probe-bundle/out
export PYTHONPATH=/workspace/probe-bundle/pydeps\${PYTHONPATH:+:\$PYTHONPATH}
export PATH=/workspace/probe-bundle/pydeps/bin:/opt/conda/bin:\$PATH
export PROBING_GPU=on
export PROBING_GPU_SAMPLE_MS=1000
unset PROBING_TORCH_PROFILING
export SIDECAR_WARMUP=8
EOT
/opt/conda/bin/python3.12 -c "import probing; print('probing_import_ok', probing.__file__)"
echo INSTALL_OK $pod
"
done
echo "ALL_PODS_OK"
