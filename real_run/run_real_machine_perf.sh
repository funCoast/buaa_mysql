#!/usr/bin/env bash
set -euo pipefail

# Real-machine performance entry for the MySQL + DSM cache project.
# This wrapper intentionally keeps only the workloads that are useful for
# final real-hardware comparison: microbench, TPC-C, and TPC-H.
#
# It expects the project workspace to already contain:
#   run_monitor_workloads_compare.sh
#   mysql_install_verify/
#   workloads/
#   ub2_simulator/dsm_runtime/ or a real DSM backend wired into the same env.

PROJECT_ROOT="${PROJECT_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
RUNNER="${RUNNER:-$PROJECT_ROOT/run_monitor_workloads_compare.sh}"
TPCH_ISOLATED_RUNNER="${TPCH_ISOLATED_RUNNER:-$PROJECT_ROOT/run_tpch_query_windows_isolated.sh}"
REAL_RUN_ROOT="${REAL_RUN_ROOT:-$PROJECT_ROOT/runs/real_machine_perf_$(date +%Y%m%d_%H%M%S)}"

REAL_REPEATS="${REAL_REPEATS:-3}"
REAL_BASE_PORT="${REAL_BASE_PORT:-4100}"

# Cost model is still recorded for continuity, but wall_time_ns is the primary
# metric on real hardware.
COST_BUF_NS="${COST_BUF_NS:-100}"
COST_DSM_NS="${COST_DSM_NS:-300}"
COST_DISK_NS="${COST_DISK_NS:-30000}"

MYSQL_BP_SIZE="${MYSQL_BP_SIZE:-5M}"
LOAD_MYSQL_BP_SIZE="${LOAD_MYSQL_BP_SIZE:-512M}"
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-4294967296}"
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-1048576}"

# Workload switches.
REAL_RUN_MICRO_RANDOM="${REAL_RUN_MICRO_RANDOM:-1}"
REAL_RUN_MICRO_SCAN="${REAL_RUN_MICRO_SCAN:-1}"
REAL_RUN_MICRO_RANDOM_UPDATE="${REAL_RUN_MICRO_RANDOM_UPDATE:-1}"
REAL_RUN_TPCC="${REAL_RUN_TPCC:-1}"
REAL_RUN_TPCH="${REAL_RUN_TPCH:-1}"
REAL_FAIL_FAST="${REAL_FAIL_FAST:-0}"

# Microbench parameters.
REAL_RANDOM_PAGES_LIST="${REAL_RANDOM_PAGES_LIST:-3000 6000 12000}"
REAL_RANDOM_PASSES="${REAL_RANDOM_PASSES:-8}"
REAL_RANDOM_WARMUP_PASSES="${REAL_RANDOM_WARMUP_PASSES:-2}"

REAL_SCAN_PAGES_LIST="${REAL_SCAN_PAGES_LIST:-3000 6000}"
REAL_SCAN_REPEATS="${REAL_SCAN_REPEATS:-8}"
REAL_SCAN_WARMUP_REPEATS="${REAL_SCAN_WARMUP_REPEATS:-2}"

REAL_RANDOM_UPDATE_PAGES_LIST="${REAL_RANDOM_UPDATE_PAGES_LIST:-800 1500}"
REAL_RANDOM_UPDATE_PASSES="${REAL_RANDOM_UPDATE_PASSES:-2}"
REAL_RANDOM_UPDATE_WARMUP_PASSES="${REAL_RANDOM_UPDATE_WARMUP_PASSES:-2}"

# TPC-C/TPC-H parameters.
REAL_TPCC_W="${REAL_TPCC_W:-4}"
REAL_TPCC_CONNS_LIST="${REAL_TPCC_CONNS_LIST:-1 2 4 8}"
REAL_TPCC_WARMUP_DURATION="${REAL_TPCC_WARMUP_DURATION:-60}"
REAL_TPCC_RAMPUP="${REAL_TPCC_RAMPUP:-0}"
REAL_TPCC_DURATION="${REAL_TPCC_DURATION:-180}"

