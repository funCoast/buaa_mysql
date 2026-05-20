#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

RUN_TPCH=0 \
RUN_TPCC=1 \
RUN_MICRO_SCAN=0 \
RUN_MICRO_RANDOM=0 \
TPCC_W="${TPCC_W:-1}" \
TPCC_CONNS="${TPCC_CONNS:-1}" \
TPCC_RAMPUP="${TPCC_RAMPUP:-5}" \
TPCC_DURATION="${TPCC_DURATION:-60}" \
DSM_CACHE_BYTES_PER_NODE="${DSM_CACHE_BYTES_PER_NODE:-16777216}" \
FIL_READ_CACHE_MAX_PAGES="${FIL_READ_CACHE_MAX_PAGES:-16384}" \
RUN_ROOT="${RUN_ROOT:-$PWD/runs/exp_tpcc_$(date +%Y%m%d_%H%M%S)}" \
PORT="${PORT:-3332}" \
./run_monitor_workloads_compare.sh
