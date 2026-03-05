#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== 移除所有容器和卷 ==="

docker compose down -v --remove-orphans

echo "所有容器和卷已移除。"
echo "重新开始: bash scripts/01-install-gitlab.sh"
