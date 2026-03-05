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

echo "=== 移除 Bot 容器（保留 GitLab）==="

docker compose stop bot 2>/dev/null || true
docker compose rm -f bot 2>/dev/null || true

echo "Bot 容器已移除。GitLab 仍在运行。"
echo "重新启动 bot: bash scripts/02-setup-bot.sh"
