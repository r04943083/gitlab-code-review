#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Source .env
if [ ! -f .env ]; then
    echo "ERROR: .env file not found. Run setup.sh and init-gitlab.sh first."
    exit 1
fi
set -a
source .env
set +a

if [ -z "${GITLAB_TOKEN:-}" ]; then
    echo "ERROR: GITLAB_TOKEN is not set. Run init-gitlab.sh first."
    exit 1
fi

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"
PROJECT_PATH="root/test-repo"
PROJECT_ENCODED="root%2Ftest-repo"
BRANCH_NAME="test-bad-code-$(date +%s)"
POLL_TIMEOUT=120

echo "=== End-to-End Review Test ==="

# --- Create branch ---
echo "Creating branch '${BRANCH_NAME}'..."

curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"branch\": \"${BRANCH_NAME}\",
        \"ref\": \"main\"
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/repository/branches" >/dev/null

echo "  Branch created."

# --- Commit bad code ---
echo "Committing bad_example.py..."

BAD_CODE=$(cat <<'PYEOF'
import os, sys, subprocess

def process(data):
    eval(data)
    password = "hardcoded_secret_123"
    query = "SELECT * FROM users WHERE name = '" + data + "'"
    subprocess.call(data, shell=True)
    f = open("/tmp/test")
    return query
PYEOF
)

ENCODED_CONTENT=$(echo "$BAD_CODE" | base64 -w 0)

curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"branch\": \"${BRANCH_NAME}\",
        \"commit_message\": \"Add bad_example.py for review testing\",
        \"actions\": [{
            \"action\": \"create\",
            \"file_path\": \"bad_example.py\",
            \"encoding\": \"base64\",
            \"content\": \"${ENCODED_CONTENT}\"
        }]
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/repository/commits" >/dev/null

echo "  Bad code committed."

# --- Create merge request ---
echo "Creating merge request..."

MR_RESPONSE=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"source_branch\": \"${BRANCH_NAME}\",
        \"target_branch\": \"main\",
        \"title\": \"Test MR: bad code for review\",
        \"remove_source_branch\": true
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/merge_requests")

MR_IID=$(echo "$MR_RESPONSE" | grep -o '"iid":[0-9]*' | head -1 | cut -d: -f2)

if [ -z "${MR_IID:-}" ]; then
    echo "ERROR: Failed to create merge request."
    echo "$MR_RESPONSE"
    exit 1
fi

echo "  Merge request created: !${MR_IID}"
echo "  URL: ${GITLAB_URL}/${PROJECT_PATH}/-/merge_requests/${MR_IID}"

# --- Poll for bot comments ---
echo "Waiting for bot review comment (timeout: ${POLL_TIMEOUT}s)..."

elapsed=0
interval=5

while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    NOTES=$(curl -sf \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/merge_requests/${MR_IID}/notes" 2>/dev/null || echo "[]")

    # Check for notes not authored by root (i.e., from the bot)
    # Or check for notes containing review-related keywords
    NOTE_COUNT=$(echo "$NOTES" | grep -c '"body"' || true)

    if [ "$NOTE_COUNT" -gt 0 ]; then
        # Check if any note looks like a bot review (not the system notes)
        if echo "$NOTES" | grep -q '"system":false'; then
            echo ""
            echo "=== Bot comment detected after ${elapsed}s ==="
            echo ""
            # Print the first non-system note body
            echo "$NOTES" | python3 -c "
import sys, json
notes = json.load(sys.stdin)
for n in notes:
    if not n.get('system', True):
        print(f\"Author: {n['author']['username']}\")
        print(f\"Body:\n{n['body'][:500]}\")
        break
" 2>/dev/null || echo "$NOTES" | head -20
            echo ""
            echo "=== Test PASSED ==="
            exit 0
        fi
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "  ...polling (${elapsed}s elapsed)"
done

echo ""
echo "=== Test FAILED: No bot comment within ${POLL_TIMEOUT}s ==="
echo "Check bot logs: docker compose logs bot"
exit 1
