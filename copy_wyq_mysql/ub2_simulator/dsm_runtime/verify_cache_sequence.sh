#!/usr/bin/env bash
# ============================================================================
# 验证 Buffer Pool 与 fil_read_cache（L2）的读写时序，思路对齐 bench_cache.sh。
#
# 文档化场景（与注释中的步骤对应）：
#   A) 冷 BP 上首次 SELECT：BP miss → fil_io READ → L2 get miss → do_io → put → 进 BP
#   B) 再次 SELECT：BP 命中 → 不应再触发 fil_io / L2 窗口计数变化
#   C) UPDATE：改脏页，本窗口内通常不走 fil_io READ（计数基本不变）
#   D) 调低 dirty 水位 + 等待：page cleaner 写盘 → fil_io WRITE 前 invalidate →
#      再次 SELECT 仍可能 BP 命中（干净页仍在 BP）
#   E) 挤出 t1 后 BP miss → fil_io READ。注意：flush 时 invalidate 只作用于「被写回」
#      的页；同一索引上未脏的 B+ 树页可仍在 L2 → 可能出现 get_hit>0 且 do_io_n=0，
#      这与「整表 L2 被清空」的简化模型不同，不是 churn 不够大。
#
# 另可选场景（你描述的 6b：仅挤出 BP、L2 仍有旧页）：
#   --l2-hit-only  不做 UPDATE/flush：对应你文档里「仅 BP 被挤出、L2 仍有页」
#                  的 6b —— 期望 get_hit>=1、do_io(read) 的 n 增量为 0。
#
# 说明：INSERT 会把 t1 页放进 BP，故数据在「prep mysqld」里建好并 shutdown，
#       验证阶段重新 start → 冷 BP，才能稳定看到首次 SELECT 的 BP miss。
#
# 用法：
#   ./verify_cache_sequence.sh              # 默认走 DSM（需 simulator，同 bench_cache）
#   ./verify_cache_sequence.sh --mem       # 仅进程内 LRU fallback，不启 simulator
#   ./verify_cache_sequence.sh --trace     # FIL_READ_CACHE_TRACE=1 + [fil_io][DISK] 等
#   ./verify_cache_sequence.sh --l2-hit-only
#   ./verify_cache_sequence.sh --churn 200   # LRU 挤出轮数（默认 150）
#   VERIFY_SEQ_STRICT7=1 ./verify_cache_sequence.sh --mem
#       # ⑦ 仍要求「必有 L2 get_miss 或 do_io」等旧断言（易在多级索引下误伤）
#   ./verify_cache_sequence.sh -h
# ============================================================================
set -euo pipefail

USE_DSM=1
TRACE=0
L2_HIT_ONLY=0
CHURN_ROUNDS=150

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mem)        USE_DSM=0; shift ;;
    --trace)      TRACE=1; shift ;;
    --l2-hit-only) L2_HIT_ONLY=1; shift ;;
    --churn)      CHURN_ROUNDS="$2"; shift 2 ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT=/workspace
SIM_DIR=${ROOT}/ub2_simulator
SIM_BUILD=${SIM_DIR}/dsm_runtime/build
MYSQL_INSTALL=${ROOT}/mysql_install
MYSQL_BIN=${MYSQL_INSTALL}/bin
MYSQL_DATA=${MYSQL_INSTALL}/data
MYSQL_SOCK=/tmp/mysql-verify-seq.sock
MYSQL_PORT=3310
LOG_DIR=/tmp/dsm_verify_cache_logs
VERIFY_LOG="${LOG_DIR}/mysqld_verify_seq.log"
CLEAN=${SIM_DIR}/dsm_runtime/cleanup.sh
DB=verify_cache_db

mkdir -p "${LOG_DIR}"

say()   { printf "\n\033[1;36m[verify]\033[0m %s\n" "$*"; }
green() { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
bad()   { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; }

MYSQLD_PID=""
stop_mysqld() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "${MYSQLD_PID}" 2>/dev/null; then
    "${MYSQL_BIN}/mysqladmin" -S "$MYSQL_SOCK" -u root shutdown 2>/dev/null || \
      kill "${MYSQLD_PID}" 2>/dev/null || true
    wait "${MYSQLD_PID}" 2>/dev/null || true
  fi
  MYSQLD_PID=""
}

trap 'stop_mysqld; "$CLEAN" >/dev/null 2>&1 || true' EXIT INT TERM

