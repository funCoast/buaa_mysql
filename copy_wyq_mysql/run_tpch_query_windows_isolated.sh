#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

COPY_ROOT="${COPY_ROOT:-/workspace/ltCopyWorkspace/copy_wyq_mysql}"
BASE_RUN_ROOT="${BASE_RUN_ROOT:-$COPY_ROOT/runs/tpch_query_windows_isolated_$(date +%Y%m%d_%H%M%S)}"
TPCH_QIDS="${TPCH_QIDS:-1 3 6 12 14 19}"
TPCH_REPEATS="${TPCH_REPEATS:-3}"
PORT_BASE="${PORT_BASE:-3610}"

mkdir -p "$BASE_RUN_ROOT"
COMBINED="$BASE_RUN_ROOT/query_windows_isolated.tsv"
PAIRED="$BASE_RUN_ROOT/query_windows_isolated_paired.tsv"
printf "mode\tqid\trepeat\tstatus\trc\tseconds\twall_time_ns\tbuf_hit\truntime_sync\truntime_async\tdisk_sync\tdisk_async\tlogical_io_cost_ns\tsql\trun_root\n" > "$COMBINED"

case_index=0
for repeat in $(seq 1 "$TPCH_REPEATS"); do
  for qid in $TPCH_QIDS; do
    case_index=$((case_index + 1))
    case_root="$BASE_RUN_ROOT/q${qid}_r${repeat}"
    port=$((PORT_BASE + case_index))
    socket="/tmp/copy_wyq_tpch_iso_q${qid}_r${repeat}.sock"
    pid_file="/tmp/copy_wyq_tpch_iso_q${qid}_r${repeat}.pid"
    echo "[tpch-isolated] qid=$qid repeat=$repeat run_root=$case_root"
    RUN_ROOT="$case_root" \
      TPCH_QIDS="$qid" \
      PORT="$port" \
      SOCKET="$socket" \
      PID_FILE="$pid_file" \
      ./run_tpch_query_windows_reuse.sh
    awk -v rep="$repeat" -v rr="$case_root" -F '\t' '
      NR == 1 { next }
      {
        print $1 "\t" $2 "\t" rep "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 "\t" $9 "\t" $10 "\t" $11 "\t" $12 "\t" $13 "\t" rr
      }
    ' "$case_root/query_windows.tsv" >> "$COMBINED"
  done
done

awk -F '\t' '
  NR == 1 { next }
  {
    key = $2 "\t" $3
    keys[key] = 1
    rows[key, $1] = $0
  }
  END {
    print "qid\trepeat\tno_status\tdsm_status\tno_seconds\tdsm_seconds\tno_wall_time_ns\tdsm_wall_time_ns\tno_logical_io_cost_ns\tdsm_logical_io_cost_ns\tno_logical_wall_ns\tdsm_logical_wall_ns\tlogical_wall_reduction_pct\tlogical_io_reduction_pct\tno_buf_hit\tdsm_buf_hit\tno_runtime_sync\tdsm_runtime_sync\tno_disk_sync\tdsm_disk_sync\tno_runtime_async\tdsm_runtime_async\tno_disk_async\tdsm_disk_async\tno_run_root\tdsm_run_root"
    for (key in keys) {
      no = rows[key, "no_dsm"]
      dsm = rows[key, "dsm"]
      if (no == "" || dsm == "") { continue }
      split(key, k, "\t")
      split(no, n, "\t")
      split(dsm, d, "\t")
      no_logical_wall = n[7]
      dsm_logical_wall = n[7] - n[13] + d[13]
      wall_reduction = (no_logical_wall > 0) ? (100.0 * (no_logical_wall - dsm_logical_wall) / no_logical_wall) : 0
      io_reduction = (n[13] > 0) ? (100.0 * (n[13] - d[13]) / n[13]) : 0
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.3f\t%.3f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
        k[1], k[2], n[4], d[4], n[6], d[6], n[7], d[7], n[13], d[13], no_logical_wall, dsm_logical_wall, wall_reduction, io_reduction, \
        n[8], d[8], n[9], d[9], n[11], d[11], n[10], d[10], n[12], d[12], n[15], d[15]
    }
  }
' "$COMBINED" | sort -k1,1n -k2,2n > "$PAIRED"

echo "[tpch-isolated] finished: $BASE_RUN_ROOT"
