#!/usr/bin/env bash
set -euo pipefail

# Reproduce monitor comparison on the copied wyq_mysql snapshot.
# It runs isolated cases for no_dsm, local_cache, and dsm modes.  The
# local_cache mode keeps the read-through hook enabled but disables the DSM
# bridge, so fil_read_cache falls back to the in-process LRU backend.  This is
# useful for ablation: hook/cache layer vs. real DSM runtime backend.
# Each case gets a fresh datadir so writes from TPC-C cannot bleed into the
# other mode. The summary reports calculated monitor cost, not wall time.

COPY_ROOT="${COPY_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
MYSQL_INSTALL="${MYSQL_INSTALL:-$COPY_ROOT/mysql_install_verify}"
WORKLOAD_DIR="${WORKLOAD_DIR:-$COPY_ROOT/workloads}"
DSM_DIR="${DSM_DIR:-$COPY_ROOT/ub2_simulator/dsm_runtime}"
DSM_BUILD="${DSM_BUILD:-$DSM_DIR/build}"
RUN_ROOT="${RUN_ROOT:-$COPY_ROOT/runs/monitor_compare_$(date +%Y%m%d_%H%M%S)}"

PORT="${PORT:-3310}"
SOCKET="${SOCKET:-/tmp/copy_wyq_monitor.sock}"
PID_FILE="${PID_FILE:-/tmp/copy_wyq_monitor.pid}"
MYSQLX_SOCK="${MYSQLX_SOCK:-/tmp/copy_wyq_mysqlx.sock}"
MYSQL_USER="${MYSQL_USER:-root}"

COST_BUF_NS="${COST_BUF_NS:-100}"
COST_DSM_NS="${COST_DSM_NS:-300}"
COST_DISK_NS="${COST_DISK_NS:-30000}"
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-16777216}"
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-16384}"
MYSQL_BP_SIZE="${MYSQL_BP_SIZE:-5M}"
LOAD_MYSQL_BP_SIZE="${LOAD_MYSQL_BP_SIZE:-512M}"
MEASURE_WITH_WINDOW="${MEASURE_WITH_WINDOW:-0}"
MONITOR_DUMP_TRIGGER="${MONITOR_DUMP_TRIGGER:-/tmp/fil_read_cache_dump}"
SKIP_SHM_CHECK="${SKIP_SHM_CHECK:-0}"

TPCH_DB="${TPCH_DB:-tpch}"
TPCH_DATASET="${TPCH_DATASET:-smoke}"
TPCH_QUERY_REPEATS="${TPCH_QUERY_REPEATS:-2}"
TPCH_WARMUP_REPEATS="${TPCH_WARMUP_REPEATS:-0}"
TPCH_SF="${TPCH_SF:-1}"
TPCH_QIDS="${TPCH_QIDS:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22}"
TPCH_QUERY_TIMEOUT_SEC="${TPCH_QUERY_TIMEOUT_SEC:-600}"
TPCH_FAIL_FAST="${TPCH_FAIL_FAST:-0}"
TPCH_KIT="${TPCH_KIT:-$WORKLOAD_DIR/tpch-kit}"
TPCH_DBGEN="${TPCH_DBGEN:-$TPCH_KIT/dbgen}"
QGEN="${QGEN:-$TPCH_DBGEN/qgen}"

TPCC_DB="${TPCC_DB:-tpcc_monitor}"
TPCC_W="${TPCC_W:-1}"
TPCC_CONNS="${TPCC_CONNS:-1}"
TPCC_RAMPUP="${TPCC_RAMPUP:-5}"
TPCC_DURATION="${TPCC_DURATION:-60}"
TPCC_WARMUP_DURATION="${TPCC_WARMUP_DURATION:-0}"
TPCC_FLUSH="${TPCC_FLUSH:-1}"

MICRO_SCAN_DB="${MICRO_SCAN_DB:-micro_scan_monitor}"
MICRO_SCAN_HOT_PAGES="${MICRO_SCAN_HOT_PAGES:-1500}"
MICRO_SCAN_QUERY_REPEATS="${MICRO_SCAN_QUERY_REPEATS:-6}"
MICRO_SCAN_WARMUP_REPEATS="${MICRO_SCAN_WARMUP_REPEATS:-0}"

MICRO_RANDOM_DB="${MICRO_RANDOM_DB:-micro_random_lookup_monitor}"
MICRO_RANDOM_PAGES="${MICRO_RANDOM_PAGES:-1500}"
MICRO_RANDOM_ROWS_PER_PAGE="${MICRO_RANDOM_ROWS_PER_PAGE:-4}"
MICRO_RANDOM_PASSES="${MICRO_RANDOM_PASSES:-6}"
MICRO_RANDOM_WARMUP_PASSES="${MICRO_RANDOM_WARMUP_PASSES:-0}"
MICRO_RANDOM_STRIDE="${MICRO_RANDOM_STRIDE:-997}"

