#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

COPY_ROOT="${COPY_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
MYSQL_INSTALL="${MYSQL_INSTALL:-$COPY_ROOT/mysql_install_verify}"
WORKLOAD_DIR="${WORKLOAD_DIR:-$COPY_ROOT/workloads}"
DSM_DIR="${DSM_DIR:-$COPY_ROOT/ub2_simulator/dsm_runtime}"
DSM_BUILD="${DSM_BUILD:-$DSM_DIR/build}"
SOURCE_RUN="${SOURCE_RUN:-$COPY_ROOT/runs/paper_logical_20260515_153348/tpch/sf1_q1-3-6-12-14-19_bp=5M_dsm=536870912/r1}"
RUN_ROOT="${RUN_ROOT:-$COPY_ROOT/runs/tpch_query_windows_$(date +%Y%m%d_%H%M%S)}"

PORT="${PORT:-3510}"
SOCKET="${SOCKET:-/tmp/copy_wyq_tpch_window.sock}"
PID_FILE="${PID_FILE:-/tmp/copy_wyq_tpch_window.pid}"
MONITOR_DUMP_TRIGGER="${MONITOR_DUMP_TRIGGER:-/tmp/fil_read_cache_dump}"
MYSQL_BP_SIZE="${MYSQL_BP_SIZE:-5M}"
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-536870912}"
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-131072}"
TPCH_QIDS="${TPCH_QIDS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22}"
TPCH_WARMUP_REPEATS="${TPCH_WARMUP_REPEATS:-2}"
TPCH_QUERY_TIMEOUT_SEC="${TPCH_QUERY_TIMEOUT_SEC:-600}"
TPCH_SF="${TPCH_SF:-1}"
COST_BUF_NS="${COST_BUF_NS:-100}"
COST_DSM_NS="${COST_DSM_NS:-300}"
COST_DISK_NS="${COST_DISK_NS:-30000}"

MYSQL="$MYSQL_INSTALL/bin/mysql"
MYSQLD="$MYSQL_INSTALL/bin/mysqld"
MYSQLADMIN="$MYSQL_INSTALL/bin/mysqladmin"
TPCH_DBGEN="${TPCH_DBGEN:-$WORKLOAD_DIR/tpch-kit/dbgen}"
QGEN="${QGEN:-$TPCH_DBGEN/qgen}"

mkdir -p "$RUN_ROOT"
SUMMARY="$RUN_ROOT/query_windows.tsv"
printf "mode\tqid\tstatus\trc\tseconds\twall_time_ns\tbuf_hit\truntime_sync\truntime_async\tdisk_sync\tdisk_async\tlogical_io_cost_ns\tsql\n" > "$SUMMARY"

MYSQLD_PID=""
SIM_PID=""

cleanup_runtime_files() {
  rm -f "$SOCKET" "$PID_FILE" "$MONITOR_DUMP_TRIGGER"
}

wait_mysql() {
  local pid="$1"
  for _ in $(seq 1 120); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    if "$MYSQLADMIN" --protocol=socket -S "$SOCKET" -uroot ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

stop_mysql() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "$MYSQLD_PID" 2>/dev/null; then
    "$MYSQLADMIN" --protocol=socket -S "$SOCKET" -uroot shutdown >/dev/null 2>&1 || kill "$MYSQLD_PID" 2>/dev/null || true
    wait "$MYSQLD_PID" 2>/dev/null || true
  fi
  MYSQLD_PID=""
  cleanup_runtime_files
}

