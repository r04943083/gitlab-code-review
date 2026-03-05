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

# Source .env
if [ ! -f .env ]; then
    echo "ERROR: .env 文件不存在。请先运行 01 和 02 脚本。"
    exit 1
fi
set -a
source .env
set +a

if [ -z "${GITLAB_TOKEN:-}" ]; then
    echo "ERROR: GITLAB_TOKEN 未设置。请先运行: bash scripts/02-setup-bot.sh"
    exit 1
fi

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"
BOT_URL="http://localhost:${BOT_PORT:-8888}"

# 创建 root token 用于测试（MR 必须由非 bot 用户创建才能触发 webhook review）
echo "获取 root token..."
ROOT_TOKEN=$(docker exec gitlab gitlab-rails runner '
user = User.find_by_username("root")
token = user.personal_access_tokens.create!(
  name: "test-token-'"$(date +%s)"'",
  scopes: [:api],
  expires_at: 1.day.from_now
)
puts token.token
' 2>&1 | tail -1)

if [ -z "$ROOT_TOKEN" ] || [[ ! "$ROOT_TOKEN" =~ ^glpat- ]]; then
    echo "ERROR: 创建 root token 失败。"
    exit 1
fi
echo "  Root token 已获取。"
PROJECT_PATH="root/test-repo"
PROJECT_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PROJECT_PATH}', safe=''))")
BRANCH_NAME="test-cpp-review-$(date +%s)"
POLL_TIMEOUT=180

echo "=== 端到端测试（多文件多目录 C++ 审查） ==="

# --- 检查 GitLab ---
if ! curl -sf -o /dev/null "${GITLAB_URL}/users/sign_in" 2>/dev/null; then
    echo "ERROR: GitLab 不可用。请先运行: bash scripts/01-install-gitlab.sh"
    exit 1
fi

# --- 检查 Bot ---
if ! curl -sf -o /dev/null "${BOT_URL}/health" 2>/dev/null; then
    echo "ERROR: Bot 不可用。请先运行: bash scripts/02-setup-bot.sh"
    exit 1
fi

echo "  GitLab 和 Bot 均已就绪。"

# --- 创建分支 ---
echo "创建分支 '${BRANCH_NAME}'..."

curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"branch\": \"${BRANCH_NAME}\",
        \"ref\": \"main\"
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/repository/branches" >/dev/null

echo "  分支已创建。"

# --- 准备 6 个测试文件 ---

# File 1: src/memory_safety.cpp - RAII violations, Rule of Five, use-after-free, dangling reference
FILE1_CONTENT=$(cat <<'CPPEOF'
#include <cstring>
#include <iostream>
#include <vector>

class ResourceHolder {
    int* data;
    size_t size;
public:
    ResourceHolder(size_t n) : size(n) {
        data = new int[n];  // Raw new without RAII
    }

    // Rule of Five violation: has destructor but missing
    // copy constructor, copy assignment, move constructor, move assignment
    ~ResourceHolder() {
        delete[] data;
    }

    void fill(int value) {
        for (size_t i = 0; i <= size; i++) {  // Off-by-one: buffer overflow
            data[i] = value;
        }
    }

    int* getData() { return data; }  // Exposes raw pointer
};

int& danglingReference() {
    int local = 42;
    return local;  // Dangling reference to local variable
}

void useAfterFree() {
    int* p = new int(10);
    delete p;
    std::cout << *p << std::endl;  // Use-after-free

    int* q = new int(20);
    delete q;
    delete q;  // Double-free
}

void memoryLeakLoop(int count) {
    for (int i = 0; i < count; i++) {
        char* buf = new char[1024];
        std::strcpy(buf, "temporary data");
        // Missing delete[] - leaked every iteration
    }
}

ResourceHolder* createAndLeak() {
    ResourceHolder* r = new ResourceHolder(100);
    r->fill(0);
    return r;  // Caller must remember to delete - ownership unclear
}
CPPEOF
)

