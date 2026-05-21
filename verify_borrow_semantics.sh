#!/usr/bin/env bash
# ============================================================================
# Verify OBMM "borrow/import" semantics.
#
# The simulator models remote-memory borrowing as:
#   remote node exports /dev/shm/virtual_nodeR/obmm_shmdevX
#   local node imports it as /dev/shm/virtual_nodeL/obmm_shmdevY
#   the imported path is a symlink to the exported object
#   both paths mmap the same storage, so writes through either view are visible
#   through the other view.
#
# This script checks those observable semantics. It can either:
#   1) start the current simulator/export_client and verify its imports, or
#   2) verify paths that already exist on a real-machine setup.
#
# Examples:
#   ./verify_borrow_semantics.sh --sim
#   ./verify_borrow_semantics.sh --local-node 0 --memids 1,2,3
#   ./verify_borrow_semantics.sh \
#       --pair /dev/shm/virtual_node0/obmm_shmdev1:/dev/shm/virtual_node1/obmm_shmdev1
#   ./verify_borrow_semantics.sh --sim --unlink-import
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIM_BUILD="${SCRIPT_DIR}/build"
CLEAN="${SCRIPT_DIR}/cleanup.sh"

START_SIM=0
NO_CLEAN=0
UNLINK_IMPORT=0
LOCAL_NODE=0
MEMIDS="1,2,3"
PAIRS=()

usage() {
  sed -n '2,22p' "$0"
}

say()   { printf "\n\033[1;36m[borrow]\033[0m %s\n" "$*"; }
ok()    { printf "\033[1;32m[ok]\033[0m %s\n" "$*"; }
warn()  { printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
fail()  { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) START_SIM=1; shift ;;
    --no-clean) NO_CLEAN=1; shift ;;
    --unlink-import) UNLINK_IMPORT=1; shift ;;
    --local-node) LOCAL_NODE="$2"; shift 2 ;;
    --memids) MEMIDS="$2"; shift 2 ;;
    --pair) PAIRS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown arg: $1" ;;
  esac
done

cleanup() {
  if [[ "$START_SIM" -eq 1 && "$NO_CLEAN" -eq 0 ]]; then
    "$CLEAN" >/dev/null 2>&1 || true
    "$CLEAN" --purge-shm >/dev/null 2>&1 || true
  fi
  [[ -n "${PROBE_BIN:-}" && -e "${PROBE_BIN:-}" ]] && rm -f "$PROBE_BIN" 2>/dev/null || true
  [[ -n "${PROBE_SRC:-}" && -e "${PROBE_SRC:-}" ]] && rm -f "$PROBE_SRC" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

build_probe() {
  PROBE_SRC="/tmp/dsm_borrow_probe.$$.c"
  PROBE_BIN="/tmp/dsm_borrow_probe.$$"
  cat >"$PROBE_SRC" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int map_file(const char *path, size_t need, void **addr, size_t *len) {
  int fd = open(path, O_RDWR);
  if (fd < 0) {
    fprintf(stderr, "open(%s): %s\n", path, strerror(errno));
    return 1;
  }
  struct stat st;
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, "fstat(%s): %s\n", path, strerror(errno));
    close(fd);
    return 1;
  }
  if (st.st_size < (off_t)need) {
    fprintf(stderr, "%s too small: need=%zu size=%jd\n", path, need,
            (intmax_t)st.st_size);
    close(fd);
    return 1;
  }
  void *p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (p == MAP_FAILED) {
    fprintf(stderr, "mmap(%s): %s\n", path, strerror(errno));
    return 1;
  }
  *addr = p;
  *len = (size_t)st.st_size;
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: %s write|expect PATH OFFSET HEX64\n", argv[0]);
    return 2;
  }
  const char *op = argv[1];
  const char *path = argv[2];
  char *end = NULL;
  errno = 0;
  uint64_t off = strtoull(argv[3], &end, 0);
  if (errno || end == argv[3] || *end != '\0') {
    fprintf(stderr, "bad offset: %s\n", argv[3]);
    return 2;
  }
  errno = 0;
  uint64_t val = strtoull(argv[4], &end, 0);
  if (errno || end == argv[4] || *end != '\0') {
    fprintf(stderr, "bad value: %s\n", argv[4]);
    return 2;
  }
  void *base = NULL;
  size_t len = 0;
  if (map_file(path, (size_t)off + sizeof(uint64_t), &base, &len) != 0) {
    return 1;
  }
  volatile uint64_t *slot = (volatile uint64_t *)((char *)base + off);
  int rc = 0;
  if (strcmp(op, "write") == 0) {
    *slot = val;
    if (msync((void *)((uintptr_t)slot & ~(uintptr_t)4095), 4096, MS_SYNC) != 0) {
      fprintf(stderr, "msync(%s): %s\n", path, strerror(errno));
      rc = 1;
    }
  } else if (strcmp(op, "expect") == 0) {
    uint64_t got = *slot;
    if (got != val) {
      fprintf(stderr, "%s offset=%" PRIu64 " expected=0x%016" PRIx64
              " got=0x%016" PRIx64 "\n", path, off, val, got);
      rc = 1;
    }
  } else {
    fprintf(stderr, "unknown op: %s\n", op);
    rc = 2;
  }
  munmap(base, len);
  return rc;
}
C
  cc -O2 -Wall -Wextra -o "$PROBE_BIN" "$PROBE_SRC"
}

