#!/usr/bin/env bash
# ferryman 卸载：停掉并删除容器。
#   bash uninstall.sh          只停容器，文件留着
#   bash uninstall.sh --purge  连本目录的文件一起删
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY_DIR="${RELAY_DIR:-$SCRIPT_DIR}"

if [ -f "$RELAY_DIR/docker-compose.yml" ]; then
  docker compose -f "$RELAY_DIR/docker-compose.yml" down --remove-orphans || true
else
  # 没有 compose 文件时的兜底；老版本装出来的容器叫 webhook-relay，用 CONTAINER_NAME 指过去
  docker rm -f "${CONTAINER_NAME:-ferryman}" >/dev/null 2>&1 || true
fi
echo "ferryman 已停止并删除"

if [ "${1:-}" = "--purge" ]; then
  cd /
  rm -rf "$RELAY_DIR"
  echo "已删除 $RELAY_DIR"
fi
