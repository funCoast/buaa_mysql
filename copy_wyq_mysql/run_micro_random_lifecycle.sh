#!/usr/bin/env bash
set -euo pipefail

COPY_ROOT="${COPY_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
MYSQL_INSTALL="${MYSQL_INSTALL:-$COPY_ROOT/mysql_install_verify}"
DSM_DIR="${DSM_DIR:-$COPY_ROOT/ub2_simulator/dsm_runtime}"
DSM_BUILD="${DSM_BUILD:-$DSM_DIR/build}"
RUN_ROOT="${RUN_ROOT:-$COPY_ROOT/runs/paper_serial_extra_20260517/micro_random_lifecycle_$(date +%Y%m%d_%H%M%S)}"

PORT="${PORT:-3911}"
SOCKET="${SOCKET:-/tmp/copy_wyq_lifecycle.sock}"
PID_FILE="${PID_FILE:-/tmp/copy_wyq_lifecycle.pid}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_BP_SIZE="${MYSQL_BP_SIZE:-5M}"
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-536870912}"
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-131072}"
MONITOR_DUMP_TRIGGER="${MONITOR_DUMP_TRIGGER:-/tmp/fil_read_cache_dump}"
MICRO_RANDOM_PAGES="${MICRO_RANDOM_PAGES:-3000}"
MICRO_RANDOM_ROWS_PER_PAGE="${MICRO_RANDOM_ROWS_PER_PAGE:-4}"
MICRO_RANDOM_STRIDE="${MICRO_RANDOM_STRIDE:-997}"

MYSQL="$MYSQL_INSTALL/bin/mysql"
MYSQLD="$MYSQL_INSTALL/bin/mysqld"
MYSQLADMIN="$MYSQL_INSTALL/bin/mysqladmin"

mkdir -p "$RUN_ROOT"

say() { printf '[lifecycle-test] %s\n' "$*"; }
mysql_cmd() { "$MYSQL" --protocol=socket -S "$SOCKET" -uroot "$@"; }

cleanup_runtime_files() {
  rm -f "$SOCKET" "$PID_FILE" "$MONITOR_DUMP_TRIGGER"
}