start_simulator() {
  [[ -x "$CLEAN" ]] || fail "cleanup script not found: $CLEAN"
  [[ -x "${SIM_BUILD}/simulator" ]] || fail "missing ${SIM_BUILD}/simulator; build dsm_runtime first"
  [[ -x "${SIM_BUILD}/export_client" ]] || fail "missing ${SIM_BUILD}/export_client; build dsm_runtime first"

  say "starting simulator/export_client baseline"
  "$CLEAN" >/dev/null 2>&1 || true
  "$CLEAN" --purge-shm >/dev/null 2>&1 || true
  # shellcheck source=/dev/null
  . "${SIM_DIR}/sim_env.sh"

  ( cd "$SIM_BUILD" && mpirun -np 4 ./simulator ) >/tmp/dsm_borrow_simulator.log 2>&1 &
  for _ in $(seq 1 80); do
    [[ -S /tmp/obmm_simulator_node0.sock ]] && break
    sleep 0.1
  done
  [[ -S /tmp/obmm_simulator_node0.sock ]] || {
    tail -n 80 /tmp/dsm_borrow_simulator.log >&2 || true
    fail "simulator socket did not appear"
  }

  ( cd "$SIM_BUILD" && mpirun -np 4 ./export_client ) >/tmp/dsm_borrow_export_client.log 2>&1 || {
    tail -n 80 /tmp/dsm_borrow_export_client.log >&2 || true
    fail "export_client failed"
  }
  ok "simulator imports are ready"
}

canonical() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1"
  else
    readlink -f "$1"
  fi
}

inode_key() {
  stat -Lc '%d:%i' "$1"
}

append_default_pairs() {
  IFS=',' read -r -a ids <<<"$MEMIDS"
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    local local_path="/dev/shm/virtual_node${LOCAL_NODE}/obmm_shmdev${id}"
    [[ -e "$local_path" || -L "$local_path" ]] || fail "missing imported path: $local_path"
    [[ -L "$local_path" ]] || fail "$local_path is not a symlink; this is not simulator-style borrow/import"
    local target
    target="$(readlink "$local_path")"
    [[ "$target" = /* ]] || target="$(dirname "$local_path")/$target"
    PAIRS+=("${local_path}:${target}")
  done
}

check_pair() {
  local pair="$1"
  local local_path="${pair%%:*}"
  local remote_path="${pair#*:}"
  [[ "$local_path" != "$remote_path" ]] || fail "bad pair, local and remote are identical textually: $pair"

  say "checking ${local_path} -> ${remote_path}"

  [[ -e "$local_path" || -L "$local_path" ]] || fail "local/import path missing: $local_path"
  [[ -e "$remote_path" ]] || fail "remote/export path missing: $remote_path"
  [[ -L "$local_path" ]] || fail "$local_path is not a symlink"

  local link_target local_real remote_real
  link_target="$(readlink "$local_path")"
  local_real="$(canonical "$local_path")"
  remote_real="$(canonical "$remote_path")"

  [[ "$local_real" == "$remote_real" ]] || {
    printf '  readlink target: %s\n  local realpath: %s\n  remote realpath: %s\n' \
      "$link_target" "$local_real" "$remote_real" >&2
    fail "import path does not resolve to remote export path"
  }
  ok "import resolves to the remote export object"

  local local_inode remote_inode
  local_inode="$(inode_key "$local_path")"
  remote_inode="$(inode_key "$remote_path")"
  [[ "$local_inode" == "$remote_inode" ]] || fail "inode differs: local=$local_inode remote=$remote_inode"
  ok "same device/inode (${local_inode})"

  local off_a=4096
  local off_b=4104
  local magic_a magic_b
  magic_a="$(printf '0x%016x' $((0x7011000000000000 + RANDOM)))"
  magic_b="$(printf '0x%016x' $((0x7022000000000000 + RANDOM)))"

  "$PROBE_BIN" write "$local_path" "$off_a" "$magic_a"
  "$PROBE_BIN" expect "$remote_path" "$off_a" "$magic_a"
  ok "local mmap write is visible through remote path"

  "$PROBE_BIN" write "$remote_path" "$off_b" "$magic_b"
  "$PROBE_BIN" expect "$local_path" "$off_b" "$magic_b"
  ok "remote mmap write is visible through local import path"

  if [[ "$UNLINK_IMPORT" -eq 1 ]]; then
    rm -f "$local_path"
    [[ ! -e "$local_path" && ! -L "$local_path" ]] || fail "failed to unlink import path: $local_path"
    [[ -e "$remote_path" ]] || fail "unlinking import also removed remote export: $remote_path"
    ok "unlinking import entry does not remove remote export"
  fi
}

build_probe
if [[ "$START_SIM" -eq 1 ]]; then
  start_simulator
fi

if [[ ${#PAIRS[@]} -eq 0 ]]; then
  append_default_pairs
fi

[[ ${#PAIRS[@]} -gt 0 ]] || fail "no pairs to verify"

for pair in "${PAIRS[@]}"; do
  check_pair "$pair"
done

say "borrow/import semantics verified for ${#PAIRS[@]} pair(s)"
