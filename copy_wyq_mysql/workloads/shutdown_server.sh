#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
INSTALL_DIR="${INSTALL_DIR:-$ROOT_DIR/mysql_install}"
SOCKET="${SOCKET:-$ROOT_DIR/tmp/mysql-debug.sock}"

"$INSTALL_DIR/bin/mysqladmin" --protocol=socket -S "$SOCKET" -u root shutdown
