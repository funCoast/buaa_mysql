#!/usr/bin/env bash
set -euo pipefail

W="${1:?W required, e.g. 100}"
CONNS="${2:?CONNS required, e.g. 32}"
RAMPUP_SEC="${3:?RAMPUP_SEC required, e.g. 10}"
DURATION_SEC="${4:?DURATION_SEC required, e.g. 600}"
ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${5:-$ROOT_DIR/runs/tpcc_io_ratio_w${W}_c${CONNS}_r${RAMPUP_SEC}_l${DURATION_SEC}_$(date +%Y%m%d_%H%M%S)}"

DB="${DB:?need DB (e.g. tpcc1)}"
TPCC_DIR="${TPCC_DIR:-$SCRIPT_DIR/tpcc-mysql}"
MYSQL_BIN="${MYSQL_BIN:-$ROOT_DIR/mysql_install/bin/mysql}"
MYSQL_SOCKET="${MYSQL_SOCKET:-$ROOT_DIR/tmp/mysql-debug.sock}"
MYSQL_OPTS="${MYSQL_OPTS:---protocol=socket -S $MYSQL_SOCKET -uroot}"

mkdir -p "$OUT_DIR"
MYSQL_ADMIN_CMD=("$MYSQL_BIN" $MYSQL_OPTS)

"${MYSQL_ADMIN_CMD[@]}" -Nse "SELECT 1;" >/dev/null
pfs_on="$(${MYSQL_ADMIN_CMD[@]} -Nse "SELECT @@performance_schema;")"
[[ "$pfs_on" == "1" ]] || { echo "performance_schema is OFF"; exit 1; }

echo -e "flush\tW\tconns\trampup_sec\tduration_sec\tmakespan_wall_sec\tredo_io_sec\tdata_io_sec\tratio_redo_pct\tratio_data_pct\tstatus" > "$OUT_DIR/result.tsv"

pfs_reset() {
  "${MYSQL_ADMIN_CMD[@]}" -e "TRUNCATE TABLE performance_schema.file_summary_by_event_name;" >/dev/null
}

pfs_sum_ps() {
  local ev="$1"
  "${MYSQL_ADMIN_CMD[@]}" -Nse "SELECT IFNULL(SUM(SUM_TIMER_READ)+SUM(SUM_TIMER_WRITE),0) FROM performance_schema.file_summary_by_event_name WHERE EVENT_NAME='${ev}';"
}

ps_to_sec() { awk -v x="$1" 'BEGIN{printf "%.6f", x/1e12}'; }
ratio_pct() { awk -v io="$1" -v w="$2" 'BEGIN{ if (w>0) printf "%.4f", (io/w)*100; else print "0.0000"}'; }

run_one() {
  local flush="$1"
  "${MYSQL_ADMIN_CMD[@]}" -e "SET GLOBAL innodb_flush_log_at_trx_commit=${flush};" >/dev/null
  pfs_reset

  local before_redo before_data after_redo after_data wall out err rc status redo_sec data_sec ratio_redo ratio_data
  before_redo="$(pfs_sum_ps 'wait/io/file/innodb/innodb_log_file')"
  before_data="$(pfs_sum_ps 'wait/io/file/innodb/innodb_data_file')"
  out="$OUT_DIR/tpcc_flush${flush}.out"
  err="$OUT_DIR/tpcc_flush${flush}.err"

  set +e
  /usr/bin/time -f "%e" -o "$OUT_DIR/wall_flush${flush}.tmp" bash -lc "
    set -euo pipefail
    export LD_LIBRARY_PATH='$ROOT_DIR/mysql_install/lib':\"\${LD_LIBRARY_PATH:-}\"
    cd '$TPCC_DIR'
    ./tpcc_start -h127.0.0.1 -P3308 -d '$DB' -u root -p '' -w '$W' -c '$CONNS' -r '$RAMPUP_SEC' -l '$DURATION_SEC'
  " >>"$out" 2>>"$err"
  rc=$?
  set -e

  wall="$(tail -n 1 "$OUT_DIR/wall_flush${flush}.tmp" 2>/dev/null || echo 0)"
  after_redo="$(pfs_sum_ps 'wait/io/file/innodb/innodb_log_file')"
  after_data="$(pfs_sum_ps 'wait/io/file/innodb/innodb_data_file')"
  redo_sec="$(ps_to_sec "$((after_redo - before_redo))")"
  data_sec="$(ps_to_sec "$((after_data - before_data))")"
  ratio_redo="$(ratio_pct "$redo_sec" "$wall")"
  ratio_data="$(ratio_pct "$data_sec" "$wall")"
  status="OK"
  [[ $rc -eq 0 ]] || status="FAIL(rc=$rc)"

  echo -e "${flush}\t${W}\t${CONNS}\t${RAMPUP_SEC}\t${DURATION_SEC}\t${wall}\t${redo_sec}\t${data_sec}\t${ratio_redo}\t${ratio_data}\t${status}" >> "$OUT_DIR/result.tsv"
}

for flush in 0 1 2; do
  run_one "$flush"
done

echo "SCRIPT_DONE"
echo "Saved: $OUT_DIR/result.tsv"
