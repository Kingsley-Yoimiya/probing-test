#!/usr/bin/env bash
# 在本批 yjr-p1c64 pods 上编译/铺 Greyhound + XPUTimer stub .so（与 deploy_to_pods 同风格）。
# Flight Recorder 仅环境变量，无需 .so。Dynolog 见 NOTES_DYNOLOG.md（管线无 C6）。
set -euo pipefail

PODS="${PODS:?need PODS csv}"
KUBECONFIG="${KUBECONFIG:?need KUBECONFIG}"
NS="${NS:-default}"
LOCAL_CODE="${LOCAL_CODE:-/workspace/probe-bundle}"

export KUBECONFIG
IFS=',' read -r -a ARR <<< "$PODS"

install_one() {
  local pod="$1"
  echo "══ baseline libs → $pod ══"
  kubectl -n "$NS" exec "$pod" -- bash -lc "
set -e
CODE='$LOCAL_CODE'
mkdir -p \"\$CODE/greyhound\" \"\$CODE/xputimer\"
# Greyhound MCCL probe (minimal)
if [[ ! -f \$CODE/greyhound/libmcclprobe.so ]]; then
  cat > \$CODE/greyhound/mcclprobe.cpp <<'CPPEOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
__attribute__((constructor)) static void gh_init(void) {
  fprintf(stderr, \"[mcclprobe] Greyhound probe loaded pid=%d\\n\", getpid());
}
CPPEOF
  g++ -shared -fPIC -O2 -o \$CODE/greyhound/libmcclprobe.so \$CODE/greyhound/mcclprobe.cpp -ldl -lrt -lpthread
fi
# XPUTimer-style hook (minimal)
if [[ ! -f \$CODE/xputimer/libxpu_timer_metax.so ]]; then
  cat > \$CODE/xputimer/hook.cpp <<'CPPEOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
__attribute__((constructor)) static void xt_init(void) {
  fprintf(stderr, \"[xputimer] MetaX hook loaded pid=%d\\n\", getpid());
}
CPPEOF
  g++ -shared -fPIC -O2 -o \$CODE/xputimer/libxpu_timer_metax.so \$CODE/xputimer/hook.cpp -ldl -lpthread
fi
ls -la \$CODE/greyhound/libmcclprobe.so \$CODE/xputimer/libxpu_timer_metax.so
echo BASELINE_LIBS_OK
"
}

for pod in "${ARR[@]}"; do
  install_one "$pod" &
done
wait
echo "all baseline libs done"
