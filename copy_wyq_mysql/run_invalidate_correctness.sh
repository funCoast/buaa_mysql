#!/usr/bin/env bash
set -euo pipefail

COPY_ROOT="${COPY_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
MYSQL_INSTALL="${MYSQL_INSTALL:-$COPY_ROOT/mysql_install_verify}"
DSM_DIR="${DSM_DIR:-$COPY_ROOT/ub2_simulator/dsm_runtime}"
DSM_BUILD="${DSM_BUILD:-$DSM_DIR/build}"
RUN_ROOT="${RUN_ROOT:-$COPY_ROOT/runs/paper_serial_extra_20260517/invalidate_correctness_$(date +%Y%m%d_%H%M%S)}"

PORT="${PORT:-3901}"
SOCKET="${SOCKET:-/tmp/copy_wyq_invalidate.sock}"
PID_FILE="${PID_FILE:-/tmp/copy_wyq_invalidate.pid}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_BP_SIZE="${MYSQL_BP_SIZE:-5M}"
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-536870912}"
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-131072}"
MONITOR_DUMP_TRIGGER="${MONITOR_DUMP_TRIGGER:-/tmp/fil_read_cache_dump}"

MYSQL="$MYSQL_INSTALL/bin/mysql"
MYSQLD="$MYSQL_INSTALL/bin/mysqld"
MYSQLADMIN="$MYSQL_INSTALL/bin/mysqladmin"

mkdir -p "$RUN_ROOT"

say() { printf '[invalidate-test] %s\n' "$*"; }

cleanup_runtime_files() {
  rm -f "$SOCKET" "$PID_FILE" "$MONITOR_DUMP_TRIGGER"
}

wait_mysql() {
  local pid="$1"
  for _ in $(seq 1 100); do
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

mysql_cmd() {
  "$MYSQL" --protocol=socket -S "$SOCKET" -uroot "$@"
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
}

stop_mysql() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "$MYSQLD_PID" 2>/dev/null; then
    "$MYSQLADMIN" --protocol=socket -S "$SOCKET" -uroot shutdown >/dev/null 2>&1 || kill "$MYSQLD_PID" 2>/dev/null || true
    wait "$MYSQLD_PID" 2>/dev/null || true
  fi
}

trap 'stop_mysql; stop_dsm_runtime; cleanup_runtime_files' EXIT INT TERM

