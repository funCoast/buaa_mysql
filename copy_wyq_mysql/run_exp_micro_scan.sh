#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

RUN_TPCH=0 \
RUN_TPCC=0 \
RUN_MICRO_SCAN=1 \
RUN_MICRO_RANDOM=0 \
MICRO_SCAN_HOT_PAGES="${MICRO_SCAN_HOT_PAGES:-1500}" \
MICRO_SCAN_QUERY_REPEATS="${MICRO_SCAN_QUERY_REPEATS:-6}" \
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-16777216}" \
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-16384}" \
RUN_ROOT="${RUN_ROOT:-$PWD/runs/exp_micro_scan_$(date +%Y%m%d_%H%M%S)}" \
PORT="${PORT:-3333}" \
./run_monitor_workloads_compare.sh
