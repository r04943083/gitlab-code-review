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

echo "=== Phase 1: 安装 GitLab ==="

# --- 检查 Docker ---
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker 未安装。请先安装 Docker。"
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose 不可用。请安装 Docker Compose v2。"
    exit 1
fi

echo "  docker 和 docker compose 已就绪。"

# --- 创建 .env ---
if [ ! -f .env ]; then
    echo "从 .env.example 创建 .env..."
    cp .env.example .env
    echo "  .env 已创建。请编辑 .env 填入 LLM_API_KEY 等配置。"
else
    echo "  .env 已存在。"
fi

# Source .env for port config
set -a
source .env
set +a

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"

# --- 幂等检查：GitLab 是否已在运行且健康 ---
if docker ps --format '{{.Names}}' | grep -q '^gitlab$'; then
    if curl -sf -o /dev/null "${GITLAB_URL}/-/health" 2>/dev/null; then
        echo ""
        echo "GitLab 已在运行且健康。"
        echo "  URL: ${GITLAB_URL}"
        echo "  登录: root / ${GITLAB_ROOT_PASSWORD:-changeme123}"
        echo ""
        echo "下一步: bash scripts/02-setup-bot.sh"
        exit 0
    fi
    echo "  GitLab 容器已存在但尚未就绪，等待中..."
fi

# --- 仅启动 GitLab 服务 ---
echo "启动 GitLab..."
docker compose up -d gitlab

# --- 等待 GitLab 就绪 ---
"$SCRIPT_DIR/wait-for-gitlab.sh" "$GITLAB_URL" 300

echo ""
echo "=== GitLab 安装完成 ==="
echo "  URL:    ${GITLAB_URL}"
echo "  用户:   root"
echo "  密码:   ${GITLAB_ROOT_PASSWORD:-changeme123}"
echo ""
echo "下一步:"
echo "  1. 浏览器访问 ${GITLAB_URL} 确认 GitLab 正常运行"
echo "  2. 编辑 .env 设置 LLM_API_KEY"
echo "  3. 运行: bash scripts/02-setup-bot.sh"
echo ""
