#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "=== Code Review Bot Setup ==="

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed. Please install Docker first."
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose is not available. Please install Docker Compose v2."
    exit 1
fi

echo "  docker and docker compose found."

# Ensure .env exists
if [ ! -f .env ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
    echo "  .env created. Edit it to set your LLM_API_KEY before running init-gitlab.sh."
else
    echo "  .env already exists."
fi

# Build and start services
echo "Building containers..."
docker compose build

echo "Starting services..."
docker compose up -d

# Wait for GitLab
"$SCRIPT_DIR/wait-for-gitlab.sh" "http://localhost:${GITLAB_PORT:-8080}" 300

echo ""
echo "=== Setup Complete ==="
echo "Next steps:"
echo "  1. Run: ./scripts/init-gitlab.sh   (creates token, project, webhook)"
echo "  2. Run: ./scripts/test-review.sh    (end-to-end test)"
echo ""