REAL_TPCH_DATASET="${REAL_TPCH_DATASET:-sf1}"
REAL_TPCH_QIDS="${REAL_TPCH_QIDS:-1 3 6 12 14 19}"
REAL_TPCH_ISOLATED="${REAL_TPCH_ISOLATED:-1}"
REAL_TPCH_WARMUP_REPEATS="${REAL_TPCH_WARMUP_REPEATS:-2}"
REAL_TPCH_QUERY_REPEATS="${REAL_TPCH_QUERY_REPEATS:-2}"
REAL_TPCH_QUERY_TIMEOUT_SEC="${REAL_TPCH_QUERY_TIMEOUT_SEC:-600}"

mkdir -p "$REAL_RUN_ROOT"
cd "$PROJECT_ROOT"

if [[ ! -x "$RUNNER" ]]; then
  echo "runner not executable: $RUNNER" >&2
  echo "Set PROJECT_ROOT to the copy_wyq_mysql workspace or set RUNNER explicitly." >&2
  exit 2
fi

MASTER="$REAL_RUN_ROOT/real_all.tsv"
MEDIAN="$REAL_RUN_ROOT/real_medians.tsv"
HEADER=$'experiment\tworkload\tmode\tconfig\trepeat\tbuf_hit\truntime_sync\truntime_async\tdisk_sync\tdisk_async\twall_time_ns\tlogical_io_cost_ns\tlogical_wall_ns\tstatus\tlog'
printf "%s\n" "$HEADER" > "$MASTER"

write_config() {
  {
    printf "PROJECT_ROOT=%s\n" "$PROJECT_ROOT"
    printf "RUNNER=%s\n" "$RUNNER"
    printf "TPCH_ISOLATED_RUNNER=%s\n" "$TPCH_ISOLATED_RUNNER"
    printf "REAL_RUN_ROOT=%s\n" "$REAL_RUN_ROOT"
    printf "REAL_REPEATS=%s\n" "$REAL_REPEATS"
    printf "MYSQL_BP_SIZE=%s\n" "$MYSQL_BP_SIZE"
    printf "LOAD_MYSQL_BP_SIZE=%s\n" "$LOAD_MYSQL_BP_SIZE"
    printf "DSM_CACHE_BYTES_PER_NODE=%s\n" "$DSM_CACHE_BYTES_PER_NODE"
    printf "FIL_READ_CACHE_MAX_PAGES=%s\n" "$FIL_READ_CACHE_MAX_PAGES"
    printf "COST_BUF_NS=%s\n" "$COST_BUF_NS"
    printf "COST_DSM_NS=%s\n" "$COST_DSM_NS"
    printf "COST_DISK_NS=%s\n" "$COST_DISK_NS"
    printf "REAL_RANDOM_PAGES_LIST=%s\n" "$REAL_RANDOM_PAGES_LIST"
    printf "REAL_SCAN_PAGES_LIST=%s\n" "$REAL_SCAN_PAGES_LIST"
    printf "REAL_RANDOM_UPDATE_PAGES_LIST=%s\n" "$REAL_RANDOM_UPDATE_PAGES_LIST"
    printf "REAL_TPCC_W=%s\n" "$REAL_TPCC_W"
    printf "REAL_TPCC_CONNS_LIST=%s\n" "$REAL_TPCC_CONNS_LIST"
    printf "REAL_TPCC_DURATION=%s\n" "$REAL_TPCC_DURATION"
    printf "REAL_TPCH_DATASET=%s\n" "$REAL_TPCH_DATASET"
    printf "REAL_TPCH_QIDS=%s\n" "$REAL_TPCH_QIDS"
    printf "REAL_TPCH_ISOLATED=%s\n" "$REAL_TPCH_ISOLATED"
    printf "REAL_TPCH_QUERY_REPEATS=%s\n" "$REAL_TPCH_QUERY_REPEATS"
    date '+created_at=%F %T %Z'
    uname -a | sed 's/^/uname=/'
    if command -v lscpu >/dev/null 2>&1; then
      lscpu | sed 's/^/lscpu: /'
    fi
    if command -v df >/dev/null 2>&1; then
      df -h /dev/shm 2>/dev/null | sed 's/^/df_shm: /' || true
      df -h "$PROJECT_ROOT" 2>/dev/null | sed 's/^/df_project: /' || true
    fi
  } > "$REAL_RUN_ROOT/config.txt"
}