start_dsm_runtime() {
  "$DSM_DIR/cleanup.sh" >/dev/null 2>&1 || true
  "$DSM_DIR/cleanup.sh" --purge-shm >/dev/null 2>&1 || true
  # shellcheck disable=SC1091
  . "$COPY_ROOT/ub2_simulator/sim_env.sh"
  ( cd "$DSM_BUILD" && mpirun -np 4 ./simulator ) > "$RUN_ROOT/simulator.log" 2>&1 &
  SIM_PID=$!
  for _ in $(seq 1 80); do
    [[ -S /tmp/obmm_simulator_node0.sock ]] && break
    sleep 0.2
  done
  ( cd "$DSM_BUILD" && DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE" mpirun -np 4 ./export_client ) > "$RUN_ROOT/export_client.log" 2>&1
}

stop_dsm_runtime() {
  "$DSM_DIR/cleanup.sh" --purge-shm >/dev/null 2>&1 || true
  if [[ -n "${SIM_PID:-}" ]] && kill -0 "$SIM_PID" 2>/dev/null; then
    kill "$SIM_PID" 2>/dev/null || true
    wait "$SIM_PID" 2>/dev/null || true
  fi
  SIM_PID=""
}

trap 'stop_mysql; stop_dsm_runtime' EXIT INT TERM

start_mysql() {
  local mode="$1" datadir="$2" log="$3"
  cleanup_runtime_files
  : > "$log"
  local envs=(
    FIL_CACHE_MONITOR_ENABLE=1
    FIL_CACHE_MONITOR_COST_BUF_NS="$COST_BUF_NS"
    FIL_CACHE_MONITOR_COST_RUNTIME_NS="$COST_DSM_NS"
    FIL_CACHE_MONITOR_COST_DISK_NS="$COST_DISK_NS"
    FIL_READ_CACHE_MAX_PAGES="$FIL_READ_CACHE_MAX_PAGES"
  )
  if [[ "$mode" == "dsm" ]]; then
    envs+=(FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1 DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE")
  else
    envs+=(FIL_READ_CACHE_ENABLE=0 DSM_BRIDGE_ENABLE=0)
  fi
  env "${envs[@]}" "$MYSQLD" \
    --datadir="$datadir" \
    --socket="$SOCKET" \
    --port="$PORT" \
    --pid-file="$PID_FILE" \
    --mysqlx=OFF \
    --performance_schema=ON \
    --secure-file-priv= \
    --innodb-buffer-pool-size="$MYSQL_BP_SIZE" \
    --innodb-buffer-pool-chunk-size=1M \
    --innodb-buffer-pool-instances=1 \
    --innodb-flush-method=O_DIRECT_NO_FSYNC \
    --innodb-doublewrite=OFF \
    --log-error-verbosity=1 \
    --user=root > "$log" 2>&1 &
  MYSQLD_PID=$!
  wait_mysql "$MYSQLD_PID"
}

kv() {
  local line="$1" key="$2"
  sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" <<< "$line"
}

stats_value() {
  local line="$1" key="$2" v
  v="$(kv "$line" "$key")"
  printf "%s" "${v:-0}"
}

stats_delta() {
  local before="$1" after="$2" key="$3"
  printf "%s" "$(( $(stats_value "$after" "$key") - $(stats_value "$before" "$key") ))"
}

wait_for_window_dump() {
  local log="$1" before_count="$2"
  for _ in $(seq 1 200); do
    local count
    count="$(grep -c '\[fil_cache_monitor\]\[stats\] tag=window' "$log" 2>/dev/null || true)"
    if [[ "$count" -gt "$before_count" ]]; then
      grep '\[fil_cache_monitor\]\[stats\] tag=window' "$log" | tail -n 1
      return 0
    fi
    sleep 0.05
  done
  return 1
}

trigger_window_dump() {
  local log="$1" before_count
  before_count="$(grep -c '\[fil_cache_monitor\]\[stats\] tag=window' "$log" 2>/dev/null || true)"
  rm -f "$MONITOR_DUMP_TRIGGER"
  : > "$MONITOR_DUMP_TRIGGER"
  wait_for_window_dump "$log" "$before_count"
}

normalize_tpch_sql() {
  local f="$1"
  local tmp="${f}.tmp"
  perl -0777 -pe 's/;\s*\n(\s*limit\s+-?\d+\s*;)/\n$1/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\blimit\s+-1\s*;/;/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  sed -E "s/\\<date[[:space:]]*'/DATE '/Ig" "$f" > "$tmp" && mv "$tmp" "$f"
  sed -E "s/interval[[:space:]]*'([0-9]+)'[[:space:]]*(day|month|year)/interval \\1 \\2/Ig" "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\b(interval\s+-?\d+\s+(?:day|month|year))\s*\(\s*\d+\s*\)/$1/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\bsubstring\s*\(\s*([^()]+?)\s+from\s+([^()]+?)\s+for\s+([^()]+?)\s*\)/substring($1, $2, $3)/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/(\x27(?:[^\x27]|\x27\x27)*\x27)\s*\|\|\s*(\x27(?:[^\x27]|\x27\x27)*\x27)/concat($1,$2)/ig' "$f" > "$tmp" && mv "$tmp" "$f"
}

prepare_queries() {
  local sql_dir="$RUN_ROOT/tpch_sql"
  mkdir -p "$sql_dir"
  for qid in $TPCH_QIDS; do
    local seed=$(( 200000 + qid * 17 ))
    local qfile="$sql_dir/q${qid}.sql"
    local runfile="$sql_dir/q${qid}_run.sql"
    ( cd "$TPCH_DBGEN" && DSS_QUERY=queries DSS_CONFIG=. "$QGEN" -v -c -s "$TPCH_SF" -r "$seed" "$qid" ) > "$qfile"
    echo ";" >> "$qfile"
    normalize_tpch_sql "$qfile"
    {
      printf "SET SESSION max_execution_time=%s;\n" "$(( TPCH_QUERY_TIMEOUT_SEC * 1000 ))"
      cat "$qfile"
    } > "$runfile"
  done
}

run_one_query() {
  local mode="$1" qid="$2" log="$3" sql="$4" out="$5"
  local before after start_ns end_ns elapsed_ns elapsed rc status buf rs ra ds da logical
  before="$(trigger_window_dump "$log")"
  start_ns="$(date +%s%N)"
  set +e
  timeout --kill-after=5s "${TPCH_QUERY_TIMEOUT_SEC}s" "$MYSQL" --protocol=socket -S "$SOCKET" -uroot tpch < "$sql" > "$out" 2>&1
  rc=$?
  set -e
  end_ns="$(date +%s%N)"
  elapsed_ns=$(( end_ns - start_ns ))
  elapsed=$(( elapsed_ns / 1000000000 ))
  after="$(trigger_window_dump "$log")"
  status="OK"
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then status="TIMEOUT"; else status="FAIL"; fi
  fi
  buf="$(stats_delta "$before" "$after" buf_hit)"
  rs="$(stats_delta "$before" "$after" runtime_hit_sync)"
  ra="$(stats_delta "$before" "$after" runtime_hit_async)"
  ds="$(stats_delta "$before" "$after" disk_read_sync)"
  da="$(stats_delta "$before" "$after" disk_read_async)"
  logical=$(( buf * COST_BUF_NS + rs * COST_DSM_NS + ds * COST_DISK_NS ))
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$mode" "$qid" "$status" "$rc" "$elapsed" "$elapsed_ns" "$buf" "$rs" "$ra" "$ds" "$da" "$logical" "$sql" >> "$SUMMARY"
}

run_mode() {
  local mode="$1"
  local src_datadir="$2"
  local datadir="$RUN_ROOT/data_${mode}"
  local log="$RUN_ROOT/${mode}_mysqld.log"
  rm -rf "$datadir"
  cp -a "$src_datadir" "$datadir"
  if [[ "$mode" == "dsm" ]]; then
    start_dsm_runtime
  fi
  start_mysql "$mode" "$datadir" "$log"
  for warmup_round in $(seq 1 "$TPCH_WARMUP_REPEATS"); do
    for qid in $TPCH_QIDS; do
      "$MYSQL" --protocol=socket -S "$SOCKET" -uroot tpch < "$RUN_ROOT/tpch_sql/q${qid}_run.sql" > "$RUN_ROOT/${mode}_q${qid}_warmup_r${warmup_round}.out" 2>&1 || true
    done
  done
  for qid in $TPCH_QIDS; do
    run_one_query "$mode" "$qid" "$log" "$RUN_ROOT/tpch_sql/q${qid}_run.sql" "$RUN_ROOT/${mode}_q${qid}.out"
  done
  stop_mysql
  if [[ "$mode" == "dsm" ]]; then
    stop_dsm_runtime
  fi
}

prepare_queries
run_mode no_dsm "$SOURCE_RUN/data_TPCH_no_dsm"
run_mode dsm "$SOURCE_RUN/data_TPCH_dsm"
