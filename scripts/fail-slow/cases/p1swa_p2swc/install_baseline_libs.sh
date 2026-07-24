#!/usr/bin/env bash
# 在本批 yjr-p1swa pods 上铺 Greyhound / XPUTimer stub .so
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
if [[ ! -f \$CODE/greyhound/libmcclprobe.so ]]; then
  cat > \$CODE/greyhound/mcclprobe.cpp <<'CPPEOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
__attribute__((constructor)) static void gh_init(void) {
  fprintf(stderr, \"[mcclprobe] Greyhound probe loaded pid=%d\\n\", getpid());
}
CPPEOF
  g++ -shared -fPIC -O2 -o \$CODE/greyhound/libmcclprobe.so \$CODE/greyhound/mcclprobe.cpp -ldl -lpthread || true
fi
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
  g++ -shared -fPIC -O2 -o \$CODE/xputimer/libxpu_timer_metax.so \$CODE/xputimer/hook.cpp -ldl -lpthread || true
fi
ls -la \$CODE/greyhound/libmcclprobe.so \$CODE/xputimer/libxpu_timer_metax.so 2>/dev/null || true
echo BASELINE_LIBS_OK
"
}

for pod in "${ARR[@]}"; do
  install_one "$pod" &
done
wait
echo "all baseline libs done"