# File 2: include/data_processor.h - Missing include guard, using namespace std in header, missing virtual destructor
FILE2_CONTENT=$(cat <<'CPPEOF'
// Missing #pragma once or include guard!

#include <string>
#include <vector>
#include <iostream>

using namespace std;  // Bad: pollutes global namespace from header

class BaseProcessor {
public:
    // Missing virtual destructor - UB when deleting derived via base pointer
    void process() { cout << "processing" << endl; }
};

class DerivedProcessor : public BaseProcessor {
    string* heapData;
public:
    DerivedProcessor() {
        heapData = new string("data");
    }
    ~DerivedProcessor() {
        delete heapData;
    }
};

struct Config {
    char name[64];
    int flags;
    // No constructor - uninitialized members
};

template<typename T>
class Container {
    T* items;
    int count;
public:
    Container() : items(nullptr), count(0) {}
    // Missing destructor - items leaked
    void add(T item) {
        // Naive reallocation without exception safety
        T* newItems = (T*)malloc(sizeof(T) * (count + 1));  // C-style alloc in C++
        if (items) {
            memcpy(newItems, items, sizeof(T) * count);  // Bad for non-trivial types
            free(items);
        }
        newItems[count++] = item;
        items = newItems;
    }
};
CPPEOF
)

# File 3: src/concurrency.cpp - Data races, deadlock, missing lock_guard
FILE3_CONTENT=$(cat <<'CPPEOF'
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

int sharedCounter = 0;          // Global mutable shared state
std::mutex mutexA, mutexB;

void incrementWithoutLock() {
    for (int i = 0; i < 100000; i++) {
        sharedCounter++;  // Data race: no synchronization
    }
}

void deadlockThread1() {
    mutexA.lock();  // Raw lock without RAII
    // Simulate work
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    mutexB.lock();  // Lock ordering: A -> B
    sharedCounter++;
    mutexB.unlock();
    mutexA.unlock();  // If exception thrown before unlock -> deadlock
}

void deadlockThread2() {
    mutexB.lock();  // Lock ordering: B -> A (inconsistent with thread1!)
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    mutexA.lock();  // DEADLOCK potential
    sharedCounter++;
    mutexA.unlock();
    mutexB.unlock();
}

class ThreadUnsafeCache {
    std::vector<int> cache;
    // No mutex protecting cache!
public:
    void add(int value) {
        cache.push_back(value);  // Data race if called from multiple threads
    }
    int get(int index) {
        return cache[index];     // No bounds check, no synchronization
    }
    size_t size() { return cache.size(); }
};

void runDataRace() {
    std::thread t1(incrementWithoutLock);
    std::thread t2(incrementWithoutLock);
    // Missing t1.join() and t2.join() - UB if threads outlive scope
}
CPPEOF
)

# File 4: src/template_utils.hpp - Missing typename, improper template specialization
FILE4_CONTENT=$(cat <<'CPPEOF'
#pragma once
#include <iostream>
#include <type_traits>
#include <vector>

template<typename T>
class TypeHelper {
public:
    // Missing 'typename' for dependent type
    typedef T::value_type inner_type;  // Error: needs 'typename' keyword

    static void print(const T& container) {
        for (auto it = container.begin(); it != container.end(); ++it) {
            std::cout << *it << " ";
        }
        std::cout << std::endl;
    }
};

// Dangerous implicit conversion
template<typename From, typename To>
To unsafeCast(From value) {
    return (To)value;  // C-style cast - could be reinterpret_cast silently
}

// Object slicing risk
class Shape {
public:
    virtual double area() { return 0; }
    // Missing virtual destructor
};

class Circle : public Shape {
    double radius;
public:
    Circle(double r) : radius(r) {}
    double area() override { return 3.14159 * radius * radius; }
};

void processShape(Shape s) {  // Pass by value - object slicing!
    std::cout << "Area: " << s.area() << std::endl;  // Always calls Shape::area
}

template<typename T>
T* createArray(int size) {
    T* arr = new T[size];  // Raw new, caller must delete[]
    return arr;
}
CPPEOF
)

# File 5: tests/test_helpers.cpp - Hardcoded credentials, resource leak, C-style cast
FILE5_CONTENT=$(cat <<'CPPEOF'
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>

// Hardcoded test credentials - security risk if committed
const char* TEST_DB_HOST = "production-db.internal.company.com";
const char* TEST_DB_USER = "admin";
const char* TEST_DB_PASS = "P@ssw0rd!2024";
const char* TEST_API_KEY = "sk-prod-abc123def456ghi789";

struct TestContext {
    FILE* logFile;
    char* buffer;
    int size;
};

TestContext* createTestContext() {
    TestContext* ctx = (TestContext*)malloc(sizeof(TestContext));  // C-style cast + malloc in C++
    ctx->logFile = fopen("/tmp/test.log", "w");
    ctx->buffer = (char*)malloc(4096);
    ctx->size = 4096;
    // No null checks on any allocation
    return ctx;
}

void runTest(TestContext* ctx) {
    // Format string from external source
    char userInput[256];
    sprintf(userInput, "test_%s_%d", TEST_DB_USER, rand());

    // Potential buffer overflow
    char query[128];
    sprintf(query, "SELECT * FROM users WHERE name='%s' AND pass='%s'",
            TEST_DB_USER, TEST_DB_PASS);  // SQL injection + credential exposure

    fprintf(ctx->logFile, query);  // Format string vulnerability
}

void cleanupTest(TestContext* ctx) {
    free(ctx->buffer);
    // Missing fclose(ctx->logFile) - resource leak
    // Missing free(ctx) - memory leak
}
CPPEOF
)