RUN_TPCH="${RUN_TPCH:-1}"
RUN_TPCC="${RUN_TPCC:-1}"
RUN_MICRO_SCAN="${RUN_MICRO_SCAN:-1}"
RUN_MICRO_RANDOM="${RUN_MICRO_RANDOM:-1}"
RUN_NO_DSM="${RUN_NO_DSM:-1}"
RUN_DSM_MODE="${RUN_DSM_MODE:-1}"
RUN_MICRO="${RUN_MICRO:-}"
if [[ -n "$RUN_MICRO" ]]; then
  RUN_MICRO_SCAN="$RUN_MICRO"
  RUN_MICRO_RANDOM="$RUN_MICRO"
fi

usage() {
  sed -n '1,70p' "$0"
  cat <<USAGE

Environment knobs:
  TPCH_DATASET=smoke|sf1       default: smoke
  TPCH_QUERY_REPEATS=N         default: 2
  TPCH_QIDS="1 ... 22"         default: all 22 TPC-H queries
  TPCH_SF=N                    default: 1, qgen scale factor
  TPCH_QUERY_TIMEOUT_SEC=N     default: 600 per generated query
  TPCH_FAIL_FAST=0/1           default: 0, continue after query failure
  TPCC_W=N                     default: 1
  TPCC_CONNS=N                 default: 1
  TPCC_RAMPUP=N                default: 5
  TPCC_DURATION=N              default: 60
  MICRO_SCAN_HOT_PAGES=N       default: 1500
  MICRO_SCAN_QUERY_REPEATS=N   default: 6
  MICRO_RANDOM_PAGES=N         default: 1500
  MICRO_RANDOM_ROWS_PER_PAGE=N default: 4
  MICRO_RANDOM_PASSES=N        default: 6
  MICRO_RANDOM_STRIDE=N        default: 997
  MYSQL_BP_SIZE=SIZE            default: 5M
  LOAD_MYSQL_BP_SIZE=SIZE       default: 512M
  MEASURE_WITH_WINDOW=0/1       default: 0, use tag=window delta after warmup
  SKIP_SHM_CHECK=0/1             default: 0, fail early if /dev/shm is too small
  TPCH_WARMUP_REPEATS=N         default: 0
  TPCC_WARMUP_DURATION=N        default: 0
  MICRO_SCAN_WARMUP_REPEATS=N   default: 0
  MICRO_RANDOM_WARMUP_PASSES=N  default: 0
  COST_BUF_NS=N                default: 100
  COST_DSM_NS=N                default: 300
  COST_DISK_NS=N               default: 30000
  RUN_TPCH=0/RUN_TPCC=0/RUN_MICRO_SCAN=0/RUN_MICRO_RANDOM=0
                                skip selected workloads
  RUN_ROOT=/path               output directory
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MYSQL="$MYSQL_INSTALL/bin/mysql"
MYSQLD="$MYSQL_INSTALL/bin/mysqld"
MYSQLADMIN="$MYSQL_INSTALL/bin/mysqladmin"

mkdir -p "$RUN_ROOT"
SUMMARY="$RUN_ROOT/summary.tsv"
SUMMARY_RAW="$RUN_ROOT/summary.raw.tsv"
printf "case\tworkload\tmode\tbuf_hit\truntime_hit\truntime_sync\truntime_async\tdisk_read\tdisk_sync\tdisk_async\twall_time_ns\tpfs_pages_read\tpfs_data_reads\tpfs_bp_reads\tpfs_read_ahead\tstatus\tlog\n" > "$SUMMARY_RAW"

say() { printf '\n[copy-monitor] %s\n' "$*"; }

cleanup_runtime_files() {
  rm -f "$SOCKET" "$PID_FILE" "$MYSQLX_SOCK" "$MYSQLX_SOCK.lock" /tmp/mysqlx.sock /tmp/mysqlx.sock.lock "$MONITOR_DUMP_TRIGGER"
}

write_run_config() {
  local out="$RUN_ROOT/config.txt"
  {
    printf "COPY_ROOT=%s\n" "$COPY_ROOT"
    printf "MYSQL_INSTALL=%s\n" "$MYSQL_INSTALL"
    printf "WORKLOAD_DIR=%s\n" "$WORKLOAD_DIR"
    printf "RUN_ROOT=%s\n" "$RUN_ROOT"
    printf "MEASURE_WITH_WINDOW=%s\n" "$MEASURE_WITH_WINDOW"
    printf "SKIP_SHM_CHECK=%s\n" "$SKIP_SHM_CHECK"
    printf "COST_BUF_NS=%s\n" "$COST_BUF_NS"
    printf "COST_DSM_NS=%s\n" "$COST_DSM_NS"
    printf "COST_DISK_NS=%s\n" "$COST_DISK_NS"
    printf "DSM_CACHE_BYTES_PER_NODE=%s\n" "$DSM_CACHE_BYTES_PER_NODE"
    printf "FIL_READ_CACHE_MAX_PAGES=%s\n" "$FIL_READ_CACHE_MAX_PAGES"
    printf "MYSQL_BP_SIZE=%s\n" "$MYSQL_BP_SIZE"
    printf "LOAD_MYSQL_BP_SIZE=%s\n" "$LOAD_MYSQL_BP_SIZE"
    printf "TPCH_DATASET=%s\n" "$TPCH_DATASET"
    printf "TPCH_QIDS=%s\n" "$TPCH_QIDS"
    printf "TPCH_WARMUP_REPEATS=%s\n" "$TPCH_WARMUP_REPEATS"
    printf "TPCH_QUERY_REPEATS=%s\n" "$TPCH_QUERY_REPEATS"
    printf "TPCC_W=%s\n" "$TPCC_W"
    printf "TPCC_CONNS=%s\n" "$TPCC_CONNS"
    printf "TPCC_WARMUP_DURATION=%s\n" "$TPCC_WARMUP_DURATION"
    printf "TPCC_RAMPUP=%s\n" "$TPCC_RAMPUP"
    printf "TPCC_DURATION=%s\n" "$TPCC_DURATION"
    printf "MICRO_SCAN_HOT_PAGES=%s\n" "$MICRO_SCAN_HOT_PAGES"
    printf "MICRO_SCAN_WARMUP_REPEATS=%s\n" "$MICRO_SCAN_WARMUP_REPEATS"
    printf "MICRO_SCAN_QUERY_REPEATS=%s\n" "$MICRO_SCAN_QUERY_REPEATS"
    printf "MICRO_RANDOM_PAGES=%s\n" "$MICRO_RANDOM_PAGES"
    printf "MICRO_RANDOM_ROWS_PER_PAGE=%s\n" "$MICRO_RANDOM_ROWS_PER_PAGE"
    printf "MICRO_RANDOM_WARMUP_PASSES=%s\n" "$MICRO_RANDOM_WARMUP_PASSES"
    printf "MICRO_RANDOM_PASSES=%s\n" "$MICRO_RANDOM_PASSES"
    printf "MICRO_RANDOM_STRIDE=%s\n" "$MICRO_RANDOM_STRIDE"
    printf "RUN_TPCH=%s\n" "$RUN_TPCH"
    printf "RUN_TPCC=%s\n" "$RUN_TPCC"
    printf "RUN_MICRO_SCAN=%s\n" "$RUN_MICRO_SCAN"
    printf "RUN_MICRO_RANDOM=%s\n" "$RUN_MICRO_RANDOM"
    if command -v df >/dev/null 2>&1; then
      df -h /dev/shm 2>/dev/null | sed 's/^/df_shm: /' || true
    fi
  } > "$out"
}

mysql_cmd() {
  "$MYSQL" --protocol=socket -S "$SOCKET" -uroot "$@"
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

init_datadir() {
  local datadir="$1" log="$2"
  rm -rf "$datadir"
  mkdir -p "$datadir"
  cleanup_runtime_files
  "$MYSQLD" --initialize-insecure --basedir="$MYSQL_INSTALL" --datadir="$datadir" --log-error="$log" --user="$MYSQL_USER"
}

MYSQLD_PID=""
start_mysql() {
  local case_name="$1" datadir="$2" log="$3" mode="$4"
  shift 4
  local envs=(
    FIL_CACHE_MONITOR_ENABLE=1
    FIL_CACHE_MONITOR_COST_BUF_NS="$COST_BUF_NS"
    FIL_CACHE_MONITOR_COST_RUNTIME_NS="$COST_DSM_NS"
    FIL_CACHE_MONITOR_COST_DISK_NS="$COST_DISK_NS"
    FIL_READ_CACHE_MAX_PAGES="$FIL_READ_CACHE_MAX_PAGES"
  )
  if [[ "$mode" == "dsm" ]]; then
    envs+=(FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1 DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE")
  elif [[ "$mode" == "local_cache" ]]; then
    envs+=(FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=0)
  else
    envs+=(FIL_READ_CACHE_ENABLE=0 DSM_BRIDGE_ENABLE=0)
  fi

  cleanup_runtime_files
  : > "$log"
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
    --user="$MYSQL_USER" \
    "$@" > "$log" 2>&1 &
  MYSQLD_PID=$!
  if ! wait_mysql "$MYSQLD_PID"; then
    tail -n 160 "$log" >&2 || true
    return 1
  fi
  say "started $case_name pid=$MYSQLD_PID"
}


start_mysql_load() {
  local case_name="$1" datadir="$2" log="$3"
  cleanup_runtime_files
  : > "$log"
  env FIL_CACHE_MONITOR_ENABLE=0 FIL_READ_CACHE_ENABLE=0 DSM_BRIDGE_ENABLE=0 "$MYSQLD" \
    --datadir="$datadir" \
    --socket="$SOCKET" \
    --port="$PORT" \
    --pid-file="$PID_FILE" \
    --mysqlx=OFF \
    --performance_schema=ON \
    --secure-file-priv= \
    --innodb-buffer-pool-size="$LOAD_MYSQL_BP_SIZE" \
    --innodb-buffer-pool-chunk-size=1M \
    --innodb-buffer-pool-instances=1 \
    --innodb-flush-method=O_DIRECT_NO_FSYNC \
    --innodb-doublewrite=OFF \
    --log-error-verbosity=1 \
    --user="$MYSQL_USER" > "$log" 2>&1 &
  MYSQLD_PID=$!
  if ! wait_mysql "$MYSQLD_PID"; then
    tail -n 160 "$log" >&2 || true
    return 1
  fi
  say "started $case_name load pid=$MYSQLD_PID"
}

stop_mysql() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "$MYSQLD_PID" 2>/dev/null; then
    "$MYSQLADMIN" --protocol=socket -S "$SOCKET" -uroot shutdown >/dev/null 2>&1 || kill "$MYSQLD_PID" 2>/dev/null || true
    wait "$MYSQLD_PID" 2>/dev/null || true
  fi
  MYSQLD_PID=""
  cleanup_runtime_files
}

SIM_PID=""
check_shm_capacity() {
  [[ "$SKIP_SHM_CHECK" == "1" ]] && return 0
  command -v df >/dev/null 2>&1 || return 0

  local shm_bytes required_bytes
  shm_bytes="$(df -B1 /dev/shm 2>/dev/null | awk 'NR==2 {print $2}' || true)"
  [[ -n "$shm_bytes" && "$shm_bytes" =~ ^[0-9]+$ ]] || return 0
  required_bytes=$(( DSM_CACHE_BYTES_PER_NODE * 3 ))
  if (( shm_bytes < required_bytes )); then
    cat >&2 <<EOF
/dev/shm is too small for this DSM cache configuration.
  /dev/shm bytes:              $shm_bytes
  required bytes, 3 DSM nodes: $required_bytes
  DSM_CACHE_BYTES_PER_NODE:    $DSM_CACHE_BYTES_PER_NODE

Recreate the Docker container with a larger --shm-size, for example --shm-size=4g,
or lower DSM_CACHE_BYTES_PER_NODE. Set SKIP_SHM_CHECK=1 only if this check is
wrong for your environment.
EOF
    return 1
  fi
}

start_dsm_runtime() {
  say "starting DSM runtime"
  check_shm_capacity
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
  for m in 1 2 3; do
    [[ -e "/dev/shm/virtual_node0/obmm_shmdev${m}" ]] || { echo "missing DSM shm obmm_shmdev${m}" >&2; exit 4; }
  done
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

kv() {
  local line="$1" key="$2"
  sed -n "s/.*${key}=\([0-9][0-9]*\).*/\1/p" <<< "$line"
}

stats_value() {
  local line="$1" key="$2"
  local v
  v="$(kv "$line" "$key")"
  printf "%s" "${v:-0}"
}

stats_delta() {
  local before="$1" after="$2" key="$3"
  local b a
  b="$(stats_value "$before" "$key")"
  a="$(stats_value "$after" "$key")"
  printf "%s" "$(( a - b ))"
}

status_value() {
  local file="$1" key="$2"
  awk -F'\t' -v k="$key" '$1==k {print $2}' "$file" | tail -n 1
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
  local log="$1" label="$2"
  local before_count
  before_count="$(grep -c '\[fil_cache_monitor\]\[stats\] tag=window' "$log" 2>/dev/null || true)"
  rm -f "$MONITOR_DUMP_TRIGGER"
  : > "$MONITOR_DUMP_TRIGGER"
  if ! wait_for_window_dump "$log" "$before_count"; then
    echo "failed to collect monitor window dump: $label" >&2
    return 1
  fi
}

collect_summary() {
  local case_name="$1" workload="$2" mode="$3" log="$4" pfs="$5" status="$6" wall_ns="$7" start_stats="${8:-}" end_stats="${9:-}"
  local stats
  stats="$(grep '\[fil_cache_monitor\]\[stats\] tag=close' "$log" | tail -n 1 || true)"

  local buf runtime runtime_sync runtime_async disk disk_sync disk_async pages_read data_reads bp_reads read_ahead
  if [[ -n "$start_stats" && -n "$end_stats" ]]; then
    buf="$(stats_delta "$start_stats" "$end_stats" buf_hit)"
    runtime="$(stats_delta "$start_stats" "$end_stats" runtime_hit)"
    runtime_sync="$(stats_delta "$start_stats" "$end_stats" runtime_hit_sync)"
    runtime_async="$(stats_delta "$start_stats" "$end_stats" runtime_hit_async)"
    disk="$(stats_delta "$start_stats" "$end_stats" disk_read)"
    disk_sync="$(stats_delta "$start_stats" "$end_stats" disk_read_sync)"
    disk_async="$(stats_delta "$start_stats" "$end_stats" disk_read_async)"
  else
    buf="$(stats_value "$stats" buf_hit)"
    runtime="$(stats_value "$stats" runtime_hit)"
    runtime_sync="$(stats_value "$stats" runtime_hit_sync)"
    runtime_async="$(stats_value "$stats" runtime_hit_async)"
    disk="$(stats_value "$stats" disk_read)"
    disk_sync="$(stats_value "$stats" disk_read_sync)"
    disk_async="$(stats_value "$stats" disk_read_async)"
  fi
  pages_read="$(status_value "$pfs" Innodb_pages_read)"; pages_read="${pages_read:-0}"
  data_reads="$(status_value "$pfs" Innodb_data_reads)"; data_reads="${data_reads:-0}"
  bp_reads="$(status_value "$pfs" Innodb_buffer_pool_read_requests)"; bp_reads="${bp_reads:-0}"
  read_ahead="$(status_value "$pfs" Innodb_buffer_pool_read_ahead)"; read_ahead="${read_ahead:-0}"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$case_name" "$workload" "$mode" "$buf" "$runtime" "$runtime_sync" "$runtime_async" \
    "$disk" "$disk_sync" "$disk_async" "$wall_ns" "$pages_read" "$data_reads" \
    "$bp_reads" "$read_ahead" "$status" "$log" >> "$SUMMARY_RAW"
  rewrite_adjusted_summary
}

rewrite_adjusted_summary() {
  awk -F'\t' -v OFS='\t' \
      -v cost_buf="$COST_BUF_NS" \
      -v cost_dsm="$COST_DSM_NS" \
      -v cost_disk="$COST_DISK_NS" '
    NR == 1 {
      header = $0
      next
    }
    {
      rows[++n] = $0
      workloads[n] = $2
      modes[n] = $3
      logical[n] = ($4 + 0) * cost_buf + ($6 + 0) * cost_dsm + ($9 + 0) * cost_disk
      wall[n] = $11 + 0
      if ($3 == "no_dsm") {
        base_wall[$2] = $11 + 0
        base_logical[$2] = logical[n]
      }
    }
    END {
      print "case", "workload", "mode", "buf_hit", "runtime_hit", "runtime_sync", \
            "runtime_async", "disk_read", "disk_sync", "disk_async", \
            "wall_time_ns", "logical_wall_ns", "pfs_pages_read", "pfs_data_reads", \
            "pfs_bp_reads", "pfs_read_ahead", "status", "log"
      for (i = 1; i <= n; ++i) {
        split(rows[i], f, FS)
        bw = (workloads[i] in base_wall) ? base_wall[workloads[i]] : wall[i]
        bl = (workloads[i] in base_logical) ? base_logical[workloads[i]] : logical[i]
        adjusted = sprintf("%.0f", bw - bl + logical[i])
        print f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], \
              f[11], adjusted, f[12], f[13], f[14], f[15], f[16], f[17]
      }
    }
  ' "$SUMMARY_RAW" > "$SUMMARY"
}

capture_pfs() {
  local out="$1"
  mysql_cmd -N -B -e "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME IN ('Innodb_pages_read','Innodb_data_reads','Innodb_buffer_pool_read_requests','Innodb_buffer_pool_read_ahead') ORDER BY VARIABLE_NAME" > "$out"
}

capture_tpcc_counts() {
  local db="$1" out="$2"
  mysql_cmd -N -B "$db" > "$out" <<'SQL'
SELECT 'warehouse', COUNT(*) FROM warehouse
UNION ALL SELECT 'district', COUNT(*) FROM district
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'history', COUNT(*) FROM history
UNION ALL SELECT 'new_orders', COUNT(*) FROM new_orders
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_line', COUNT(*) FROM order_line
UNION ALL SELECT 'item', COUNT(*) FROM item
UNION ALL SELECT 'stock', COUNT(*) FROM stock;
SQL
}

load_tpch() {
  local db="$1"
  local data_dir="$WORKLOAD_DIR/tpch_data/$TPCH_DATASET"
  DATA_DIR="$data_dir" ROOT_DIR="$COPY_ROOT" WORKLOAD_DIR="$WORKLOAD_DIR" MYSQL_BIN="$MYSQL" MYSQL_SOCKET="$SOCKET" \
    "$WORKLOAD_DIR/load_tpch_sf1.sh" "$db" > "$RUN_ROOT/load_${db}.log" 2>&1
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

run_tpch_query() {
  local db="$1" out="$2"
  local sql_dir="$RUN_ROOT/tpch_sql_${db}"
  local status_file="${out%.out}_query_status.tsv"
  local failures=0
  mkdir -p "$sql_dir"
  : > "$out"
  printf "qid\trepeat\tstatus\trc\tseconds\tsql\n" > "$status_file"

  if [[ ! -x "$QGEN" ]]; then
    echo "qgen not executable: $QGEN" >&2
    return 2
  fi

  for rep in $(seq 1 "$TPCH_QUERY_REPEATS"); do
    for qid in $TPCH_QIDS; do
      local seed=$(( 100000 + rep * 1009 + qid * 17 ))
      local qfile="$sql_dir/q${qid}_r${rep}.sql"
      local runfile="$sql_dir/q${qid}_r${rep}_run.sql"
      ( cd "$TPCH_DBGEN" && DSS_QUERY=queries DSS_CONFIG=. "$QGEN" -v -c -s "$TPCH_SF" -r "$seed" "$qid" ) > "$qfile"
      echo ";" >> "$qfile"
      normalize_tpch_sql "$qfile"
      {
        printf "SET SESSION max_execution_time=%s;\\n" "$(( TPCH_QUERY_TIMEOUT_SEC * 1000 ))"
        cat "$qfile"
      } > "$runfile"

      local start elapsed rc status
      start="$(date +%s)"
      {
        printf "\\n-- query=%s repeat=%s file=%s\\n" "$qid" "$rep" "$qfile"
        timeout --kill-after=5s "${TPCH_QUERY_TIMEOUT_SEC}s" "$MYSQL" --protocol=socket -S "$SOCKET" -uroot "$db" < "$runfile"
      } >> "$out"
      rc=$?
      elapsed=$(( $(date +%s) - start ))
      status="OK"
      if [[ $rc -ne 0 ]]; then
        failures=$(( failures + 1 ))
        if [[ $rc -eq 124 || $rc -eq 137 ]]; then
          status="TIMEOUT"
        else
          status="FAIL"
        fi
        printf "\\n-- query=%s repeat=%s status=%s rc=%s seconds=%s\\n" "$qid" "$rep" "$status" "$rc" "$elapsed" >> "$out"
        mysql_cmd -N -B -e "SELECT ID FROM INFORMATION_SCHEMA.PROCESSLIST WHERE USER='root' AND COMMAND='Query' AND INFO NOT LIKE '%PROCESSLIST%';" \
          | while read -r query_id; do mysql_cmd -e "KILL QUERY $query_id;" >/dev/null 2>&1 || true; done
        if [[ "$TPCH_FAIL_FAST" == "1" ]]; then
          printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$qid" "$rep" "$status" "$rc" "$elapsed" "$qfile" >> "$status_file"
          return "$rc"
        fi
      fi
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$qid" "$rep" "$status" "$rc" "$elapsed" "$qfile" >> "$status_file"
    done
  done
  [[ $failures -eq 0 ]]
}

load_tpcc() {
  local db="$1"
  ROOT_DIR="$COPY_ROOT" MYSQL_BIN="$MYSQL" MYSQL_SOCKET="$SOCKET" MYSQL_LIB_DIR="$MYSQL_INSTALL/lib" \
    "$WORKLOAD_DIR/prepare_tpcc.sh" "$db" "$TPCC_W" > "$RUN_ROOT/load_${db}.log" 2>&1
}

run_tpcc_workload() {
  local db="$1" out="$2" err="$3"
  mysql_cmd -e "SET GLOBAL innodb_flush_log_at_trx_commit=${TPCC_FLUSH};" >/dev/null
  export LD_LIBRARY_PATH="$MYSQL_INSTALL/lib:${LD_LIBRARY_PATH:-}"
  (
    cd "$WORKLOAD_DIR/tpcc-mysql"
    ./tpcc_start -h127.0.0.1 -P"$PORT" -d "$db" -u root -p '' -w "$TPCC_W" -c "$TPCC_CONNS" -r "$TPCC_RAMPUP" -l "$TPCC_DURATION"
  ) > "$out" 2> "$err"
}


load_micro_scan() {
  local db="$1"
  local rows=$(( MICRO_SCAN_HOT_PAGES * 30 ))
  mysql_cmd <<SQL
DROP DATABASE IF EXISTS \`$db\`;
CREATE DATABASE \`$db\`;
USE \`$db\`;
CREATE TABLE hot (
  id INT PRIMARY KEY AUTO_INCREMENT,
  pad1 VARBINARY(255) NOT NULL,
  pad2 VARBINARY(255) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=COMPACT;
INSERT INTO hot (pad1, pad2) VALUES (REPEAT('X',255), REPEAT('Y',255));
SQL

  local cur=1
  while [[ $cur -lt $rows ]]; do
    mysql_cmd "$db" -e "INSERT INTO hot (pad1, pad2) SELECT pad1, pad2 FROM hot LIMIT $cur;" >/dev/null
    cur=$(( cur * 2 ))
  done
  mysql_cmd "$db" -e "ANALYZE TABLE hot;" >/dev/null
  mysql_cmd -e "FLUSH TABLES \`$db\`.hot WITH READ LOCK; UNLOCK TABLES;" >/dev/null || true
}

run_micro_scan_workload() {
  local db="$1" out="$2"
  : > "$out"
  for i in $(seq 1 "$MICRO_SCAN_QUERY_REPEATS"); do
    mysql_cmd "$db" -N -e "SELECT SUM(CRC32(pad1) + CRC32(pad2)) FROM hot;" >> "$out"
  done
}


load_micro_random_lookup() {
  local db="$1"
  local rows=$(( MICRO_RANDOM_PAGES * MICRO_RANDOM_ROWS_PER_PAGE ))
  mysql_cmd <<SQL
DROP DATABASE IF EXISTS \`$db\`;
CREATE DATABASE \`$db\`;
USE \`$db\`;
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

  local cur=1
  while [[ $cur -lt $rows ]]; do
    mysql_cmd "$db" -e "INSERT INTO hot (pad01, pad02, pad03, pad04, pad05, pad06, pad07, pad08, pad09, pad10, pad11, pad12, pad13, pad14, pad15, pad16) SELECT pad01, pad02, pad03, pad04, pad05, pad06, pad07, pad08, pad09, pad10, pad11, pad12, pad13, pad14, pad15, pad16 FROM hot LIMIT $cur;" >/dev/null
    cur=$(( cur * 2 ))
  done
  mysql_cmd "$db" -e "DELETE FROM hot WHERE id > $rows; ANALYZE TABLE hot;" >/dev/null
  mysql_cmd -e "FLUSH TABLES \`$db\`.hot WITH READ LOCK; UNLOCK TABLES;" >/dev/null || true
}

run_micro_random_lookup_workload() {
  local db="$1" out="$2"
  local sql="$RUN_ROOT/${db}_random_lookup.sql"
  : > "$out"
  : > "$sql"
  {
    echo "USE \`$db\`;"
    for pass in $(seq 1 "$MICRO_RANDOM_PASSES"); do
      for i in $(seq 0 $(( MICRO_RANDOM_PAGES - 1 ))); do
        local page=$(( (i * MICRO_RANDOM_STRIDE) % MICRO_RANDOM_PAGES ))
        local id=$(( page * MICRO_RANDOM_ROWS_PER_PAGE + 1 ))
        echo "SELECT LENGTH(pad01) + LENGTH(pad16) FROM hot FORCE INDEX(PRIMARY) WHERE id = $id;"
      done
    done
  } > "$sql"
  mysql_cmd -N < "$sql" > "$out"
}

run_workload_once() {
  local workload="$1" out_prefix="$2"
  case "$workload" in
    TPCH) run_tpch_query "$TPCH_DB" "${out_prefix}_tpch.out" ;;
    TPCC) run_tpcc_workload "$TPCC_DB" "${out_prefix}_tpcc.out" "${out_prefix}_tpcc.err" ;;
    MICRO_SCAN) run_micro_scan_workload "$MICRO_SCAN_DB" "${out_prefix}_micro_scan.out" ;;
    MICRO_RANDOM_LOOKUP) run_micro_random_lookup_workload "$MICRO_RANDOM_DB" "${out_prefix}_micro_random_lookup.out" ;;
    *) echo "unknown workload: $workload" >&2; return 2 ;;
  esac
}

run_warmup_if_needed() {
  local workload="$1" out_prefix="$2"
  case "$workload" in
    TPCH)
      [[ "$TPCH_WARMUP_REPEATS" -gt 0 ]] || return 0
      local saved_repeats="$TPCH_QUERY_REPEATS"
      local rc
      TPCH_QUERY_REPEATS="$TPCH_WARMUP_REPEATS"
      run_tpch_query "$TPCH_DB" "${out_prefix}_warmup_tpch.out"
      rc=$?
      TPCH_QUERY_REPEATS="$saved_repeats"
      return "$rc"
      ;;
    TPCC)
      [[ "$TPCC_WARMUP_DURATION" -gt 0 ]] || return 0
      local saved_rampup="$TPCC_RAMPUP" saved_duration="$TPCC_DURATION"
      local rc
      TPCC_RAMPUP=0
      TPCC_DURATION="$TPCC_WARMUP_DURATION"
      run_tpcc_workload "$TPCC_DB" "${out_prefix}_warmup_tpcc.out" "${out_prefix}_warmup_tpcc.err"
      rc=$?
      TPCC_RAMPUP="$saved_rampup"
      TPCC_DURATION="$saved_duration"
      return "$rc"
      ;;
    MICRO_SCAN)
      [[ "$MICRO_SCAN_WARMUP_REPEATS" -gt 0 ]] || return 0
      local saved_scan_repeats="$MICRO_SCAN_QUERY_REPEATS"
      local rc
      MICRO_SCAN_QUERY_REPEATS="$MICRO_SCAN_WARMUP_REPEATS"
      run_micro_scan_workload "$MICRO_SCAN_DB" "${out_prefix}_warmup_micro_scan.out"
      rc=$?
      MICRO_SCAN_QUERY_REPEATS="$saved_scan_repeats"
      return "$rc"
      ;;
    MICRO_RANDOM_LOOKUP)
      [[ "$MICRO_RANDOM_WARMUP_PASSES" -gt 0 ]] || return 0
      local saved_random_passes="$MICRO_RANDOM_PASSES"
      local rc
      MICRO_RANDOM_PASSES="$MICRO_RANDOM_WARMUP_PASSES"
      run_micro_random_lookup_workload "$MICRO_RANDOM_DB" "${out_prefix}_warmup_micro_random_lookup.out"
      rc=$?
      MICRO_RANDOM_PASSES="$saved_random_passes"
      return "$rc"
      ;;
    *) echo "unknown workload: $workload" >&2; return 2 ;;
  esac
}

run_case() {
  local workload="$1" mode="$2"
  local case_name="${workload}_${mode}"
  local datadir="$RUN_ROOT/data_${case_name}"
  local init_log="$RUN_ROOT/${case_name}_init.log"
  local mysqld_log="$RUN_ROOT/${case_name}_mysqld.log"
  local pfs="$RUN_ROOT/${case_name}_pfs.tsv"
  local status="OK"

  say "case $case_name"
  init_datadir "$datadir" "$init_log"

  start_mysql_load "${case_name}_prepare" "$datadir" "$RUN_ROOT/${case_name}_prepare_mysqld.log"
  case "$workload" in
    TPCH) load_tpch "$TPCH_DB" ;;
    TPCC) load_tpcc "$TPCC_DB" ;;
    MICRO_SCAN) load_micro_scan "$MICRO_SCAN_DB" ;;
    MICRO_RANDOM_LOOKUP) load_micro_random_lookup "$MICRO_RANDOM_DB" ;;
    *) echo "unknown workload: $workload" >&2; return 2 ;;
  esac
  case "$workload" in
    TPCH) [[ -f "$RUN_ROOT/load_${TPCH_DB}.log" ]] && cp "$RUN_ROOT/load_${TPCH_DB}.log" "$RUN_ROOT/${case_name}_load.log" ;;
    TPCC)
      [[ -f "$RUN_ROOT/load_${TPCC_DB}.log" ]] && cp "$RUN_ROOT/load_${TPCC_DB}.log" "$RUN_ROOT/${case_name}_load.log"
      capture_tpcc_counts "$TPCC_DB" "$RUN_ROOT/${case_name}_tpcc_counts_after_load.tsv" || true
      ;;
  esac
  stop_mysql

  start_mysql "$case_name" "$datadir" "$mysqld_log" "$mode"
  mysql_cmd -e "FLUSH STATUS; TRUNCATE TABLE performance_schema.file_summary_by_event_name;" >/dev/null || true
  if [[ "$workload" == "TPCC" ]]; then
    capture_tpcc_counts "$TPCC_DB" "$RUN_ROOT/${case_name}_tpcc_counts_before_workload.tsv" || true
  fi

  local warmup_rc=0
  if [[ "$MEASURE_WITH_WINDOW" == "1" ]]; then
    say "warmup $case_name"
    set +e
    run_warmup_if_needed "$workload" "$RUN_ROOT/${case_name}"
    warmup_rc=$?
    set -e
    [[ $warmup_rc -eq 0 ]] || status="FAIL(warmup_rc=$warmup_rc)"
    mysql_cmd -e "FLUSH STATUS; TRUNCATE TABLE performance_schema.file_summary_by_event_name;" >/dev/null || true
  fi

  local start_stats="" end_stats=""
  if [[ "$MEASURE_WITH_WINDOW" == "1" && $warmup_rc -eq 0 ]]; then
    if ! start_stats="$(trigger_window_dump "$mysqld_log" "${case_name}_start")"; then
      status="FAIL(window_dump_start)"
      start_stats=""
    fi
  fi

  local start_ns end_ns wall_ns
  start_ns="$(date +%s%N)"
  set +e
  run_workload_once "$workload" "$RUN_ROOT/${case_name}"
  local rc=$?
  set -e
  end_ns="$(date +%s%N)"
  wall_ns=$(( end_ns - start_ns ))
  [[ $rc -eq 0 ]] || status="FAIL(rc=$rc)"
  if [[ "$MEASURE_WITH_WINDOW" == "1" && $warmup_rc -eq 0 && -n "$start_stats" ]]; then
    end_stats="$(trigger_window_dump "$mysqld_log" "${case_name}_end")" || {
      status="FAIL(window_dump)"
      end_stats=""
    }
  fi
  if [[ -n "${MYSQLD_PID:-}" ]] && ! kill -0 "$MYSQLD_PID" 2>/dev/null; then
    status="FAIL(mysqld_exit)"
  fi

  if [[ "$workload" == "TPCC" ]]; then
    capture_tpcc_counts "$TPCC_DB" "$RUN_ROOT/${case_name}_tpcc_counts_after_workload.tsv" || true
  fi

  capture_pfs "$pfs" || true
  stop_mysql
  collect_summary "$case_name" "$workload" "$mode" "$mysqld_log" "$pfs" "$status" "$wall_ns" "$start_stats" "$end_stats"
}

say "copy root: $COPY_ROOT"
say "run root:  $RUN_ROOT"
say "cost model: buf=${COST_BUF_NS}ns dsm=${COST_DSM_NS}ns disk=${COST_DISK_NS}ns"
say "mysql bp size: ${MYSQL_BP_SIZE}"
write_run_config

if [[ "$RUN_NO_DSM" == "1" && "$RUN_TPCH" == "1" ]]; then
  run_case TPCH no_dsm
fi

if [[ "$RUN_NO_DSM" == "1" && "$RUN_TPCC" == "1" ]]; then
  run_case TPCC no_dsm
fi
if [[ "$RUN_NO_DSM" == "1" && "$RUN_MICRO_SCAN" == "1" ]]; then
  run_case MICRO_SCAN no_dsm
fi
if [[ "$RUN_NO_DSM" == "1" && "$RUN_MICRO_RANDOM" == "1" ]]; then
  run_case MICRO_RANDOM_LOOKUP no_dsm
fi

if [[ "${RUN_LOCAL_CACHE:-0}" == "1" ]]; then
  if [[ "$RUN_TPCH" == "1" ]]; then
    run_case TPCH local_cache
  fi
  if [[ "$RUN_TPCC" == "1" ]]; then
    run_case TPCC local_cache
  fi
  if [[ "$RUN_MICRO_SCAN" == "1" ]]; then
    run_case MICRO_SCAN local_cache
  fi
  if [[ "$RUN_MICRO_RANDOM" == "1" ]]; then
    run_case MICRO_RANDOM_LOOKUP local_cache
  fi
fi

if [[ "$RUN_DSM_MODE" == "1" ]]; then
  start_dsm_runtime
  if [[ "$RUN_TPCH" == "1" ]]; then
    run_case TPCH dsm
  fi
  if [[ "$RUN_TPCC" == "1" ]]; then
    run_case TPCC dsm
  fi
  if [[ "$RUN_MICRO_SCAN" == "1" ]]; then
    run_case MICRO_SCAN dsm
  fi
  if [[ "$RUN_MICRO_RANDOM" == "1" ]]; then
    run_case MICRO_RANDOM_LOOKUP dsm
  fi
  stop_dsm_runtime
fi

say "summary: $SUMMARY"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
