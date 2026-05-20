#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PAPER_RUN_ROOT="${PAPER_RUN_ROOT:-$PWD/runs/paper_logical_$(date +%Y%m%d_%H%M%S)}"
PAPER_REPEATS="${PAPER_REPEATS:-3}"
PAPER_BASE_PORT="${PAPER_BASE_PORT:-3400}"
PAPER_DSM_BYTES="${PAPER_DSM_BYTES:-536870912}"
PAPER_RANDOM_PAGES_LIST="${PAPER_RANDOM_PAGES_LIST:-3000 6000 12000}"
PAPER_RANDOM_UPDATE_PAGES_LIST="${PAPER_RANDOM_UPDATE_PAGES_LIST:-3000 6000}"
PAPER_RANDOM_UPDATE_PASSES="${PAPER_RANDOM_UPDATE_PASSES:-2}"
PAPER_SEQ_WRITE_ROWS_LIST="${PAPER_SEQ_WRITE_ROWS_LIST:-6000 12000}"
PAPER_DSM_BYTES_LIST="${PAPER_DSM_BYTES_LIST:-16777216 67108864 134217728 268435456 536870912}"
PAPER_BP_SIZE_LIST="${PAPER_BP_SIZE_LIST:-5M 16M 32M 64M 128M}"
PAPER_SCAN_PAGES_LIST="${PAPER_SCAN_PAGES_LIST:-3000 6000}"
PAPER_TPCC_CONNS_LIST="${PAPER_TPCC_CONNS_LIST:-1 2 4 8}"
PAPER_TPCH_QIDS="${PAPER_TPCH_QIDS:-1 3 6 12 14 19}"
PAPER_TPCH_QUERY_REPEATS="${PAPER_TPCH_QUERY_REPEATS:-2}"
PAPER_TPCH_QUERY_TIMEOUT_SEC="${PAPER_TPCH_QUERY_TIMEOUT_SEC:-600}"

PAPER_RUN_MICRO_RANDOM="${PAPER_RUN_MICRO_RANDOM:-1}"
PAPER_RUN_MICRO_RANDOM_UPDATE="${PAPER_RUN_MICRO_RANDOM_UPDATE:-0}"
PAPER_RUN_MICRO_SEQ_WRITE="${PAPER_RUN_MICRO_SEQ_WRITE:-0}"
PAPER_RUN_DSM_CAPACITY="${PAPER_RUN_DSM_CAPACITY:-1}"
PAPER_RUN_BP_SENSITIVITY="${PAPER_RUN_BP_SENSITIVITY:-1}"
PAPER_RUN_MICRO_SCAN="${PAPER_RUN_MICRO_SCAN:-1}"
PAPER_RUN_TPCC="${PAPER_RUN_TPCC:-1}"
PAPER_RUN_TPCH="${PAPER_RUN_TPCH:-1}"
PAPER_FAIL_FAST="${PAPER_FAIL_FAST:-0}"

mkdir -p "$PAPER_RUN_ROOT"

MASTER="$PAPER_RUN_ROOT/paper_all.tsv"
HEADER=$'experiment\tworkload\tmode\tconfig\trepeat\tbuf_hit\truntime_sync\truntime_async\tdisk_sync\tdisk_async\twall_time_ns\tlogical_wall_ns\tstatus\tlog'
printf "%s\n" "$HEADER" > "$MASTER"

init_table() {
  local file="$1"
  printf "%s\n" "$HEADER" > "$file"
}

append_summary() {
  local experiment="$1" out_file="$2" config="$3" repeat="$4" summary="$5"
  awk -F'\t' -v OFS='\t' \
      -v experiment="$experiment" \
      -v config="$config" \
      -v repeat="$repeat" '
    NR > 1 {
      print experiment, $2, $3, config, repeat, $4, $6, $7, $9, $10, $11, $12, $17, $18
    }
  ' "$summary" | tee -a "$out_file" >> "$MASTER"
}

append_failed_run() {
  local experiment="$1" out_file="$2" config="$3" repeat="$4" status="$5" log="$6"
  printf "%s\tNA\tNA\t%s\t%s\t0\t0\t0\t0\t0\t0\t0\t%s\t%s\n" \
    "$experiment" "$config" "$repeat" "$status" "$log" | tee -a "$out_file" >> "$MASTER"
}