append_summary() {
  local experiment="$1" config="$2" repeat="$3" summary="$4"
  awk -F'\t' -v OFS='\t' \
      -v experiment="$experiment" \
      -v config="$config" \
      -v repeat="$repeat" '
    NR > 1 {
      print experiment, $2, $3, config, repeat, $4, $6, $7, $9, $10, $11, $12, $13, $18, $19
    }
  ' "$summary" >> "$MASTER"
}

append_failed_run() {
  local experiment="$1" config="$2" repeat="$3" status="$4" log="$5"
  printf "%s\tNA\tNA\t%s\t%s\t0\t0\t0\t0\t0\t0\t0\t0\t%s\t%s\n" \
    "$experiment" "$config" "$repeat" "$status" "$log" >> "$MASTER"
}

append_tpch_isolated_summary() {
  local experiment="$1" config_prefix="$2" summary="$3"
  awk -F'\t' -v OFS='\t' \
      -v experiment="$experiment" \
      -v config_prefix="$config_prefix" '
    NR > 1 {
      if (NF >= 15) {
        wall_time_ns = $7
        print experiment, "TPCH_Q" $2, $1, config_prefix "_q=" $2, $3, $8, $9, $10, $11, $12, wall_time_ns, $13, $13, $4, $15
      } else {
        wall_time_ns = $6 * 1000000000
        print experiment, "TPCH_Q" $2, $1, config_prefix "_q=" $2, $3, $7, $8, $9, $10, $11, wall_time_ns, $12, $12, $4, $14
      }
    }
  ' "$summary" >> "$MASTER"
}

append_tpch_isolated_paired_summary() {
  local experiment="$1" config_prefix="$2" paired="$3"
  awk -F'\t' -v OFS='\t' \
      -v experiment="$experiment" \
      -v config_prefix="$config_prefix" '
    NR > 1 {
      workload = "TPCH_Q" $1
      config = config_prefix "_q=" $1
      repeat = $2
      print experiment, workload, "no_dsm", config, repeat, $15, $17, $21, $19, $23, $7, $9, $11, $3, $25
      print experiment, workload, "dsm", config, repeat, $16, $18, $22, $20, $24, $8, $10, $12, $4, $26
    }
  ' "$paired" >> "$MASTER"
}

RUN_SEQ=0
run_one() {
  local experiment="$1" config="$2" repeat="$3"
  shift 3
  RUN_SEQ=$((RUN_SEQ + 1))

  local run_dir="$REAL_RUN_ROOT/$experiment/$config/r$repeat"
  local port=$((REAL_BASE_PORT + RUN_SEQ))
  local socket="/tmp/real_${experiment}_${RUN_SEQ}.sock"
  local pid_file="/tmp/real_${experiment}_${RUN_SEQ}.pid"
  local mysqlx_sock="/tmp/real_${experiment}_${RUN_SEQ}_mysqlx.sock"
  mkdir -p "$run_dir"

  printf "\n[real-run] experiment=%s config=%s repeat=%s port=%s\n" \
    "$experiment" "$config" "$repeat" "$port"

  set +e
  env \
    MEASURE_WITH_WINDOW=1 \
    RUN_ROOT="$run_dir" \
    PORT="$port" \
    SOCKET="$socket" \
    PID_FILE="$pid_file" \
    MYSQLX_SOCK="$mysqlx_sock" \
    MYSQL_BP_SIZE="$MYSQL_BP_SIZE" \
    LOAD_MYSQL_BP_SIZE="$LOAD_MYSQL_BP_SIZE" \
    DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE" \
    FIL_READ_CACHE_MAX_PAGES="$FIL_READ_CACHE_MAX_PAGES" \
    COST_BUF_NS="$COST_BUF_NS" \
    COST_DSM_NS="$COST_DSM_NS" \
    COST_DISK_NS="$COST_DISK_NS" \
    "$@" \
    "$RUNNER" > "$run_dir/runner.out" 2> "$run_dir/runner.err"
  local rc=$?
  set -e

  if [[ -f "$run_dir/summary.tsv" ]]; then
    append_summary "$experiment" "$config" "$repeat" "$run_dir/summary.tsv"
  else
    append_failed_run "$experiment" "$config" "$repeat" "FAIL(rc=$rc)" "$run_dir/runner.err"
  fi

  if [[ $rc -ne 0 && "$REAL_FAIL_FAST" == "1" ]]; then
    exit "$rc"
  fi
}

