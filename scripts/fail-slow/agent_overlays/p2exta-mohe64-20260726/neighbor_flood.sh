#!/usr/bin/env bash
# P2-EXT-A 邻居↔邻居 RoCE 持续打流（不碰主战役 HCA）
# 默认：server=yjr-fs-h14411 四 HCA；client=yjr-fs-h14410 四 HCA
set -euo pipefail
ACTION="${1:?start|stop}"
KUBECONFIG="${KUBECONFIG:?}"
NS="${NS:-default}"
CLI_POD="${NEIGHBOR_POD:-yjr-fs-h14410}"
SRV_POD="${FLOOD_SRV_POD:-yjr-fs-h14411}"
INNER_BASE="${FLOOD_INNER_BASE:-18740}"
OUTER_BASE="${FLOOD_OUTER_BASE:-18840}"
GID="${FLOOD_GID:-5}"
SIZE="${FLOOD_SIZE:-1048576}"
QP="${FLOOD_QP:-4}"
DUR="${FLOOD_DUR:-30}"
IB_BIN="${IB_BIN:-/opt/maca/samples/mccl_tests/ib_perf/tests/ib_write_bw}"
NLINKS="${FLOOD_LINKS:-4}"

kx() { kubectl --kubeconfig="$KUBECONFIG" -n "$NS" "$@"; }

stop_all() {
  for pod in "$CLI_POD" "$SRV_POD"; do
    kx exec "$pod" -- bash -c '
      for f in /tmp/p2exta_*.pid; do
        [ -f "$f" ] || continue
        kill -9 $(cat "$f") 2>/dev/null || true
        rm -f "$f"
      done
      killall -9 ib_write_bw socat 2>/dev/null || true
      exit 0
    ' >/dev/null 2>&1 || true
  done
  echo "FLOOD_STOP $(date -Iseconds)"
}

start_all() {
  stop_all
  local sip
  sip=$(kx get pod "$SRV_POD" -o jsonpath='{.status.podIP}')
  echo "SRV_POD=$SRV_POD eth0=$sip links=$NLINKS"

  # servers on SRV_POD: one per HCA
  kx exec "$SRV_POD" -- bash -c "
    set +e
    export MACA_PATH=/opt/maca
    export LD_LIBRARY_PATH=\${MACA_PATH}/lib:\${LD_LIBRARY_PATH:-}
    IB='$IB_BIN'; IP='$sip'
    for i in \$(seq 0 $((NLINKS-1))); do
      inner=\$(($INNER_BASE + i))
      outer=\$(($OUTER_BASE + i))
      hca=xscale_\$i
      setsid \$IB -d \$hca -F -p \$inner -s $SIZE -x $GID -q $QP --force-link=Ethernet \
        </dev/null >/tmp/p2exta_srv_\$i.out 2>&1 &
      echo \$! >/tmp/p2exta_srv_\$i.pid
      sleep 0.5
      setsid socat TCP-LISTEN:\$outer,bind=\$IP,reuseaddr,fork TCP:127.0.0.1:\$inner \
        </dev/null >/tmp/p2exta_socat_\$i.out 2>&1 &
      echo \$! >/tmp/p2exta_socat_\$i.pid
      sleep 0.3
      kill -0 \$(cat /tmp/p2exta_srv_\$i.pid) && kill -0 \$(cat /tmp/p2exta_socat_\$i.pid) \
        && echo SRV_OK_\$i hca=\$hca outer=\$outer || { echo SRV_FAIL_\$i; cat /tmp/p2exta_srv_\$i.out /tmp/p2exta_socat_\$i.out; exit 1; }
    done
  "

  HERE="$(cd "$(dirname "$0")" && pwd)"
  kubectl --kubeconfig="$KUBECONFIG" -n "$NS" cp "$HERE/start_pair_clients.sh" "$CLI_POD:/tmp/p2exta_start_pair_clients.sh"
  kx exec "$CLI_POD" -- bash /tmp/p2exta_start_pair_clients.sh \
    "$sip" "$OUTER_BASE" "$SIZE" "$GID" "$QP" "$DUR" "$NLINKS"
  echo "FLOOD_START $(date -Iseconds) srv=$SRV_POD cli=$CLI_POD links=$NLINKS gid=$GID qp=$QP"
}

case "$ACTION" in
  start) start_all ;;
  stop) stop_all ;;
  *) echo "usage: $0 start|stop"; exit 2 ;;
esac
