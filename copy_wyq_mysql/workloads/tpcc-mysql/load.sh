#!/usr/bin/env bash
set -eu

DBNAME="$1"
WH="$2"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3308}"
USER="${USER:-root}"
PASS="${PASS:-}"
STEP="${STEP:-100}"
ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
MYSQL_LIB_DIR="${MYSQL_LIB_DIR:-$ROOT_DIR/mysql_install/lib}"
export LD_LIBRARY_PATH="$MYSQL_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "HOST=$HOST PORT=$PORT DB=$DBNAME WH=$WH STEP=$STEP"
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

pids=()
./tpcc_load -h "$HOST" -P "$PORT" -d "$DBNAME" -u "$USER" -p "$PASS" -w "$WH" -l 1 -m 1 -n "$WH" >> 1.out &
pids+=("$!")

x=1
while [ "$x" -le "$WH" ]
do
  end=$(( x + STEP - 1 ))
  if [ "$end" -gt "$WH" ]; then end="$WH"; fi
  echo "range: $x..$end"
  ./tpcc_load -h "$HOST" -P "$PORT" -d "$DBNAME" -u "$USER" -p "$PASS" -w "$WH" -l 2 -m "$x" -n "$end" >> "2_$x.out" &
  pids+=("$!")
  ./tpcc_load -h "$HOST" -P "$PORT" -d "$DBNAME" -u "$USER" -p "$PASS" -w "$WH" -l 3 -m "$x" -n "$end" >> "3_$x.out" &
  pids+=("$!")
  ./tpcc_load -h "$HOST" -P "$PORT" -d "$DBNAME" -u "$USER" -p "$PASS" -w "$WH" -l 4 -m "$x" -n "$end" >> "4_$x.out" &
  pids+=("$!")
  x=$(( x + STEP ))
done

rc=0
for pid in "${pids[@]}"; do
  wait "$pid" || rc=1
done
exit "$rc"