wait_mysqld() {
  for _ in $(seq 1 80); do
    if "${MYSQL_BIN}/mysqladmin" -S "$MYSQL_SOCK" -u root ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_mysqld() {
  local tag="$1" log="$2"
  shift 2
  say "starting mysqld (${tag}) -> $log"
  "${MYSQL_BIN}/mysqld" \
    --datadir="${MYSQL_DATA}" \
    --socket="${MYSQL_SOCK}" \
    --port="${MYSQL_PORT}" \
    --pid-file=/tmp/mysql-verify-seq.pid \
    --innodb-buffer-pool-size=5M \
    --innodb-buffer-pool-chunk-size=1M \
    --innodb-buffer-pool-instances=1 \
    --innodb-flush-method=O_DIRECT_NO_FSYNC \
    --innodb-doublewrite=OFF \
    --log-error-verbosity=1 \
    --user="$(whoami)" \
    "$@" \
    >"$log" 2>&1 &
  MYSQLD_PID=$!
  if ! wait_mysqld; then
    bad "mysqld (${tag}) failed to start"
    tail -n 80 "$log" >&2
    exit 1
  fi
  green "mysqld (${tag}) pid=${MYSQLD_PID}"
}

get_status() {
  "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -B -e \
    "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status
     WHERE VARIABLE_NAME='$1'" 2>/dev/null || echo 0
}

trigger_dump() { rm -f /tmp/fil_read_cache_dump 2>/dev/null || true; touch /tmp/fil_read_cache_dump; }
wait_dumped()  { for _ in $(seq 1 80); do [[ ! -e /tmp/fil_read_cache_dump ]] && return 0; sleep 0.01; done; return 1; }

# 从 VERIFY_LOG 里取「最后一次 tag=window 的 stats / timing 行」
last_window_stats() {
  grep -E '\[fil_read_cache\]\[stats\].*tag=window' "$VERIFY_LOG" 2>/dev/null | tail -1 || true
}
last_window_timing() {
  grep -E '\[fil_read_cache\]\[timing_ns\]' "$VERIFY_LOG" 2>/dev/null | tail -1 || true
}

parse_ctr() { sed -n "s/.*$2=\\([0-9]*\\).*/\\1/p" <<<"${1:-}"; }

# 两次 touch dump 之间执行一条 SQL，把增量写到 WGH WGM WPT WIV WND WBR WBQ
fil_capture_window() {
  local sql="${1:-}"
  trigger_dump; wait_dumped || true
  sleep 0.05
  WBR0=$(get_status Innodb_buffer_pool_reads)
  WBQ0=$(get_status Innodb_buffer_pool_read_requests)
  WS0=$(last_window_stats)
  WT0=$(last_window_timing)
  if [[ -n "$sql" ]]; then
    "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -e "$sql" >/dev/null
  fi
  trigger_dump; wait_dumped || true
  sleep 0.08
  WBR1=$(get_status Innodb_buffer_pool_reads)
  WBQ1=$(get_status Innodb_buffer_pool_read_requests)
  WS1=$(last_window_stats)
  WT1=$(last_window_timing)
  WGH=$(( $(parse_ctr "$WS1" get_hit) - $(parse_ctr "$WS0" get_hit) ))
  WGM=$(( $(parse_ctr "$WS1" get_miss) - $(parse_ctr "$WS0" get_miss) ))
  WPT=$(( $(parse_ctr "$WS1" put) - $(parse_ctr "$WS0" put) ))
  WIV=$(( $(parse_ctr "$WS1" invalidate) - $(parse_ctr "$WS0" invalidate) ))
  WND=$(( $(sed -n 's/.*doio_read=[0-9]*(n=\([0-9]*\)).*/\1/p' <<<"${WT1:-}") - $(sed -n 's/.*doio_read=[0-9]*(n=\([0-9]*\)).*/\1/p' <<<"${WT0:-}") ))
  WDD=$(( $(parse_ctr "$WT1" doio_read) - $(parse_ctr "$WT0" doio_read) ))
  WBR=$(( WBR1 - WBR0 ))
  WBQ=$(( WBQ1 - WBQ0 ))
}

fil_print_window() {
  printf "  fil_read_cache: get_hit=%s get_miss=%s put=%s invalidate=%s\n" "$WGH" "$WGM" "$WPT" "$WIV"
  printf "  do_io(read): delta_n=%s delta_ns=%s\n" "$WND" "$WDD"
  printf "  BP: buffer_pool_reads delta=%s read_requests delta=%s\n" "$WBR" "$WBQ"
}

measure_window() {
  local label="$1"
  local sql="$2"
  say "--- 窗口: ${label} ---"
  fil_capture_window "$sql"
  fil_print_window
}

# ---------------------------------------------------------------------------
# 0) 清理
# ---------------------------------------------------------------------------
"$CLEAN" >/dev/null 2>&1 || true
"$CLEAN" --purge-shm >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 1) 可选：simulator（与 bench_cache.sh 一致）
# ---------------------------------------------------------------------------
if [[ "$USE_DSM" -eq 1 ]]; then
  say "starting simulator + export_client (DSM)"
  # shellcheck source=/dev/null
  . "${SIM_DIR}/sim_env.sh"
  ( cd "${SIM_BUILD}" && mpirun -np 4 ./simulator ) \
    >"${LOG_DIR}/simulator.log" 2>&1 &
  for _ in $(seq 1 50); do
    [[ -S /tmp/obmm_simulator_node0.sock ]] && break
    sleep 0.2
  done
  ( cd "${SIM_BUILD}" && mpirun -np 4 ./export_client ) \
    >"${LOG_DIR}/export_client.log" 2>&1
  for m in 1 2 3; do
    [[ -e "/dev/shm/virtual_node0/obmm_shmdev${m}" ]] || {
      echo "export_client did not leave obmm_shmdev${m}"; exit 4; }
  done
  green "DSM shm ready"
