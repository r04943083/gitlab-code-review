#!/usr/bin/env bash
set -euo pipefail

# Prevent VSCode popup in WSL
export EDITOR=cat
export VISUAL=cat
export GIT_EDITOR=cat
export LESSEDIT=cat
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "VS Code" | tr '\n' ':' | sed 's/:$//')

# Wait for GitLab to become healthy
# Usage: wait-for-gitlab.sh [url] [timeout_seconds]

GITLAB_URL="${1:-http://localhost:8080}"
TIMEOUT="${2:-300}"

echo "Waiting for GitLab at ${GITLAB_URL} to become healthy (timeout: ${TIMEOUT}s)..."

elapsed=0
interval=5

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    # Check login page (returns 200 when GitLab is ready)
    if curl -sf -o /dev/null -w "%{http_code}" "${GITLAB_URL}/users/sign_in" 2>/dev/null | grep -q "200"; then
        echo "GitLab is healthy after ${elapsed}s."
        exit 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "  ...still waiting (${elapsed}s elapsed)"
done

echo "ERROR: GitLab did not become healthy within ${TIMEOUT}s."
exit 1
