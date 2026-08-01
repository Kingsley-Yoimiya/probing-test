#!/usr/bin/env bash
# On client neighbor: continuous ib_write_bw to single server eth0, NLINKS HCAs.
# Args: server_ip outer_base size gid qp dur nlinks
set -euo pipefail
export MACA_PATH=/opt/maca
export LD_LIBRARY_PATH=${MACA_PATH}/lib:${LD_LIBRARY_PATH:-}
IB=${IB_BIN:-/opt/maca/samples/mccl_tests/ib_perf/tests/ib_write_bw}
IP=$1
OUTER_BASE=$2
SIZE=$3
GID=$4
QP=$5
DUR=$6
NLINKS=$7
for i in $(seq 0 $((NLINKS - 1))); do
  outer=$((OUTER_BASE + i))
  hca=xscale_$i
  rm -f /tmp/p2exta_cli_$i.out /tmp/p2exta_cli_$i.pid
  setsid bash -c "
    while true; do
      stdbuf -oL -eL '$IB' -d $hca -F -p $outer -s $SIZE -x $GID -q $QP --force-link=Ethernet -D $DUR $IP \
        >>/tmp/p2exta_cli_$i.out 2>&1 || sleep 1
    done
  " </dev/null >/dev/null 2>&1 &
  echo $! >/tmp/p2exta_cli_$i.pid
  echo "CLI_$i hca=$hca -> $IP:$outer pid=$(cat /tmp/p2exta_cli_$i.pid)"
done
sleep 2
for i in $(seq 0 $((NLINKS - 1))); do
  if kill -0 "$(cat /tmp/p2exta_cli_$i.pid)" 2>/dev/null; then
    echo "CLI_ALIVE_$i"
  else
    echo "CLI_DEAD_$i"
  fi
done
