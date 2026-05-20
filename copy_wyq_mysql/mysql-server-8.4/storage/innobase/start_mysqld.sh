#!/usr/bin/env bash
install_dir="/workspace/mysql_install"

read -r -p "Start mysqld in console mode? [y/N]: " answer

if [[ $answer =~ ^[Yy] ]]; then
  echo "Starting mysqld in console mode (foreground)..."
  "$install_dir/bin/mysqld" \
    --user="$(whoami)" \
    --datadir=data \
    --port=3308 \
    --socket=/tmp/mysql-debug.sock \
    --console
else
  echo "Starting mysqld in background..."
  "$install_dir/bin/mysqld" \
    --user="$(whoami)" \
    --datadir=data \
    --port=3308 \
    --socket=/tmp/mysql-debug.sock &
  echo "mysqld_safe launched in background (PID $!)."
fi
