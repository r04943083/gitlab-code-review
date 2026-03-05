#!/usr/bin/env bash
set -euo pipefail

# Prevent editor from popping up
export EDITOR=cat
export VISUAL=cat
export GIT_EDITOR=cat

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Phase 2: 配置 AI 代码审查 ==="

# --- 检查 .env ---
if [ ! -f .env ]; then
    echo "ERROR: .env 文件不存在。请先运行: bash scripts/01-install-gitlab.sh"
    exit 1
fi
set -a
source .env
set +a

# --- 检查 LLM_API_KEY ---
if [ -z "${LLM_API_KEY:-}" ] || [ "$LLM_API_KEY" = "your-api-key-here" ]; then
    echo "ERROR: LLM_API_KEY 未设置。请编辑 .env 填入你的 API Key。"
    exit 1
fi

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"

# --- 检查 GitLab 是否运行 ---
if ! docker ps --format '{{.Names}}' | grep -q '^gitlab$'; then
    echo "ERROR: GitLab 未运行。请先运行: bash scripts/01-install-gitlab.sh"
    exit 1
fi

if ! curl -sf -o /dev/null "${GITLAB_URL}/-/health" 2>/dev/null; then
    echo "GitLab 尚未就绪，等待中..."
    "$SCRIPT_DIR/wait-for-gitlab.sh" "$GITLAB_URL" 300
fi

BOT_USERNAME="${BOT_USERNAME:-ai-reviewer}"
BOT_NAME="${BOT_NAME:-AI Code Reviewer}"

# --- 创建 root token（幂等） ---
echo "创建 root access token..."