RUN_SEQ=0
run_one() {
  local experiment="$1" out_file="$2" config="$3" repeat="$4"
  shift 4
  RUN_SEQ=$(( RUN_SEQ + 1 ))
  local run_dir="$PAPER_RUN_ROOT/${experiment}/${config}/r${repeat}"
  local port=$(( PAPER_BASE_PORT + RUN_SEQ ))
  mkdir -p "$run_dir"

  printf "\n[paper-exp] experiment=%s config=%s repeat=%s port=%s\n" \
    "$experiment" "$config" "$repeat" "$port"

  set +e
  env \
    MEASURE_WITH_WINDOW=1 \
    RUN_ROOT="$run_dir" \
    PORT="$port" \
    COST_BUF_NS="${COST_BUF_NS:-100}" \
    COST_DSM_NS="${COST_DSM_NS:-300}" \
    COST_DISK_NS="${COST_DISK_NS:-30000}" \
    "$@" \
    ./run_monitor_workloads_compare.sh > "$run_dir/runner.out" 2> "$run_dir/runner.err"
  local rc=$?
  set -e

  if [[ -f "$run_dir/summary.tsv" ]]; then
    append_summary "$experiment" "$out_file" "$config" "$repeat" "$run_dir/summary.tsv"
  else
    append_failed_run "$experiment" "$out_file" "$config" "$repeat" "FAIL(rc=$rc)" "$run_dir/runner.err"
  fi

  if [[ $rc -ne 0 && "$PAPER_FAIL_FAST" == "1" ]]; then
    exit "$rc"
  fi
}

