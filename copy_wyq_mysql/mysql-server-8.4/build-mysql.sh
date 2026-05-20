#!/usr/bin/env bash
set -euo pipefail

ROOT=/workspace/ltCopyWorkspace/mysql-server-8.4
BUILD_DIR="${ROOT}/build"
INSTALL_DIR=/workspace/ltCopyWorkspace/mysql_install
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

cmake .. \
  -DCMAKE_BUILD_TYPE=Debug \
  -DWITH_DEBUG=1 \
  -DADD_GDB_INDEX=ON \
  -DCMAKE_INSTALL_PREFIX="${INSTALL_DIR}" \
  -DWITH_SSL=system \
  -DENABLE_DOWNLOADS=1 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

make -j"${JOBS}"
make install