ROOT_TOKEN=$(docker exec gitlab gitlab-rails runner '
user = User.find_by_username("root")
existing = user.personal_access_tokens.active.find_by(name: "root-api-token")
if existing
  # Token already exists but we cannot retrieve its value, create a new one
  puts existing.token if existing.respond_to?(:token) && existing.token
end
' 2>&1 | tail -1)

if [ -z "$ROOT_TOKEN" ] || [[ ! "$ROOT_TOKEN" =~ ^glpat- ]]; then
    ROOT_TOKEN=$(docker exec gitlab gitlab-rails runner '
user = User.find_by_username("root")
token = user.personal_access_tokens.create!(
  name: "root-api-token-'"$(date +%s)"'",
  scopes: [:api],
  expires_at: 365.days.from_now
)
puts token.token
' 2>&1 | tail -1)
fi

if [ -z "$ROOT_TOKEN" ] || [[ ! "$ROOT_TOKEN" =~ ^glpat- ]]; then
    echo "ERROR: 创建 root token 失败。"
    echo "  Output: $ROOT_TOKEN"
    exit 1
fi
echo "  Root token: ${ROOT_TOKEN:0:12}..."

# --- 创建 bot 用户（幂等） ---
echo "检查 bot 用户..."

BOT_CHECK=$(curl -sf \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    "${GITLAB_URL}/api/v4/users?username=${BOT_USERNAME}" 2>/dev/null || echo "[]")

if echo "$BOT_CHECK" | grep -q "\"username\":\"${BOT_USERNAME}\""; then
    echo "  Bot 用户已存在: ${BOT_USERNAME}"
else
    echo "  创建 bot 用户..."
    curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
            \"username\": \"${BOT_USERNAME}\",
            \"name\": \"${BOT_NAME}\",
            \"email\": \"${BOT_USERNAME}@gitlab.local\",
            \"password\": \"$(openssl rand -hex 16)\",
            \"skip_confirmation\": true
        }" \
        "${GITLAB_URL}/api/v4/users" >/dev/null 2>&1

    echo "  Bot 用户已创建: ${BOT_USERNAME}"
    sleep 2
fi

# --- 创建 bot token ---
echo "创建 bot access token..."

GITLAB_TOKEN=$(docker exec gitlab gitlab-rails runner '
user = User.find_by_username("'"${BOT_USERNAME}"'")
if user
  token = user.personal_access_tokens.create!(
    name: "review-bot-token-'"$(date +%s)"'",
    scopes: [:api, :read_api, :read_repository, :write_repository],
    expires_at: 365.days.from_now
  )
  puts token.token
end
' 2>&1 | tail -1)

if [ -z "$GITLAB_TOKEN" ] || [[ ! "$GITLAB_TOKEN" =~ ^glpat- ]]; then
    echo "  Bot token 创建失败，使用 root token 代替..."
    GITLAB_TOKEN="$ROOT_TOKEN"
fi

echo "  Bot token: ${GITLAB_TOKEN:0:12}..."

# --- 写入 GITLAB_TOKEN 到 .env ---
if grep -q "^GITLAB_TOKEN=" .env; then
    sed -i "s|^GITLAB_TOKEN=.*|GITLAB_TOKEN=${GITLAB_TOKEN}|" .env
else
    echo "GITLAB_TOKEN=${GITLAB_TOKEN}" >> .env
fi
echo "  Token 已写入 .env"

# --- 创建测试项目（幂等） ---
echo "创建测试项目..."

PROJECT_RESPONSE=$(curl -sf \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects?search=test-repo" 2>/dev/null || echo "[]")

if echo "$PROJECT_RESPONSE" | grep -q '"path":"test-repo"'; then
    echo "  项目 'test-repo' 已存在。"
    PROJECT_ID=$(echo "$PROJECT_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
else
    CREATE_RESPONSE=$(curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data '{
            "name": "test-repo",
            "path": "test-repo",
            "initialize_with_readme": true,
            "visibility": "public"
        }' \
        "${GITLAB_URL}/api/v4/projects" 2>/dev/null)

    PROJECT_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
    echo "  项目 'test-repo' 已创建 (ID: ${PROJECT_ID})。"
fi

if [ -z "${PROJECT_ID:-}" ]; then
    echo "ERROR: 无法获取项目 ID。"
    exit 1
fi

# --- 添加 bot 为项目成员 ---
echo "添加 bot 用户到项目..."

BOT_USER_ID=$(curl -sf \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    "${GITLAB_URL}/api/v4/users?username=${BOT_USERNAME}" 2>/dev/null | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [ -n "$BOT_USER_ID" ]; then
    curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
            \"user_id\": ${BOT_USER_ID},
            \"access_level\": 30
        }" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/members" >/dev/null 2>&1 || true
    echo "  Bot 用户已添加为 Developer。"
else
    echo "  警告: 未找到 bot 用户 ID。"
fi

# --- 配置 webhook（幂等） ---
echo "配置 webhook..."

WEBHOOK_URL="http://review-bot:${BOT_PORT:-8888}/webhook"

EXISTING_HOOKS=$(curl -sf \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" 2>/dev/null || echo "[]")

if echo "$EXISTING_HOOKS" | grep -q "review-bot"; then
    echo "  Webhook 已配置。"
else
    curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
            \"url\": \"${WEBHOOK_URL}\",
            \"token\": \"${GITLAB_WEBHOOK_SECRET:-webhook-secret-change-me}\",
            \"merge_requests_events\": true,
            \"push_events\": false,
            \"enable_ssl_verification\": false
        }" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" >/dev/null 2>&1

    echo "  Webhook 已配置: ${WEBHOOK_URL}"
fi

# --- 启动 bot 容器 ---
echo "构建并启动 bot 容器..."
docker compose up -d --build bot

# --- 等待 bot 健康检查 ---
echo "等待 bot 就绪..."
BOT_URL="http://localhost:${BOT_PORT:-8888}"
BOT_TIMEOUT=60
elapsed=0
interval=3

while [ "$elapsed" -lt "$BOT_TIMEOUT" ]; do
    if curl -sf -o /dev/null "${BOT_URL}/health" 2>/dev/null; then
        echo "  Bot 已就绪 (${elapsed}s)。"
        break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
done

if [ "$elapsed" -ge "$BOT_TIMEOUT" ]; then
    echo "WARNING: Bot 未在 ${BOT_TIMEOUT}s 内就绪。检查日志: docker compose logs bot"
fi

echo ""
echo "=== AI 代码审查配置完成 ==="
echo "  GitLab URL:  ${GITLAB_URL}"
echo "  Bot 用户:    ${BOT_USERNAME}"
echo "  测试项目:    root/test-repo (ID: ${PROJECT_ID})"
echo "  Webhook:     ${WEBHOOK_URL}"
echo "  Bot 健康:    ${BOT_URL}/health"
echo ""
echo "下一步: bash scripts/03-test-review.sh"
echo ""