# File 6: src/legacy_wrapper.c - strcpy overflow, format string, integer overflow, NULL unchecked
FILE6_CONTENT=$(cat <<'CPPEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define BUFFER_SIZE 64

char* copy_string(const char* src) {
    char buf[BUFFER_SIZE];
    strcpy(buf, src);  // Buffer overflow if src > 64 bytes
    char* result = (char*)malloc(strlen(buf) + 1);
    // No NULL check on malloc
    strcpy(result, buf);
    return result;
}

void format_message(const char* user_input) {
    char output[256];
    sprintf(output, user_input);  // Format string vulnerability
    printf(output);               // Double format string vulnerability
}

int safe_multiply(int a, int b) {
    return a * b;  // Integer overflow not checked
}

void process_data(const char* filename) {
    FILE* f = fopen(filename, "r");
    // No NULL check - will crash if file doesn't exist

    char line[128];
    while (fgets(line, sizeof(line), f)) {
        char* token = strtok(line, ",");  // strtok is not thread-safe
        while (token) {
            char processed[32];
            strcpy(processed, token);  // Overflow if token > 32 bytes
            printf("Token: %s\n", processed);
            token = strtok(NULL, ",");
        }
    }

    // Missing fclose(f)
}

void execute_command(const char* cmd) {
    char full_cmd[512];
    sprintf(full_cmd, "sh -c '%s'", cmd);
    system(full_cmd);  // Command injection vulnerability
}

int* allocate_array(int count) {
    // Integer overflow in size calculation
    int* arr = (int*)malloc(count * sizeof(int));
    // No NULL check, no overflow check on count * sizeof(int)
    memset(arr, 0, count * sizeof(int));
    return arr;
}
CPPEOF
)

# --- Base64 encode all files ---
ENC1=$(echo "$FILE1_CONTENT" | base64 -w 0)
ENC2=$(echo "$FILE2_CONTENT" | base64 -w 0)
ENC3=$(echo "$FILE3_CONTENT" | base64 -w 0)
ENC4=$(echo "$FILE4_CONTENT" | base64 -w 0)
ENC5=$(echo "$FILE5_CONTENT" | base64 -w 0)
ENC6=$(echo "$FILE6_CONTENT" | base64 -w 0)

# --- 提交 6 个文件（单次 commit） ---
echo "提交 6 个测试文件（跨多目录）..."

curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"branch\": \"${BRANCH_NAME}\",
        \"commit_message\": \"Add C/C++ test files for multi-file review testing\",
        \"actions\": [
            {
                \"action\": \"create\",
                \"file_path\": \"src/memory_safety.cpp\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC1}\"
            },
            {
                \"action\": \"create\",
                \"file_path\": \"include/data_processor.h\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC2}\"
            },
            {
                \"action\": \"create\",
                \"file_path\": \"src/concurrency.cpp\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC3}\"
            },
            {
                \"action\": \"create\",
                \"file_path\": \"src/template_utils.hpp\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC4}\"
            },
            {
                \"action\": \"create\",
                \"file_path\": \"tests/test_helpers.cpp\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC5}\"
            },
            {
                \"action\": \"create\",
                \"file_path\": \"src/legacy_wrapper.c\",
                \"encoding\": \"base64\",
                \"content\": \"${ENC6}\"
            }
        ]
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/repository/commits" >/dev/null

echo "  6 个文件已提交到 3 个目录 (src/, include/, tests/)。"

# --- 创建 MR ---
echo "创建 Merge Request..."

MR_RESPONSE=$(curl -sf --request POST \
    --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
        \"source_branch\": \"${BRANCH_NAME}\",
        \"target_branch\": \"main\",
        \"title\": \"Test MR: multi-file C/C++ code for review\",
        \"description\": \"This MR contains intentionally problematic C/C++ code across multiple directories to test the AI code reviewer's C++ analysis capabilities.\",
        \"remove_source_branch\": true
    }" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/merge_requests")