write_config

if [[ "$REAL_RUN_MICRO_RANDOM" == "1" ]]; then
  for pages in $REAL_RANDOM_PAGES_LIST; do
    for repeat in $(seq 1 "$REAL_REPEATS"); do
      run_one "micro_random_lookup" "pages=${pages}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=1 RUN_MICRO_RANDOM_UPDATE=0 RUN_MICRO_SEQ_WRITE=0 \
        MICRO_RANDOM_PAGES="$pages" MICRO_RANDOM_ROWS_PER_PAGE=4 \
        MICRO_RANDOM_WARMUP_PASSES="$REAL_RANDOM_WARMUP_PASSES" \
        MICRO_RANDOM_PASSES="$REAL_RANDOM_PASSES" MICRO_RANDOM_STRIDE=997
    done
  done
fi

if [[ "$REAL_RUN_MICRO_SCAN" == "1" ]]; then
  for pages in $REAL_SCAN_PAGES_LIST; do
    for repeat in $(seq 1 "$REAL_REPEATS"); do
      run_one "micro_scan" "hot_pages=${pages}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=1 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=0 RUN_MICRO_SEQ_WRITE=0 \
        MICRO_SCAN_HOT_PAGES="$pages" \
        MICRO_SCAN_WARMUP_REPEATS="$REAL_SCAN_WARMUP_REPEATS" \
        MICRO_SCAN_QUERY_REPEATS="$REAL_SCAN_REPEATS"
    done
  done
fi

if [[ "$REAL_RUN_MICRO_RANDOM_UPDATE" == "1" ]]; then
  for pages in $REAL_RANDOM_UPDATE_PAGES_LIST; do
    for repeat in $(seq 1 "$REAL_REPEATS"); do
      run_one "micro_random_update" "pages=${pages}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=1 RUN_MICRO_SEQ_WRITE=0 \
        MICRO_RANDOM_UPDATE_PAGES="$pages" MICRO_RANDOM_UPDATE_ROWS_PER_PAGE=4 \
        MICRO_RANDOM_UPDATE_WARMUP_PASSES="$REAL_RANDOM_UPDATE_WARMUP_PASSES" \
        MICRO_RANDOM_UPDATE_PASSES="$REAL_RANDOM_UPDATE_PASSES" \
        MICRO_RANDOM_UPDATE_STRIDE=997 MICRO_RANDOM_UPDATE_SINGLE_TXN=1
    done
  done
fi

if [[ "$REAL_RUN_TPCC" == "1" ]]; then
  for conns in $REAL_TPCC_CONNS_LIST; do
    for repeat in $(seq 1 "$REAL_REPEATS"); do
      run_one "tpcc" "w=${REAL_TPCC_W}_conns=${conns}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=1 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=0 RUN_MICRO_SEQ_WRITE=0 \
        TPCC_W="$REAL_TPCC_W" TPCC_CONNS="$conns" \
        TPCC_WARMUP_DURATION="$REAL_TPCC_WARMUP_DURATION" \
        TPCC_RAMPUP="$REAL_TPCC_RAMPUP" TPCC_DURATION="$REAL_TPCC_DURATION"
    done
  done
fi

