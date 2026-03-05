#!/usr/bin/env bash
set -euo pipefail

# Prevent VSCode popup in WSL
export EDITOR=cat
export VISUAL=cat
export GIT_EDITOR=cat
export LESSEDIT=cat
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "VS Code" | tr '\n' ':' | sed 's/:$//')

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== 移除所有容器和卷 ==="

docker compose down -v --remove-orphans

echo "所有容器和卷已移除。"
echo "重新开始: bash scripts/01-install-gitlab.sh"