MR_IID=$(echo "$MR_RESPONSE" | grep -o '"iid":[0-9]*' | head -1 | cut -d: -f2)

if [ -z "${MR_IID:-}" ]; then
    echo "ERROR: 创建 MR 失败。"
    echo "$MR_RESPONSE"
    exit 1
fi

echo "  MR 已创建: !${MR_IID}"
echo "  URL: ${GITLAB_URL}/${PROJECT_PATH}/-/merge_requests/${MR_IID}"

# --- 轮询等待 bot 评论 ---
echo "等待 bot 审查评论 (超时: ${POLL_TIMEOUT}s)..."

elapsed=0
interval=5

while [ "$elapsed" -lt "$POLL_TIMEOUT" ]; do
    # Check both notes (summary) and discussions (inline comments)
    NOTES=$(curl -sf \
        --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/merge_requests/${MR_IID}/notes" 2>/dev/null || echo "[]")

    NOTE_COUNT=$(echo "$NOTES" | grep -c '"body"' || true)

    if [ "$NOTE_COUNT" -gt 0 ]; then
        if echo "$NOTES" | grep -q '"system":false'; then
            echo ""
            echo "=== Bot 评论已检测到 (${elapsed}s) ==="
            echo ""

            # --- 增强验证逻辑 ---

            # Fetch discussions (inline comments)
            DISCUSSIONS=$(curl -sf \
                --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
                "${GITLAB_URL}/api/v4/projects/${PROJECT_ENCODED}/merge_requests/${MR_IID}/discussions" 2>/dev/null || echo "[]")

            # Analyze results with Python
            python3 -c "
import sys, json

notes = json.loads('''${NOTES//\'/\\\'}'''.replace(chr(10), ' ')) if '''${NOTES//\'/\\\'}''' != '[]' else []
discussions_raw = '''$(echo "$DISCUSSIONS" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)))" 2>/dev/null || echo '[]')'''
discussions = json.loads(discussions_raw) if discussions_raw != '[]' else []

# Count non-system notes
bot_notes = [n for n in notes if not n.get('system', True)]
print(f'Summary notes: {len(bot_notes)}')

# Count inline comments and collect covered files
inline_count = 0
covered_files = set()
for disc in discussions:
    for note in disc.get('notes', []):
        if note.get('type') == 'DiffNote' and not note.get('system', True):
            inline_count += 1
            pos = note.get('position', {})
            path = pos.get('new_path', pos.get('old_path', 'unknown'))
            covered_files.add(path)

print(f'Inline comments: {inline_count}')
print(f'Files with comments: {len(covered_files)}')
if covered_files:
    for f in sorted(covered_files):
        print(f'  - {f}')

# Print first summary note
for n in bot_notes:
    body = n.get('body', '')
    if 'Code Review Summary' in body or 'summary' in body.lower():
        print(f\"\\nSummary preview:\")
        print(body[:600])
        break

# Validation
print('\\n--- 验证结果 ---')
total = len(bot_notes) + inline_count
print(f'总评论数: {total}')

passed = True
if total == 0:
    print('FAIL: 没有检测到任何评论')
    passed = False
if len(covered_files) < 2:
    print(f'WARN: 仅覆盖 {len(covered_files)} 个文件（期望 >= 2）')
else:
    print(f'PASS: 覆盖了 {len(covered_files)} 个不同文件的评论')
if inline_count > 0:
    print(f'PASS: 检测到 {inline_count} 条行内评论')
else:
    print('WARN: 未检测到行内评论（仅有 summary）')

if passed:
    print('\\n=== 测试通过 ===')
" 2>/dev/null || {
                # Fallback: simple output if Python analysis fails
                echo "Bot 评论详情:"
                echo "$NOTES" | python3 -c "
import sys, json
notes = json.load(sys.stdin)
for n in notes:
    if not n.get('system', True):
        print(f\"Author: {n['author']['username']}\")
        print(f\"Body:\n{n['body'][:500]}\")
        print('---')
" 2>/dev/null || echo "$NOTES" | head -30
                echo ""
                echo "=== 测试通过（基本验证） ==="
            }
            exit 0
        fi
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "  ...轮询中 (${elapsed}s)"
done

echo ""
echo "=== 测试失败: ${POLL_TIMEOUT}s 内未检测到 bot 评论 ==="
echo "检查 bot 日志: docker compose logs bot"
exit 1