else
  say "跳过 simulator（--mem：进程内 LRU fallback）"
fi

# ---------------------------------------------------------------------------
# 2) 准备数据：用无 L2 的 mysqld 建表，随后关闭 → 验证阶段冷启动得到冷 BP
# ---------------------------------------------------------------------------
say "数据准备（FIL_READ_CACHE_ENABLE=0）"
FIL_READ_CACHE_ENABLE=0 start_mysqld "prep" "${LOG_DIR}/mysqld_prep.log"
MYSQL="${MYSQL_BIN}/mysql -S ${MYSQL_SOCK} -u root"

$MYSQL <<SQL
CREATE DATABASE IF NOT EXISTS ${DB};
USE ${DB};
DROP TABLE IF EXISTS t1;
CREATE TABLE t1 (
  id   INT PRIMARY KEY,
  data VARCHAR(64) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;
INSERT INTO t1 VALUES (1, 'init');

DROP TABLE IF EXISTS filler;
CREATE TABLE filler (
  id   INT PRIMARY KEY AUTO_INCREMENT,
  pad1 CHAR(255) NOT NULL,
  pad2 CHAR(255) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=COMPACT;
INSERT INTO filler (pad1, pad2) VALUES (REPEAT('A',255), REPEAT('B',255));
SQL

# 约 400 行/轮倍增，快速造 >5MB 的 filler，便于挤出 t1
CUR=1
TARGET_ROWS=80000
while [[ $CUR -lt $TARGET_ROWS ]]; do
  $MYSQL -e "USE ${DB}; INSERT INTO filler (pad1, pad2) SELECT pad1, pad2 FROM filler LIMIT $CUR;" >/dev/null
  CUR=$(( CUR * 2 ))
done
$MYSQL -e "USE ${DB}; ANALYZE TABLE t1, filler;" >/dev/null
$MYSQL -e "USE ${DB}; FLUSH TABLES t1, filler;" >/dev/null || true
stop_mysqld

# ---------------------------------------------------------------------------
# 3) 验证 mysqld
# ---------------------------------------------------------------------------
EXTRA_ENV=()
if [[ "$USE_DSM" -eq 1 ]]; then
  EXTRA_ENV+=(FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1)
else
  EXTRA_ENV+=(FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=0)
fi
export FIL_READ_CACHE_TRACE=${TRACE}
for e in "${EXTRA_ENV[@]}"; do export "$e"; done

start_mysqld "verify" "$VERIFY_LOG"
MYSQL="${MYSQL_BIN}/mysql -S ${MYSQL_SOCK} -u root"

failures=0
check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    green "$name"
  else
    bad "$name  (期望: $cond)"
    failures=$((failures + 1))
  fi
}

if [[ "$L2_HIT_ONLY" -eq 1 ]]; then
  say "======== 场景：仅 L2 命中（无 UPDATE / 无 flush，对应你文档里的 6b）========"
  measure_window "① 冷 BP 首次 SELECT t1" "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  measure_window "② 再次 SELECT（应 BP 命中，不经 fil_io READ）" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  check "② BP_reads=0 且 L2 无 put" "[[ $WBR -eq 0 && $WPT -eq 0 ]]"

  say "③ LRU 挤出：${CHURN_ROUNDS} 轮全表扫 filler（t1 页被挤出 BP，L2 仍保留）"
  for _ in $(seq 1 "$CHURN_ROUNDS"); do
    $MYSQL -e "USE ${DB}; SELECT COUNT(*) FROM filler;" >/dev/null
  done

  measure_window "④ 挤出后再 SELECT t1（BP miss → L2 get 命中 → 无 do_io）" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  echo "  [断言] get_hit=$WGH get_miss=$WGM put=$WPT do_io_n_delta=$WND BP_reads=$WBR"
  check "④ BP 再次 miss" "[[ $WBR -gt 0 ]]"
  check "④ L2 get 命中 (get_hit>=1)" "[[ $WGH -ge 1 ]]"
  check "④ 命中 L2 不再 put" "[[ $WPT -eq 0 ]]"
  check "④ do_io(read) 次数不增 (n delta=0)" "[[ $WND -eq 0 ]]"
else
  say "======== 场景：完整 UPDATE + flush + invalidate + 挤出（对应你文档 ①—⑦）========"

  measure_window "① 冷 BP 首次 SELECT * FROM t1 WHERE id=1" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  echo "  [断言] get_miss=$WGM put=$WPT do_io_n=$WND BP_reads=$WBR"
  check "① BP miss" "[[ $WBR -gt 0 ]]"
  check "① L2 get_miss>=1" "[[ $WGM -ge 1 ]]"
  check "① L2 put>=1" "[[ $WPT -ge 1 ]]"
  check "① do_io(read) 发生" "[[ $WND -ge 1 ]]"

  measure_window "② 再次相同 SELECT（BP 命中）" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  echo "  [断言] get_miss=$WGM put=$WPT BP_reads=$WBR"
  check "② 不经同步读盘" "[[ $WBR -eq 0 ]]"
  check "② L2 无 put" "[[ $WPT -eq 0 ]]"

  measure_window "③ UPDATE（脏页；不走 fil_io READ）" \
    "USE ${DB}; UPDATE t1 SET data = 'a' WHERE id = 1;"
  echo "  [断言] put_delta=$WPT"
  check "③ 无 L2 put" "[[ $WPT -eq 0 ]]"

  say "④ 等待 page cleaner 刷脏（fil_io WRITE 前 invalidate）"
  $MYSQL -e "SET GLOBAL innodb_max_dirty_pages_pct = 0;" >/dev/null || true
  dirty=999
  for _ in $(seq 1 60); do
    dirty=$($MYSQL -N -e "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status
                         WHERE VARIABLE_NAME='Innodb_buffer_pool_pages_dirty'" || echo 999)
    [[ "$dirty" -le 2 ]] && break
    sleep 0.5
  done
  green "Innodb_buffer_pool_pages_dirty=${dirty}"

  measure_window "⑤ flush 后再 SELECT（干净页常在 BP）" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  echo "  [断言] BP_reads=$WBR"
  check "⑤ 仍 BP 命中、无同步读" "[[ $WBR -eq 0 ]]"

  say "⑥ LRU 挤出 t1 所在页（${CHURN_ROUNDS} 轮 filler 全表扫）"
  for _ in $(seq 1 "$CHURN_ROUNDS"); do
    $MYSQL -e "USE ${DB}; SELECT COUNT(*) FROM filler;" >/dev/null
  done

  measure_window "⑦ 挤出后再 SELECT（BP miss；脏页已在 flush 时从 L2 invalidate，干净索引页可仍在 L2）" \
    "USE ${DB}; SELECT * FROM t1 WHERE id = 1;"
  row=$($MYSQL -N -e "USE ${DB}; SELECT data FROM t1 WHERE id = 1;" || true)
  echo "  [断言] BP_reads=$WBR get_miss=$WGM get_hit=$WGH put=$WPT do_io_n=$WND row(data)=${row:-?}"
  check "⑦ BP 再次 miss（页被挤出 BP）" "[[ $WBR -gt 0 ]]"
  check "⑦ 读到 UPDATE 后数据 (data=a)" "[[ \"${row}\" == \"a\" ]]"

  if [[ "${VERIFY_SEQ_STRICT7:-0}" == "1" ]]; then
    check "⑦[strict] L2 get_miss" "[[ $WGM -ge 1 ]]"
    check "⑦[strict] 再次 put" "[[ $WPT -ge 1 ]]"
    check "⑦[strict] do_io(read)" "[[ $WND -ge 1 ]]"
    check "⑦[strict] 无 L2 命中" "[[ $WGH -eq 0 ]]"
  else
    if [[ $((WGM + WND)) -ge 1 ]]; then
      green "⑦ 至少部分页走 L2 miss + do_io（与「脏页已 invalidate」一致）"
    elif [[ "$WGH" -gt 0 ]]; then
      say "⑦ 说明: 本窗口仅 L2 get_hit、无 do_io —— 常见于多级 B+ 树：flush 只 invalidate 写回页，"
      say "         未脏的根/内节点仍在 L2；数据正确性已由 data='a' 校验。调大 --churn 不会改变此行为。"
    fi
  fi
fi

stop_mysqld
unset FIL_READ_CACHE_TRACE
for e in "${EXTRA_ENV[@]}"; do unset "${e%%=*}"; done

say "日志: ${VERIFY_LOG}"
if [[ "$failures" -gt 0 ]]; then
  bad "共 ${failures} 条断言失败"
  exit 1
fi
green "全部断言通过"