write_medians() {
  python3 - "$MASTER" "$PAPER_RUN_ROOT/paper_medians.tsv" <<'PY'
import csv
import statistics
import sys
from collections import defaultdict

src, dst = sys.argv[1], sys.argv[2]
groups = defaultdict(list)
with open(src, newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        if row["status"] != "OK":
            continue
        key = (row["experiment"], row["workload"], row["mode"], row["config"])
        groups[key].append(row)

fields = [
    "experiment", "workload", "mode", "config", "n",
    "buf_hit_median", "runtime_sync_median", "runtime_async_median",
    "disk_sync_median", "disk_async_median",
    "wall_time_ns_median", "logical_wall_ns_median",
]
numeric = fields[5:]
source_key = {
    "buf_hit_median": "buf_hit",
    "runtime_sync_median": "runtime_sync",
    "runtime_async_median": "runtime_async",
    "disk_sync_median": "disk_sync",
    "disk_async_median": "disk_async",
    "wall_time_ns_median": "wall_time_ns",
    "logical_wall_ns_median": "logical_wall_ns",
}

with open(dst, "w", newline="") as f:
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for key in sorted(groups):
        rows = groups[key]
        out = {
            "experiment": key[0],
            "workload": key[1],
            "mode": key[2],
            "config": key[3],
            "n": len(rows),
        }
        for field in numeric:
            values = [int(r[source_key[field]]) for r in rows]
            out[field] = str(int(statistics.median(values)))
        writer.writerow(out)
PY
}

write_top_config() {
  {
    printf "PAPER_RUN_ROOT=%s\n" "$PAPER_RUN_ROOT"
    printf "PAPER_REPEATS=%s\n" "$PAPER_REPEATS"
    printf "PAPER_DSM_BYTES=%s\n" "$PAPER_DSM_BYTES"
    printf "PAPER_RANDOM_PAGES_LIST=%s\n" "$PAPER_RANDOM_PAGES_LIST"
    printf "PAPER_RANDOM_UPDATE_PAGES_LIST=%s\n" "$PAPER_RANDOM_UPDATE_PAGES_LIST"
    printf "PAPER_RANDOM_UPDATE_PASSES=%s\n" "$PAPER_RANDOM_UPDATE_PASSES"
    printf "PAPER_SEQ_WRITE_ROWS_LIST=%s\n" "$PAPER_SEQ_WRITE_ROWS_LIST"
    printf "PAPER_DSM_BYTES_LIST=%s\n" "$PAPER_DSM_BYTES_LIST"
    printf "PAPER_BP_SIZE_LIST=%s\n" "$PAPER_BP_SIZE_LIST"
    printf "PAPER_SCAN_PAGES_LIST=%s\n" "$PAPER_SCAN_PAGES_LIST"
    printf "PAPER_TPCC_CONNS_LIST=%s\n" "$PAPER_TPCC_CONNS_LIST"
    printf "PAPER_TPCH_QIDS=%s\n" "$PAPER_TPCH_QIDS"
    printf "PAPER_TPCH_QUERY_REPEATS=%s\n" "$PAPER_TPCH_QUERY_REPEATS"
    printf "PAPER_TPCH_QUERY_TIMEOUT_SEC=%s\n" "$PAPER_TPCH_QUERY_TIMEOUT_SEC"
    printf "COST_BUF_NS=%s\n" "${COST_BUF_NS:-100}"
    printf "COST_DSM_NS=%s\n" "${COST_DSM_NS:-300}"
    printf "COST_DISK_NS=%s\n" "${COST_DISK_NS:-30000}"
    if command -v df >/dev/null 2>&1; then
      df -h /dev/shm 2>/dev/null | sed 's/^/df_shm: /' || true
    fi
  } > "$PAPER_RUN_ROOT/config.txt"
}

write_top_config

MICRO_RANDOM_OUT="$PAPER_RUN_ROOT/paper_micro_random.tsv"
MICRO_RANDOM_UPDATE_OUT="$PAPER_RUN_ROOT/paper_micro_random_update.tsv"
MICRO_SEQ_WRITE_OUT="$PAPER_RUN_ROOT/paper_micro_seq_write.tsv"
DSM_CAPACITY_OUT="$PAPER_RUN_ROOT/paper_dsm_capacity.tsv"
BP_SENSITIVITY_OUT="$PAPER_RUN_ROOT/paper_bp_sensitivity.tsv"
MICRO_SCAN_OUT="$PAPER_RUN_ROOT/paper_micro_scan.tsv"
TPCC_OUT="$PAPER_RUN_ROOT/paper_tpcc.tsv"
TPCH_OUT="$PAPER_RUN_ROOT/paper_tpch.tsv"

init_table "$MICRO_RANDOM_OUT"
init_table "$MICRO_RANDOM_UPDATE_OUT"
init_table "$MICRO_SEQ_WRITE_OUT"
init_table "$DSM_CAPACITY_OUT"
init_table "$BP_SENSITIVITY_OUT"
init_table "$MICRO_SCAN_OUT"
init_table "$TPCC_OUT"
init_table "$TPCH_OUT"

if [[ "$PAPER_RUN_MICRO_RANDOM" == "1" ]]; then
  for pages in $PAPER_RANDOM_PAGES_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "micro_random" "$MICRO_RANDOM_OUT" "pages=${pages}_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=1 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_RANDOM_PAGES="$pages" MICRO_RANDOM_ROWS_PER_PAGE=4 MICRO_RANDOM_WARMUP_PASSES=1 MICRO_RANDOM_PASSES=8 MICRO_RANDOM_STRIDE=997
    done
  done
fi

if [[ "$PAPER_RUN_MICRO_RANDOM_UPDATE" == "1" ]]; then
  for pages in $PAPER_RANDOM_UPDATE_PAGES_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "micro_random_update" "$MICRO_RANDOM_UPDATE_OUT" "pages=${pages}_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=1 RUN_MICRO_SEQ_WRITE=0 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_RANDOM_UPDATE_PAGES="$pages" MICRO_RANDOM_UPDATE_ROWS_PER_PAGE=4 MICRO_RANDOM_UPDATE_WARMUP_PASSES=1 MICRO_RANDOM_UPDATE_PASSES="$PAPER_RANDOM_UPDATE_PASSES" MICRO_RANDOM_UPDATE_STRIDE=997 MICRO_RANDOM_UPDATE_SINGLE_TXN=1
    done
  done
fi

if [[ "$PAPER_RUN_MICRO_SEQ_WRITE" == "1" ]]; then
  for rows in $PAPER_SEQ_WRITE_ROWS_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "micro_seq_write" "$MICRO_SEQ_WRITE_OUT" "insert_rows=${rows}_initial=12000_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 RUN_MICRO_RANDOM_UPDATE=0 RUN_MICRO_SEQ_WRITE=1 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_SEQ_WRITE_INITIAL_ROWS=12000 MICRO_SEQ_WRITE_WARMUP_ROWS=1000 MICRO_SEQ_WRITE_INSERT_ROWS="$rows" MICRO_SEQ_WRITE_SINGLE_TXN=1
    done
  done
fi

if [[ "$PAPER_RUN_DSM_CAPACITY" == "1" ]]; then
  for dsm_bytes in $PAPER_DSM_BYTES_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "dsm_capacity" "$DSM_CAPACITY_OUT" "pages=6000_bp=5M_dsm=${dsm_bytes}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=1 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$dsm_bytes" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_RANDOM_PAGES=6000 MICRO_RANDOM_ROWS_PER_PAGE=4 MICRO_RANDOM_WARMUP_PASSES=1 MICRO_RANDOM_PASSES=8 MICRO_RANDOM_STRIDE=997
    done
  done
fi

if [[ "$PAPER_RUN_BP_SENSITIVITY" == "1" ]]; then
  for bp_size in $PAPER_BP_SIZE_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "bp_sensitivity" "$BP_SENSITIVITY_OUT" "pages=6000_bp=${bp_size}_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=1 \
        MYSQL_BP_SIZE="$bp_size" DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_RANDOM_PAGES=6000 MICRO_RANDOM_ROWS_PER_PAGE=4 MICRO_RANDOM_WARMUP_PASSES=1 MICRO_RANDOM_PASSES=8 MICRO_RANDOM_STRIDE=997
    done
  done
fi

if [[ "$PAPER_RUN_MICRO_SCAN" == "1" ]]; then
  for pages in $PAPER_SCAN_PAGES_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "micro_scan" "$MICRO_SCAN_OUT" "hot_pages=${pages}_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=1 RUN_MICRO_RANDOM=0 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        MICRO_SCAN_HOT_PAGES="$pages" MICRO_SCAN_WARMUP_REPEATS=1 MICRO_SCAN_QUERY_REPEATS=8
    done
  done
fi

if [[ "$PAPER_RUN_TPCC" == "1" ]]; then
  for conns in $PAPER_TPCC_CONNS_LIST; do
    for repeat in $(seq 1 "$PAPER_REPEATS"); do
      run_one "tpcc" "$TPCC_OUT" "w=4_conns=${conns}_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
        RUN_TPCH=0 RUN_TPCC=1 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 \
        MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
        TPCC_W=4 TPCC_CONNS="$conns" TPCC_WARMUP_DURATION=60 TPCC_RAMPUP=0 TPCC_DURATION=180
    done
  done
fi

if [[ "$PAPER_RUN_TPCH" == "1" ]]; then
  for repeat in $(seq 1 "$PAPER_REPEATS"); do
    run_one "tpch" "$TPCH_OUT" "sf1_q1-3-6-12-14-19_bp=5M_dsm=${PAPER_DSM_BYTES}" "$repeat" \
      RUN_TPCH=1 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=0 \
      MYSQL_BP_SIZE=5M DSM_CACHE_BYTES_PER_NODE="$PAPER_DSM_BYTES" FIL_READ_CACHE_MAX_PAGES=131072 \
      TPCH_DATASET=sf1 TPCH_QIDS="$PAPER_TPCH_QIDS" TPCH_WARMUP_REPEATS=1 TPCH_QUERY_REPEATS="$PAPER_TPCH_QUERY_REPEATS" TPCH_QUERY_TIMEOUT_SEC="$PAPER_TPCH_QUERY_TIMEOUT_SEC"
  done
fi

write_medians

printf "\n[paper-exp] done\n"
printf "[paper-exp] raw:    %s\n" "$MASTER"
printf "[paper-exp] median: %s\n" "$PAPER_RUN_ROOT/paper_medians.tsv"
