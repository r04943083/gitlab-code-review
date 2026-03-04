# GitLab AI Code Review Bot 部署指南

[English](#english) | [中文](#中文)

---

## 中文

### 概述

本指南面向**已在内网部署 GitLab** 的团队，说明如何单独部署 AI Code Review Bot，为现有的 GitLab 实例添加智能代码审查能力。

### 系统架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        内网环境                                      │
│                                                                     │
│  ┌──────────────┐      Webhook       ┌──────────────────────────┐  │
│  │              │  ─────────────────► │                          │  │
│  │   GitLab     │                     │   Review Bot (Docker)    │  │
│  │   (现有实例)  │  ◄───────────────── │   :8888                  │  │
│  │              │    API Comments     │                          │  │
│  └──────────────┘                     └────────────┬─────────────┘  │
│                                                    │                │
│                                                    │ HTTP API       │
│                                                    ▼                │
│                                           ┌──────────────────┐     │
│                                           │   LLM 服务        │     │
│                                           │ (Anthropic/Ollama│     │
│                                           │  /vLLM/其他)      │     │
│                                           └──────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

### 工作流程

```
1. 开发者创建/更新 Merge Request
         │
         ▼
2. GitLab 触发 Webhook → POST 到 Review Bot
         │
         ▼
3. Bot 立即返回 HTTP 200（不阻塞 GitLab）
         │
         ▼
4. 后台异步处理：
   ├── 4.1 调用 GitLab API 获取 MR diff
   ├── 4.2 构建 Prompt（包含代码变更）
   ├── 4.3 调用 LLM 获取审查结果（JSON 格式）
   ├── 4.4 解析结果，过滤低优先级问题
   └── 4.5 调用 GitLab API 发布行内评论 + 总结
         │
         ▼
5. 开发者在 MR 页面看到审查评论
```

### 核心组件

| 组件 | 文件 | 职责 |
|------|------|------|
| **Webhook 入口** | `app.py` | 接收 GitLab webhook，验证 token，调度后台任务 |
| **审查编排器** | `reviewer.py` | 协调整个审查流程，过滤文件，处理异常 |
| **GitLab 客户端** | `gitlab_client.py` | 封装 GitLab API（获取 diff、发布评论） |
| **LLM 客户端** | `llm_client.py` | 封装 LLM API（支持 Anthropic/OpenAI 兼容接口） |
| **Prompt 模板** | `prompts.py` | 定义系统提示词，构建用户 prompt |

### 前置条件

1. **已有的 GitLab 实例**
   - 版本 14.0+（推荐 16.x）
   - 管理员权限（用于配置 webhook 白名单）

2. **服务器资源**
   - Docker + Docker Compose
   - 1GB+ 可用内存（Bot 本身很轻量）

3. **LLM 服务**（三选一）
   - Anthropic API Key（外网访问）
   - 内网 Ollama 服务
   - 内网 vLLM/其他 OpenAI 兼容服务

---

## 部署步骤

### 步骤 1：准备配置文件

```bash
# 克隆仓库
git clone https://github.com/r04943083/gitlab-code-review-bot.git
cd gitlab-code-review-bot

# 复制配置模板
cp .env.example .env
```

### 步骤 2：编辑 .env 配置

```bash
# === GitLab 配置 ===
# 你现有 GitLab 的地址
GITLAB_URL=https://gitlab.your-company.com
# 或内网地址（如果 Bot 和 GitLab 在同一网络）
GITLAB_INTERNAL_URL=http://gitlab.internal:80

# GitLab Access Token（需要 api 权限）
GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

# Webhook 验证密钥（自定义一个随机字符串）
GITLAB_WEBHOOK_SECRET=your-random-secret-here

# === LLM 配置 ===
# 选项 A: 使用 Anthropic Claude
LLM_PROVIDER=anthropic
LLM_API_KEY=sk-ant-xxxxxxxx
LLM_MODEL=claude-sonnet-4-20250514

# 选项 B: 使用内网 Ollama
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://ollama-server:11434/v1
LLM_MODEL=qwen2.5-coder:32b

# 选项 C: 使用内网 vLLM
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://vllm-server:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct

# === 审查配置 ===
# 最低评论严重级别（critical/high/medium/low/info）
MIN_SEVERITY=medium
# diff 最大字符数（超出截断，避免 token 超限）
MAX_DIFF_CHARS=30000
```

### 步骤 3：使用独立部署配置

创建 `docker-compose.standalone.yml`（仅包含 Bot，不包含 GitLab）：

```yaml
services:
  bot:
    build: ./bot
    container_name: review-bot
    ports:
      - "${BOT_PORT:-8888}:8888"
    environment:
      - GITLAB_URL=${GITLAB_URL}
      - GITLAB_INTERNAL_URL=${GITLAB_INTERNAL_URL:-${GITLAB_URL}}
      - GITLAB_TOKEN=${GITLAB_TOKEN}
      - GITLAB_WEBHOOK_SECRET=${GITLAB_WEBHOOK_SECRET}
      - LLM_PROVIDER=${LLM_PROVIDER}
      - LLM_API_KEY=${LLM_API_KEY}
      - LLM_API_BASE=${LLM_API_BASE}
      - LLM_MODEL=${LLM_MODEL}
      - LLM_MAX_TOKENS=${LLM_MAX_TOKENS:-4096}
      - MIN_SEVERITY=${MIN_SEVERITY:-medium}
      - MAX_DIFF_CHARS=${MAX_DIFF_CHARS:-30000}
      - BOT_PORT=${BOT_PORT:-8888}
    restart: unless-stopped
    extra_hosts:
      # 允许容器访问宿主机网络（Linux）
      - "host.docker.internal:host-gateway"
```

### 步骤 4：启动 Bot

```bash
# 构建并启动
docker compose -f docker-compose.standalone.yml up -d --build

# 查看日志
docker logs -f review-bot
```

### 步骤 5：配置 GitLab Webhook

**方法 A：通过 GitLab UI 配置**

1. 进入项目 → Settings → Webhooks
2. 填写：
   - **URL**: `http://bot-server:8888/webhook`
   - **Secret Token**: 与 `.env` 中 `GITLAB_WEBHOOK_SECRET` 一致
   - **Trigger**: 勾选 `Merge request events`
   - **SSL verification**: 取消勾选（如果是 HTTP）

**方法 B：通过 API 配置**

```bash
# 替换变量
GITLAB_URL="https://gitlab.your-company.com"
PROJECT_ID="123"  # 你的项目 ID
PRIVATE_TOKEN="glpat-xxxxxxxx"
WEBHOOK_URL="http://bot-server:8888/webhook"
WEBHOOK_SECRET="your-random-secret-here"

curl --request POST \
  --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{
    \"url\": \"$WEBHOOK_URL\",
    \"token\": \"$WEBHOOK_SECRET\",
    \"merge_requests_events\": true,
    \"push_events\": false,
    \"enable_ssl_verification\": false
  }" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks"
```

### 步骤 6：允许本地网络 Webhook（重要！）

如果 Bot 和 GitLab 在同一内网，需要允许本地网络请求：

**方法 A：通过 GitLab Admin UI**

Admin Area → Settings → Network → Outbound requests
- 勾选 `Allow requests to the local network from web hooks and services`

**方法 B：通过 Rails Console**

```bash
# 进入 GitLab 服务器
docker exec -it <gitlab-container> gitlab-rails runner "
ApplicationSetting.first.update!(allow_local_requests_from_web_hooks_and_services: true)
puts 'Done'
"
```

---

## 验证部署

### 测试 Webhook 连通性

```bash
# 从 GitLab 服务器测试
curl http://bot-server:8888/health
# 期望返回: {"status":"ok"}
```

### 创建测试 MR

1. 在项目中创建新分支
2. 添加一些包含潜在问题的代码
3. 创建 Merge Request
4. 检查 MR 中是否出现 Bot 评论

### 查看日志

```bash
docker logs review-bot --tail 100
```

---

## 高级配置

### 调整审查严格程度

```bash
# 只报告严重问题
MIN_SEVERITY=high

# 报告所有问题（包括建议）
MIN_SEVERITY=info
```

### 处理大型 MR

```bash
# 增加 diff 最大字符数（注意 token 限制）
MAX_DIFF_CHARS=50000

# 增加 LLM 输出 token
LLM_MAX_TOKENS=8192
```

### 自定义跳过的文件

编辑 `bot/reviewer.py` 中的 `SKIP_EXTENSIONS` 和 `SKIP_FILENAMES`：

```python
SKIP_EXTENSIONS = {".lock", ".min.js", ".min.css", ...}
SKIP_FILENAMES = {"package-lock.json", "yarn.lock", ...}
```

---

## 扩展开发

### 添加新的 LLM 提供商

编辑 `bot/llm_client.py`，添加新的调用方法：

```python
async def _call_your_provider(self, user_prompt: str) -> str:
    # 实现你的 LLM API 调用逻辑
    pass
```

### 自定义 Prompt

编辑 `bot/prompts.py`：

```python
SYSTEM_PROMPT = """你是一个专业的代码审查专家...
# 添加你的自定义规则
"""
```

### 添加新的审查规则

在 `ReviewOrchestrator._should_review()` 中添加文件过滤逻辑，或在 prompt 中添加特定检查要求。

---

## 故障排除

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| Webhook 403 | Secret Token 不匹配 | 检查 `.env` 和 GitLab webhook 配置 |
| Webhook 422 | URL 无效 | 启用本地网络 webhook 白名单 |
| 无评论出现 | LLM API 失败 | 检查 `docker logs review-bot` |
| 评论延迟长 | LLM 响应慢 | 考虑使用更快的模型 |
| Token 超限 | diff 太大 | 减小 `MAX_DIFF_CHARS` |

---

## English

### Overview

This guide is for teams that **already have GitLab deployed in their intranet**, explaining how to deploy the AI Code Review Bot separately to add intelligent code review capabilities to your existing GitLab instance.

### System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Intranet Environment                          │
│                                                                     │
│  ┌──────────────┐      Webhook       ┌──────────────────────────┐  │
│  │              │  ─────────────────► │                          │  │
│  │   GitLab     │                     │   Review Bot (Docker)    │  │
│  │   (Existing) │  ◄───────────────── │   :8888                  │  │
│  │              │    API Comments     │                          │  │
│  └──────────────┘                     └────────────┬─────────────┘  │
│                                                    │                │
│                                                    │ HTTP API       │
│                                                    ▼                │
│                                           ┌──────────────────┐     │
│                                           │   LLM Service    │     │
│                                           │ (Anthropic/Ollama│     │
│                                           │  /vLLM/etc.)     │     │
│                                           └──────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

### Workflow

```
1. Developer creates/updates Merge Request
         │
         ▼
2. GitLab triggers Webhook → POST to Review Bot
         │
         ▼
3. Bot returns HTTP 200 immediately (non-blocking)
         │
         ▼
4. Background async processing:
   ├── 4.1 Call GitLab API to fetch MR diff
   ├── 4.2 Build Prompt (with code changes)
   ├── 4.3 Call LLM to get review results (JSON format)
   ├── 4.4 Parse results, filter low-priority issues
   └── 4.5 Call GitLab API to post inline comments + summary
         │
         ▼
5. Developer sees review comments in MR page
```

### Core Components

| Component | File | Responsibility |
|-----------|------|----------------|
| **Webhook Entry** | `app.py` | Receive GitLab webhook, validate token, dispatch background task |
| **Review Orchestrator** | `reviewer.py` | Coordinate review flow, filter files, handle exceptions |
| **GitLab Client** | `gitlab_client.py` | Wrap GitLab API (fetch diff, post comments) |
| **LLM Client** | `llm_client.py` | Wrap LLM API (supports Anthropic/OpenAI-compatible) |
| **Prompt Template** | `prompts.py` | Define system prompt, build user prompt |

### Prerequisites

1. **Existing GitLab Instance**
   - Version 14.0+ (16.x recommended)
   - Admin access (for webhook whitelist configuration)

2. **Server Resources**
   - Docker + Docker Compose
   - 1GB+ available memory (Bot itself is lightweight)

3. **LLM Service** (choose one)
   - Anthropic API Key (internet access required)
   - Internal Ollama service
   - Internal vLLM or other OpenAI-compatible service

---

## Deployment Steps

### Step 1: Prepare Configuration

```bash
# Clone repository
git clone https://github.com/r04943083/gitlab-code-review-bot.git
cd gitlab-code-review-bot

# Copy configuration template
cp .env.example .env
```

### Step 2: Edit .env Configuration

```bash
# === GitLab Configuration ===
# Your existing GitLab URL
GITLAB_URL=https://gitlab.your-company.com
# Or internal URL (if Bot and GitLab are on same network)
GITLAB_INTERNAL_URL=http://gitlab.internal:80

# GitLab Access Token (requires api scope)
GITLAB_TOKEN=glpat-xxxxxxxxxxxxxxxxxxxx

# Webhook verification secret (custom random string)
GITLAB_WEBHOOK_SECRET=your-random-secret-here

# === LLM Configuration ===
# Option A: Use Anthropic Claude
LLM_PROVIDER=anthropic
LLM_API_KEY=sk-ant-xxxxxxxx
LLM_MODEL=claude-sonnet-4-20250514

# Option B: Use internal Ollama
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://ollama-server:11434/v1
LLM_MODEL=qwen2.5-coder:32b

# Option C: Use internal vLLM
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://vllm-server:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct

# === Review Configuration ===
# Minimum comment severity (critical/high/medium/low/info)
MIN_SEVERITY=medium
# Max diff characters (truncated beyond to avoid token limits)
MAX_DIFF_CHARS=30000
```

### Step 3: Create Standalone Deployment Config

Create `docker-compose.standalone.yml` (Bot only, no GitLab):

```yaml
services:
  bot:
    build: ./bot
    container_name: review-bot
    ports:
      - "${BOT_PORT:-8888}:8888"
    environment:
      - GITLAB_URL=${GITLAB_URL}
      - GITLAB_INTERNAL_URL=${GITLAB_INTERNAL_URL:-${GITLAB_URL}}
      - GITLAB_TOKEN=${GITLAB_TOKEN}
      - GITLAB_WEBHOOK_SECRET=${GITLAB_WEBHOOK_SECRET}
      - LLM_PROVIDER=${LLM_PROVIDER}
      - LLM_API_KEY=${LLM_API_KEY}
      - LLM_API_BASE=${LLM_API_BASE}
      - LLM_MODEL=${LLM_MODEL}
      - LLM_MAX_TOKENS=${LLM_MAX_TOKENS:-4096}
      - MIN_SEVERITY=${MIN_SEVERITY:-medium}
      - MAX_DIFF_CHARS=${MAX_DIFF_CHARS:-30000}
      - BOT_PORT=${BOT_PORT:-8888}
    restart: unless-stopped
    extra_hosts:
      # Allow container to access host network (Linux)
      - "host.docker.internal:host-gateway"
```

### Step 4: Start Bot

```bash
# Build and start
docker compose -f docker-compose.standalone.yml up -d --build

# View logs
docker logs -f review-bot
```

### Step 5: Configure GitLab Webhook

**Method A: Via GitLab UI**

1. Go to Project → Settings → Webhooks
2. Fill in:
   - **URL**: `http://bot-server:8888/webhook`
   - **Secret Token**: Same as `GITLAB_WEBHOOK_SECRET` in `.env`
   - **Trigger**: Check `Merge request events`
   - **SSL verification**: Uncheck (if using HTTP)

**Method B: Via API**

```bash
# Replace variables
GITLAB_URL="https://gitlab.your-company.com"
PROJECT_ID="123"  # Your project ID
PRIVATE_TOKEN="glpat-xxxxxxxx"
WEBHOOK_URL="http://bot-server:8888/webhook"
WEBHOOK_SECRET="your-random-secret-here"

curl --request POST \
  --header "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{
    \"url\": \"$WEBHOOK_URL\",
    \"token\": \"$WEBHOOK_SECRET\",
    \"merge_requests_events\": true,
    \"push_events\": false,
    \"enable_ssl_verification\": false
  }" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks"
```

### Step 6: Allow Local Network Webhooks (Important!)

If Bot and GitLab are on the same intranet, you need to allow local network requests:

**Method A: Via GitLab Admin UI**

Admin Area → Settings → Network → Outbound requests
- Check `Allow requests to the local network from web hooks and services`

**Method B: Via Rails Console**

```bash
# Enter GitLab server
docker exec -it <gitlab-container> gitlab-rails runner "
ApplicationSetting.first.update!(allow_local_requests_from_web_hooks_and_services: true)
puts 'Done'
"
```

---

## Verify Deployment

### Test Webhook Connectivity

```bash
# Test from GitLab server
curl http://bot-server:8888/health
# Expected: {"status":"ok"}
```

### Create Test MR

1. Create a new branch in the project
2. Add some code with potential issues
3. Create a Merge Request
4. Check if Bot comments appear in the MR

### View Logs

```bash
docker logs review-bot --tail 100
```

---

## Troubleshooting

| Issue | Possible Cause | Solution |
|-------|----------------|----------|
| Webhook 403 | Secret Token mismatch | Check `.env` and GitLab webhook config |
| Webhook 422 | Invalid URL | Enable local network webhook whitelist |
| No comments | LLM API failure | Check `docker logs review-bot` |
| Slow comments | LLM response slow | Consider using a faster model |
| Token limit exceeded | Diff too large | Reduce `MAX_DIFF_CHARS` |

---

## License

MIT
