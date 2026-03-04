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
BOT_USERNAME="${BOT_USERNAME:-ai-reviewer}"
PROJECT_PATH="${BOT_USERNAME}/test-repo"
PROJECT_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PROJECT_PATH}', safe=''))")
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
echo "Committing bad_example.cpp..."

BAD_CODE=$(cat <<'CPPEOF'
#include <iostream>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <vector>
#include <string>
#include <memory>
#include <fstream>

// Bad practice: using namespace std in header
using namespace std;

// Global variable - bad practice
char* globalBuffer = nullptr;
const int MAX_SIZE = 1024;

// Hardcoded credentials - security issue
const char* DB_PASSWORD = "admin123";
const char* API_KEY = "sk-1234567890abcdef";

class DataProcessor {
private:
    char* buffer;
    size_t size;

public:
    DataProcessor() : buffer(nullptr), size(0) {}

    // Memory leak - no destructor
    // Missing copy constructor and assignment operator (Rule of Three)

    void processInput(const char* input) {
        // No input validation - potential buffer overflow
        strcpy(buffer, input);  // Dangerous: no bounds checking

        // Using unsafe function
        sprintf(buffer, "Processed: %s", input);  // Buffer overflow risk

        // Executing shell command with user input - command injection
        char cmd[256];
        sprintf(cmd, "echo %s", input);
        system(cmd);  // Security vulnerability
    }

    void allocateBuffer(size_t sz) {
        // Memory leak if called multiple times
        buffer = new char[sz];
        size = sz;
    }

    // Raw pointer return - ownership unclear
    char* getBuffer() { return buffer; }

    // Exception safety issue
    void readFromFile(const char* filename) {
        ifstream file(filename);
        if (!file.is_open()) {
            // Should throw exception or return error
            cout << "Error opening file" << endl;
            return;
        }
        file.read(buffer, MAX_SIZE);
        // No error checking on read
    }
};

// C-style code in C++ - should use smart pointers
void legacyFunction(char* data) {
    char localBuffer[100];
    // Potential buffer overflow
    strcpy(localBuffer, data);

    // Memory leak
    char* dynamicMem = (char*)malloc(256);
    // Missing free()

    // Using deprecated function
    gets(localBuffer);  // Extremely dangerous

    // Format string vulnerability
    printf(data);  // Should be printf("%s", data)
}

// Infinite recursion potential
int fibonacci(int n) {
    if (n <= 1) return n;
    return fibonacci(n-1) + fibonacci(n-2);  // O(2^n) complexity
}

// Uninitialized variable
void processArray() {
    int arr[10];  // Uninitialized
    for (int i = 0; i < 10; i++) {
        cout << arr[i] << endl;  // Undefined behavior
    }
}

// SQL injection vulnerability
void executeQuery(const char* username) {
    char query[512];
    sprintf(query, "SELECT * FROM users WHERE username = '%s'", username);
    // executeSQL(query);  // SQL injection
}

// Resource leak
void fileOperations() {
    FILE* f1 = fopen("file1.txt", "r");
    FILE* f2 = fopen("file2.txt", "w");

    if (!f1) {
        return;  // f2 leaked if f1 is null
    }

    // More operations...
    // Missing fclose() calls
}

int main(int argc, char* argv[]) {
    // No argument validation
    DataProcessor processor;
    processor.processInput(argv[1]);  // Crash if no args

    // Using magic numbers
    int data[100];
    for (int i = 0; i < 100; i++) {
        data[i] = i * 2;
    }

    // Integer overflow potential
    int result = 1000000 * 1000000;  // Overflow on 32-bit

    // Null pointer dereference
    char* ptr = nullptr;
    if (strlen(ptr) > 0) {  // Crash!
        cout << ptr << endl;
    }

    return 0;
}
CPPEOF
)

ENCODED_CONTENT=$(echo "$BAD_CODE" | base64 -w 0)

curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"branch\": \"${BRANCH_NAME}\",
        \"commit_message\": \"Add bad_example.cpp for review testing\",
        \"actions\": [{
            \"action\": \"create\",
            \"file_path\": \"bad_example.cpp\",
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
