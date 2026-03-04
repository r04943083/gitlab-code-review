#!/usr/bin/env bash
set -euo pipefail

# Wait for GitLab to become healthy
# Usage: wait-for-gitlab.sh [url] [timeout_seconds]

GITLAB_URL="${1:-http://localhost:8080}"
TIMEOUT="${2:-300}"

echo "Waiting for GitLab at ${GITLAB_URL} to become healthy (timeout: ${TIMEOUT}s)..."

elapsed=0
interval=5

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if curl -sf "${GITLAB_URL}/-/health" >/dev/null 2>&1; then
        echo "GitLab is healthy after ${elapsed}s."
        exit 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "  ...still waiting (${elapsed}s elapsed)"
done

echo "ERROR: GitLab did not become healthy within ${TIMEOUT}s."
exit 1
