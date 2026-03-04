#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Source .env
if [ ! -f .env ]; then
    echo "ERROR: .env file not found. Run setup.sh first."
    exit 1
fi
set -a
source .env
set +a

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"
INTERNAL_URL="http://gitlab:${GITLAB_PORT:-8080}"

echo "=== Initializing GitLab ==="

# Wait for GitLab to be healthy
"$SCRIPT_DIR/wait-for-gitlab.sh" "$GITLAB_URL" 300

# --- Create bot user (if not exists) ---
echo "Creating bot user..."

BOT_USERNAME="${BOT_USERNAME:-ai-reviewer}"
BOT_NAME="${BOT_NAME:-AI Code Reviewer}"

docker exec gitlab gitlab-rails runner "
bot = User.find_by_username('${BOT_USERNAME}')
if bot
  puts 'Bot user already exists: ${BOT_USERNAME}'
else
  bot = User.create!(
    username: '${BOT_USERNAME}',
    name: '${BOT_NAME}',
    email: '${BOT_USERNAME}@gitlab.local',
    password: SecureRandom.hex(16),
    admin: false,
    skip_confirmation: true
  )
  puts 'Created bot user: ${BOT_USERNAME}'
end
" 2>/dev/null

# --- Create Personal Access Token (idempotent) ---
echo "Creating Personal Access Token..."

TOKEN_NAME="review-bot-token"

GITLAB_TOKEN=$(docker exec gitlab gitlab-rails runner "
token = PersonalAccessToken.find_by(name: '${TOKEN_NAME}', revoked: false)
if token && !token.expired?
  puts token.token
else
  user = User.find_by_username('${BOT_USERNAME}') || User.find_by_username('root')
  token = user.personal_access_tokens.create!(
    name: '${TOKEN_NAME}',
    scopes: [:api, :read_api, :read_repository, :write_repository],
    expires_at: 365.days.from_now
  )
  puts token.token
end
" 2>/dev/null)

if [ -z "$GITLAB_TOKEN" ]; then
    echo "ERROR: Failed to create Personal Access Token."
    exit 1
fi

echo "  Token obtained: ${GITLAB_TOKEN:0:8}..."

# Write token back to .env
if grep -q "^GITLAB_TOKEN=" .env; then
    sed -i "s|^GITLAB_TOKEN=.*|GITLAB_TOKEN=${GITLAB_TOKEN}|" .env
else
    echo "GITLAB_TOKEN=${GITLAB_TOKEN}" >> .env
fi
echo "  Token written to .env"

# --- Create test project (if not exists) ---
echo "Creating test project..."

PROJECT_RESPONSE=$(curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects?search=test-repo&owned=true" 2>/dev/null || echo "[]")

if echo "$PROJECT_RESPONSE" | grep -q '"path":"test-repo"'; then
    echo "  Project 'test-repo' already exists."
    PROJECT_ID=$(echo "$PROJECT_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
else
    CREATE_RESPONSE=$(curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data '{
            "name": "test-repo",
            "path": "test-repo",
            "initialize_with_readme": true,
            "visibility": "internal"
        }' \
        "${GITLAB_URL}/api/v4/projects")

    PROJECT_ID=$(echo "$CREATE_RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
    echo "  Project 'test-repo' created (ID: ${PROJECT_ID})."
fi

if [ -z "${PROJECT_ID:-}" ]; then
    echo "ERROR: Could not determine project ID."
    exit 1
fi

# --- Configure webhook ---
echo "Configuring webhook..."

EXISTING_HOOKS=$(curl -sf \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" 2>/dev/null || echo "[]")

WEBHOOK_URL="http://review-bot:8888/webhook"

if echo "$EXISTING_HOOKS" | grep -q "$WEBHOOK_URL"; then
    echo "  Webhook already configured."
else
    curl -sf --request POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{
            \"url\": \"${WEBHOOK_URL}\",
            \"token\": \"${GITLAB_WEBHOOK_SECRET}\",
            \"merge_requests_events\": true,
            \"push_events\": false,
            \"enable_ssl_verification\": false
        }" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks" >/dev/null

    echo "  Webhook configured: ${WEBHOOK_URL}"
fi

# --- Restart bot to pick up new token ---
echo "Restarting bot container..."
docker compose restart bot
echo "  Bot restarted."

echo ""
echo "=== GitLab Initialization Complete ==="
echo "  GitLab URL:  ${GITLAB_URL}"
echo "  Bot User:    ${BOT_USERNAME}"
echo "  Project:     ${BOT_USERNAME}/test-repo (ID: ${PROJECT_ID})"
echo "  Webhook:     ${WEBHOOK_URL}"
echo "  Token:       ${GITLAB_TOKEN:0:8}..."
echo ""
