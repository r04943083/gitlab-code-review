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

echo "=== Registering GitLab Runner ==="

# Wait for GitLab
"$SCRIPT_DIR/wait-for-gitlab.sh" "$GITLAB_URL" 300

# Get runner registration token via rails runner
echo "Retrieving runner registration token..."

RUNNER_TOKEN=$(docker exec gitlab gitlab-rails runner "
puts Gitlab::CurrentSettings.current_application_settings.runners_registration_token
" 2>/dev/null)

if [ -z "$RUNNER_TOKEN" ]; then
    echo "ERROR: Could not retrieve runner registration token."
    exit 1
fi

echo "  Registration token obtained: ${RUNNER_TOKEN:0:8}..."

# Register the runner
echo "Registering runner..."

docker exec gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "http://gitlab:${GITLAB_PORT:-8080}" \
    --registration-token "$RUNNER_TOKEN" \
    --executor docker \
    --docker-image "python:3.12-slim" \
    --docker-network-mode "code-review_gl-net" \
    --description "code-review-runner" \
    --tag-list "code-review" \
    --run-untagged=true

echo "  Runner registered."

# Restart runner to apply config
echo "Restarting runner container..."
docker compose restart runner
echo "  Runner restarted."

echo ""
echo "=== Runner Registration Complete ==="
echo ""