wait_mysql() {
  local pid="$1"
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    if "$MYSQLADMIN" --protocol=socket -S "$SOCKET" -uroot ping >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 1
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
  local label="$1"
  touch "$MONITOR_DUMP_TRIGGER"
  sleep 0.3
  grep '\[fil_read_cache\]\[stats\] tag=window' "$RUN_ROOT/mysqld.log" | tail -1 > "$RUN_ROOT/${label}_fil_read_cache.stats" || true
  grep '\[fil_cache_monitor\]\[stats\] tag=window' "$RUN_ROOT/mysqld.log" | tail -1 > "$RUN_ROOT/${label}_monitor.stats" || true
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
    --ssl=0 \
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

rows=$(( MICRO_RANDOM_PAGES * MICRO_RANDOM_ROWS_PER_PAGE ))
say "load table rows=$rows"
mysql_cmd <<SQL
DROP DATABASE IF EXISTS lifecycle_monitor;
CREATE DATABASE lifecycle_monitor;
USE lifecycle_monitor;
CREATE TABLE hot (
  id INT PRIMARY KEY AUTO_INCREMENT,
  pad01 VARBINARY(255) NOT NULL,
  pad02 VARBINARY(255) NOT NULL,
  pad03 VARBINARY(255) NOT NULL,
  pad04 VARBINARY(255) NOT NULL,
  pad05 VARBINARY(255) NOT NULL,
  pad06 VARBINARY(255) NOT NULL,
  pad07 VARBINARY(255) NOT NULL,
  pad08 VARBINARY(255) NOT NULL,
  pad09 VARBINARY(255) NOT NULL,
  pad10 VARBINARY(255) NOT NULL,
  pad11 VARBINARY(255) NOT NULL,
  pad12 VARBINARY(255) NOT NULL,
  pad13 VARBINARY(255) NOT NULL,
  pad14 VARBINARY(255) NOT NULL,
  pad15 VARBINARY(255) NOT NULL,
  pad16 VARBINARY(255) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=COMPACT;
INSERT INTO hot (
  pad01, pad02, pad03, pad04, pad05, pad06, pad07, pad08,
  pad09, pad10, pad11, pad12, pad13, pad14, pad15, pad16
) VALUES (
  REPEAT('A',255), REPEAT('B',255), REPEAT('C',255), REPEAT('D',255),
  REPEAT('E',255), REPEAT('F',255), REPEAT('G',255), REPEAT('H',255),
  REPEAT('I',255), REPEAT('J',255), REPEAT('K',255), REPEAT('L',255),
  REPEAT('M',255), REPEAT('N',255), REPEAT('O',255), REPEAT('P',255)
);
SQL

cur=1
while [[ "$cur" -lt "$rows" ]]; do
  mysql_cmd lifecycle_monitor -e "INSERT INTO hot (pad01,pad02,pad03,pad04,pad05,pad06,pad07,pad08,pad09,pad10,pad11,pad12,pad13,pad14,pad15,pad16) SELECT pad01,pad02,pad03,pad04,pad05,pad06,pad07,pad08,pad09,pad10,pad11,pad12,pad13,pad14,pad15,pad16 FROM hot LIMIT $cur;" >/dev/null
  cur=$(( cur * 2 ))
done
mysql_cmd lifecycle_monitor -e "DELETE FROM hot WHERE id > $rows; ANALYZE TABLE hot;" >/dev/null

sql="$RUN_ROOT/random_pass.sql"
{
  echo "USE lifecycle_monitor;"
  for i in $(seq 0 $(( MICRO_RANDOM_PAGES - 1 ))); do
    page=$(( (i * MICRO_RANDOM_STRIDE) % MICRO_RANDOM_PAGES ))
    id=$(( page * MICRO_RANDOM_ROWS_PER_PAGE + 1 ))
    echo "SELECT LENGTH(pad01) + LENGTH(pad16) FROM hot FORCE INDEX(PRIMARY) WHERE id = $id;"
  done
} > "$sql"

trigger_dump "baseline"
for phase in pass1_cold_fill pass2_dsm_hit pass3_steady; do
  say "run $phase"
  mysql_cmd -N < "$sql" > "$RUN_ROOT/${phase}.out"
  trigger_dump "$phase"
done

python3 - "$RUN_ROOT" <<'PY'
import os, re, sys
root=sys.argv[1]
phases=['baseline','pass1_cold_fill','pass2_dsm_hit','pass3_steady']
def parse(path):
    if not os.path.exists(path):
        return {}
    line=open(path, errors='ignore').read().strip()
    d={}
    for k in ['backend','get_hit','get_miss','put','invalidate','buf_hit','runtime_hit','runtime_hit_sync','runtime_hit_async','disk_read','disk_read_sync','disk_read_async']:
        m=re.search(k+r'=([^ ]+)', line)
        if m: d[k]=m.group(1)
    return d
rows=[]
prev_cache=prev_mon=None
for p in phases:
    cache=parse(os.path.join(root,p+'_fil_read_cache.stats'))
    mon=parse(os.path.join(root,p+'_monitor.stats'))
    row={'phase':p}
    for k in ['get_hit','get_miss','put','invalidate']:
        v=int(cache.get(k,0) or 0)
        row[k+'_cum']=v
        row[k+'_delta']=0 if prev_cache is None else v-int(prev_cache.get(k,0) or 0)
    for k in ['buf_hit','runtime_hit_sync','runtime_hit_async','disk_read_sync','disk_read_async']:
        v=int(mon.get(k,0) or 0)
        row[k+'_cum']=v
        row[k+'_delta']=0 if prev_mon is None else v-int(prev_mon.get(k,0) or 0)
    rows.append(row)
    prev_cache,prev_mon=cache,mon
fields=['phase','get_hit_delta','get_miss_delta','put_delta','invalidate_delta','buf_hit_delta','runtime_hit_sync_delta','runtime_hit_async_delta','disk_read_sync_delta','disk_read_async_delta','get_hit_cum','get_miss_cum','put_cum','invalidate_cum','buf_hit_cum','runtime_hit_sync_cum','runtime_hit_async_cum','disk_read_sync_cum','disk_read_async_cum']
with open(os.path.join(root,'micro_random_lifecycle.tsv'),'w') as f:
    f.write('\\t'.join(fields)+'\\n')
    for r in rows:
        f.write('\\t'.join(str(r.get(x,0)) for x in fields)+'\\n')
PY

cat "$RUN_ROOT/micro_random_lifecycle.tsv"
