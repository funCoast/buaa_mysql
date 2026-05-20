#!/usr/bin/env bash
set -euo pipefail

SF="${1:?SF required}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
RUN_ROOT="${RUN_ROOT:-$ROOT_DIR/runs}"
DB="${DB:-tpch}"
MYSQL_USER="${MYSQL_USER:-root}"
N_STREAMS="${N_STREAMS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
QIDS="${QIDS:-1 6 12 14 19 21}"
USE_PERMUTATION="${USE_PERMUTATION:-0}"
TPCH_KIT="${TPCH_KIT:-$SCRIPT_DIR/tpch-kit}"
QGEN="${QGEN:-$TPCH_KIT/dbgen/qgen}"
OUT="${OUT:-$RUN_ROOT/tpch_sf${SF}_streams_${N_STREAMS}}"
MYSQL_BIN="${MYSQL_BIN:-$ROOT_DIR/mysql_install/bin/mysql}"
MYSQL_SOCKET="${MYSQL_SOCKET:-$ROOT_DIR/tmp/mysql-debug.sock}"

if [[ -n "${MYSQL_OPTS:-}" ]]; then
  # shellcheck disable=SC2206
  MYSQL_CMD=("$MYSQL_BIN" ${MYSQL_OPTS} "$DB")
else
  MYSQL_CMD=("$MYSQL_BIN" --protocol=socket -S "$MYSQL_SOCKET" -u"$MYSQL_USER" "$DB")
fi

mkdir -p "$OUT/sql" "$OUT/logs"

for s in $(seq 1 "$N_STREAMS"); do
  seed=$((100000 + s * 1009))
  f="$OUT/sql/stream${s}.sql"
  : > "$f"
  for q in $QIDS; do
    if [[ "$USE_PERMUTATION" == "1" ]]; then
      "$QGEN" -v -c -s "$SF" -p "$s" -r "$seed" "$q" >> "$f"
    else
      "$QGEN" -v -c -s "$SF" -r "$seed" "$q" >> "$f"
    fi
    echo ";" >> "$f"
  done
done

for f in "$OUT"/sql/stream*.sql; do
  tmp="${f}.tmp"
  perl -0777 -pe 's/;\s*\n(\s*limit\s+-?\d+\s*;)/\n$1/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\blimit\s+-1\s*;/;/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  sed -E "s/\\<date[[:space:]]*'/DATE '/Ig" "$f" > "$tmp" && mv "$tmp" "$f"
  sed -E "s/interval[[:space:]]*'([0-9]+)'[[:space:]]*(day|month|year)/interval \\1 \\2/Ig" "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\b(interval\s+-?\d+\s+(?:day|month|year))\s*\(\s*\d+\s*\)/$1/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe 's/\bsubstring\s*\(\s*([^()]+?)\s+from\s+([^()]+?)\s+for\s+([^()]+?)\s*\)/substring($1, $2, $3)/ig' "$f" > "$tmp" && mv "$tmp" "$f"
  perl -0777 -pe "s/('([^']|'')*')\s*\|\|\s*('([^']|'')*')/concat(\\$1,\\$3)/ig" "$f" > "$tmp" && mv "$tmp" "$f"
done

"${MYSQL_CMD[@]}" -e "FLUSH STATUS; TRUNCATE TABLE performance_schema.file_summary_by_event_name;"

cat > "$OUT/run_one.sh" <<'RUNONE'
#!/usr/bin/env bash
set -euo pipefail
s="$1"
OUT="$2"
shift 2
/usr/bin/time -f "stream=${s} wall_sec=%e" -o "${OUT}/logs/stream${s}.time" \
  "$@" < "${OUT}/sql/stream${s}.sql" > "${OUT}/logs/stream${s}.out" 2>&1
RUNONE
chmod +x "$OUT/run_one.sh"

seq 1 "$N_STREAMS" | xargs -I{} -P "$N_STREAMS" "$OUT/run_one.sh" {} "$OUT" "${MYSQL_CMD[@]}"

echo "DONE: SF=$SF streams=$N_STREAMS qids=[$QIDS] out=$OUT"
