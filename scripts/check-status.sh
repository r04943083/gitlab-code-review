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

# Source .env if exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

GITLAB_PORT="${GITLAB_PORT:-8080}"
BOT_PORT="${BOT_PORT:-8888}"

echo "=== 服务状态检查 ==="
echo ""

# --- GitLab ---
printf "%-20s" "GitLab:"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^gitlab$'; then
    if curl -sf -o /dev/null "http://localhost:${GITLAB_PORT}/-/health" 2>/dev/null; then
        echo "✓ 运行中 (健康) - http://localhost:${GITLAB_PORT}"
    else
        echo "△ 运行中 (启动中/未就绪)"
    fi
else
    echo "✗ 未运行"
fi

# --- Bot ---
printf "%-20s" "Review Bot:"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^review-bot$'; then
    if curl -sf -o /dev/null "http://localhost:${BOT_PORT}/health" 2>/dev/null; then
        echo "✓ 运行中 (健康) - http://localhost:${BOT_PORT}"
    else
        echo "△ 运行中 (启动中/未就绪)"
    fi
else
    echo "✗ 未运行"
fi

# --- Runner ---
printf "%-20s" "GitLab Runner:"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^gitlab-runner$'; then
    echo "✓ 运行中"
else
    echo "✗ 未运行 (可选组件)"
fi

echo ""

# --- Docker Compose 服务详情 ---
echo "--- Docker 容器详情 ---"
docker compose ps 2>/dev/null || echo "(docker compose ps 执行失败)"
echo ""