trigger_dump() {
  local tag="$1"
  local before after
  before="$(grep -c '\\[fil_cache_monitor\\]' "$RUN_ROOT/mysqld.log" 2>/dev/null || true)"
  touch "$MONITOR_DUMP_TRIGGER"
  for _ in $(seq 1 200); do
    after="$(grep -c '\\[fil_cache_monitor\\]' "$RUN_ROOT/mysqld.log" 2>/dev/null || true)"
    if [[ "$after" -gt "$before" ]]; then
      grep '\\[fil_read_cache\\]\\[stats\\] tag=window' "$RUN_ROOT/mysqld.log" | tail -1 > "$RUN_ROOT/${tag}_fil_read_cache.stats"
      grep '\\[fil_cache_monitor\\] tag=window' "$RUN_ROOT/mysqld.log" | tail -1 > "$RUN_ROOT/${tag}_monitor.stats"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

kv() {
  local file="$1" key="$2"
  sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p" "$file" | tail -1
}

datadir="$RUN_ROOT/data"
rm -rf "$datadir"
cleanup_runtime_files
start_dsm_runtime

say "initialize datadir"
"$MYSQLD" --initialize-insecure --basedir="$MYSQL_INSTALL" --datadir="$datadir" --log-error="$RUN_ROOT/init.log" --user="$MYSQL_USER"

say "start mysqld"
env \
  FIL_CACHE_MONITOR_ENABLE=1 \
  FIL_CACHE_MONITOR_COST_BUF_NS=100 \
  FIL_CACHE_MONITOR_COST_RUNTIME_NS=300 \
  FIL_CACHE_MONITOR_COST_DISK_NS=30000 \
  FIL_READ_CACHE_ENABLE=1 \
  DSM_BRIDGE_ENABLE=1 \
  DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE" \
  FIL_READ_CACHE_MAX_PAGES="$FIL_READ_CACHE_MAX_PAGES" \
  "$MYSQLD" \
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
    --user="$MYSQL_USER" > "$RUN_ROOT/mysqld.log" 2>&1 &
MYSQLD_PID=$!
wait_mysql "$MYSQLD_PID"

say "load table"
mysql_cmd <<'SQL'
DROP DATABASE IF EXISTS invalidate_monitor;
CREATE DATABASE invalidate_monitor;
USE invalidate_monitor;
CREATE TABLE hot (
  id INT PRIMARY KEY AUTO_INCREMENT,
  marker INT NOT NULL,
  pad VARBINARY(7600) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=COMPACT;
INSERT INTO hot(marker, pad) VALUES (0, REPEAT('A',7600));
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
INSERT INTO hot(marker, pad) SELECT 0, pad FROM hot;
ANALYZE TABLE hot;
SQL

say "warm DSM cache"
mysql_cmd invalidate_monitor -N -B -e "SELECT SUM(LENGTH(pad)) FROM hot FORCE INDEX(PRIMARY);" > "$RUN_ROOT/warmup.out"
trigger_dump "after_warmup" || true

say "update and force flush"
mysql_cmd invalidate_monitor -e "UPDATE hot SET marker=42, pad=REPEAT('B',7600) WHERE id=128;" > "$RUN_ROOT/update.out"
mysql_cmd -e "SET GLOBAL innodb_max_dirty_pages_pct=0; FLUSH TABLES invalidate_monitor.hot WITH READ LOCK; UNLOCK TABLES;" > "$RUN_ROOT/flush.out" 2>&1 || true
mysql_cmd -e "FLUSH TABLES;" >> "$RUN_ROOT/flush.out" 2>&1 || true
sleep 2
trigger_dump "after_update_flush" || true

say "evict buffer pool pressure and validate SQL value"
mysql_cmd invalidate_monitor -N -B -e "SELECT SUM(LENGTH(pad)) FROM hot FORCE INDEX(PRIMARY);" > "$RUN_ROOT/second_scan.out"
mysql_cmd invalidate_monitor -N -B -e "SELECT marker, LENGTH(pad), ASCII(SUBSTRING(pad,1,1)) FROM hot WHERE id=128;" > "$RUN_ROOT/final_value.tsv"
trigger_dump "after_final_read" || true

before_inv="$(kv "$RUN_ROOT/after_warmup_fil_read_cache.stats" invalidate || echo 0)"
after_inv="$(kv "$RUN_ROOT/after_update_flush_fil_read_cache.stats" invalidate || echo 0)"
final_marker="$(awk '{print $1}' "$RUN_ROOT/final_value.tsv")"
final_len="$(awk '{print $2}' "$RUN_ROOT/final_value.tsv")"
final_ascii="$(awk '{print $3}' "$RUN_ROOT/final_value.tsv")"
invalidate_delta=$(( ${after_inv:-0} - ${before_inv:-0} ))
status="OK"
if [[ "$final_marker" != "42" || "$final_len" != "7600" || "$final_ascii" != "66" ]]; then
  status="FAIL_VALUE"
elif [[ "$invalidate_delta" -le 0 ]]; then
  status="OK_VALUE_NO_INVALIDATE_DELTA"
fi

{
  printf "status\tfinal_marker\tfinal_len\tfinal_ascii\tinvalidate_before\tinvalidate_after\tinvalidate_delta\n"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$status" "$final_marker" "$final_len" "$final_ascii" "${before_inv:-0}" "${after_inv:-0}" "$invalidate_delta"
} > "$RUN_ROOT/invalidate_correctness.tsv"

cat "$RUN_ROOT/invalidate_correctness.tsv"