if [[ "$REAL_RUN_TPCH" == "1" ]]; then
  if [[ "$REAL_TPCH_ISOLATED" == "1" ]]; then
    if [[ ! -x "$TPCH_ISOLATED_RUNNER" ]]; then
      echo "TPC-H isolated runner not executable: $TPCH_ISOLATED_RUNNER" >&2
      echo "Copy run_tpch_query_windows_isolated.sh into PROJECT_ROOT or set REAL_TPCH_ISOLATED=0 to use aggregate TPC-H." >&2
      exit 2
    fi
    tpch_config="dataset=${REAL_TPCH_DATASET}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}"
    tpch_run_dir="$REAL_RUN_ROOT/tpch_isolated/${tpch_config}_q=${REAL_TPCH_QIDS// /-}"
    mkdir -p "$tpch_run_dir"
    printf "\n[real-run] experiment=tpch_isolated config=%s repeats=%s\n" "$tpch_config" "$REAL_REPEATS"
    set +e
    env \
      BASE_RUN_ROOT="$tpch_run_dir" \
      MYSQL_BP_SIZE="$MYSQL_BP_SIZE" \
      DSM_CACHE_BYTES_PER_NODE="$DSM_CACHE_BYTES_PER_NODE" \
      FIL_READ_CACHE_MAX_PAGES="$FIL_READ_CACHE_MAX_PAGES" \
      TPCH_QIDS="$REAL_TPCH_QIDS" \
      TPCH_REPEATS="$REAL_REPEATS" \
      TPCH_WARMUP_REPEATS="$REAL_TPCH_WARMUP_REPEATS" \
      TPCH_QUERY_TIMEOUT_SEC="$REAL_TPCH_QUERY_TIMEOUT_SEC" \
      COST_BUF_NS="$COST_BUF_NS" \
      COST_DSM_NS="$COST_DSM_NS" \
      COST_DISK_NS="$COST_DISK_NS" \
      "$TPCH_ISOLATED_RUNNER" > "$tpch_run_dir/runner.out" 2> "$tpch_run_dir/runner.err"
    rc=$?
    set -e
    if [[ -f "$tpch_run_dir/query_windows_isolated_paired.tsv" ]]; then
      append_tpch_isolated_paired_summary "tpch_isolated" "$tpch_config" "$tpch_run_dir/query_windows_isolated_paired.tsv"
    elif [[ -f "$tpch_run_dir/query_windows_isolated.tsv" ]]; then
      append_tpch_isolated_summary "tpch_isolated" "$tpch_config" "$tpch_run_dir/query_windows_isolated.tsv"
    else
      append_failed_run "tpch_isolated" "$tpch_config" "all" "FAIL(rc=$rc)" "$tpch_run_dir/runner.err"
    fi
    if [[ $rc -ne 0 && "$REAL_FAIL_FAST" == "1" ]]; then
      exit "$rc"
    fi
  else
    for repeat in $(seq 1 "$REAL_REPEATS"); do
      run_one "tpch" "dataset=${REAL_TPCH_DATASET}_q=${REAL_TPCH_QIDS// /-}_bp=${MYSQL_BP_SIZE}_dsm=${DSM_CACHE_BYTES_PER_NODE}" "$repeat" \
        RUN_TPCH=1 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=0 RUN_MICRO_SEQ_WRITE=0 \
        TPCH_DATASET="$REAL_TPCH_DATASET" TPCH_QIDS="$REAL_TPCH_QIDS" \
        TPCH_WARMUP_REPEATS="$REAL_TPCH_WARMUP_REPEATS" \
        TPCH_QUERY_REPEATS="$REAL_TPCH_QUERY_REPEATS" \
        TPCH_QUERY_TIMEOUT_SEC="$REAL_TPCH_QUERY_TIMEOUT_SEC"
    done
  fi
fi

python3 "$(dirname "$0")/summarize_real_machine_results.py" "$MASTER" "$MEDIAN"

printf "\n[real-run] done\n"
printf "[real-run] raw:    %s\n" "$MASTER"
printf "[real-run] median: %s\n" "$MEDIAN"
