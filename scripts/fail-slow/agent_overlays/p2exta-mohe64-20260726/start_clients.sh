#!/usr/bin/env bash
# Run on neighbor pod: continuous ib_write_bw clients.
# Args: outer_base size gid qp dur ip0,ip1,ip2,ip3
set -euo pipefail
export MACA_PATH=/opt/maca
export LD_LIBRARY_PATH=${MACA_PATH}/lib:${LD_LIBRARY_PATH:-}
IB=${IB_BIN:-/opt/maca/samples/mccl_tests/ib_perf/tests/ib_write_bw}
OUTER_BASE=$1
SIZE=$2
GID=$3
QP=$4
DUR=$5
IFS=',' read -r -a IPS <<< "$6"
i=0
for ip in "${IPS[@]}"; do
  outer=$((OUTER_BASE + i))
  hca=xscale_$i
  rm -f /tmp/p2exta_cli_$i.out /tmp/p2exta_cli_$i.pid
  setsid bash -c "
    while true; do
      '$IB' -d $hca -F -p $outer -s $SIZE -x $GID -q $QP --force-link=Ethernet -D $DUR $ip \
        >>/tmp/p2exta_cli_$i.out 2>&1 || sleep 1
    done
  " </dev/null >/dev/null 2>&1 &
  echo $! >/tmp/p2exta_cli_$i.pid
  echo "CLI_$i hca=$hca -> $ip:$outer pid=$(cat /tmp/p2exta_cli_$i.pid)"
  i=$((i + 1))
done
sleep 2
for i in 0 1 2 3; do
  if kill -0 "$(cat /tmp/p2exta_cli_$i.pid)" 2>/dev/null; then
    echo "CLI_ALIVE_$i"
  else
    echo "CLI_DEAD_$i"
  fi
done
