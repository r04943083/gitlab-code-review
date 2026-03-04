# GitLab AI Code Review Bot

[中文](#中文) | [English](#english)

---

## 中文

### 简介

基于 AI 的 GitLab Merge Request 代码审查机器人。当开发者创建或更新 MR 时，Bot 会自动分析代码变更并以行内评论的形式提供审查意见。

**特性：**
- 自动审查 MR 代码变更，发现安全漏洞、代码质量问题
- 支持行内评论（精确到具体代码行）
- 支持多种 LLM 后端：Anthropic Claude、OpenAI 兼容 API（Ollama、vLLM 等）
- Docker Compose 一键部署
- 适配内网无互联网环境

### 架构

```
开发者推送代码 → GitLab MR 创建/更新
  → GitLab Webhook POST → review-bot:8888/webhook
  → Bot 返回 HTTP 200（立即响应）
  → 后台异步任务：
      1. 获取 MR diff 信息
      2. 构建 prompt 调用 LLM
      3. 解析结构化审查结果
      4. 发布行内评论 + 总结
```

```
┌─────────────── Docker Network: gl-net ────────────────┐
│  GitLab CE (:8080)  ←webhook→  Review Bot (:8888)     │
│  GitLab Runner (docker executor)                       │
└────────────────────────────────────────────────────────┘
                        │ LLM API
                  本地 LLM / Anthropic API
```

### 快速开始

#### 前置条件

- Docker 和 Docker Compose
- 至少 4GB 可用内存（GitLab CE 需要较多资源）
- LLM API 访问（Anthropic API Key 或本地 LLM 服务）

#### 五步部署

```bash
# 1. 克隆仓库
git clone https://github.com/r04943083/gitlab-code-review-bot.git
cd gitlab-code-review-bot

# 2. 配置环境变量
cp .env.example .env
# 编辑 .env，填入 LLM_API_KEY 等配置

# 3. 一键启动（构建镜像 + 启动服务 + 等待 GitLab 就绪）
bash scripts/setup.sh

# 4. 初始化 GitLab（创建 Token、测试项目、Webhook）
bash scripts/init-gitlab.sh

# 5. 运行端到端测试
bash scripts/test-review.sh
```

完成后访问 `http://localhost:8080` 查看 MR 中的审查评论。

### 配置说明

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GITLAB_PORT` | GitLab 端口 | `8080` |
| `GITLAB_ROOT_PASSWORD` | GitLab root 密码 | `changeme123` |
| `GITLAB_TOKEN` | GitLab API Token（由 init-gitlab.sh 自动生成） | - |
| `GITLAB_WEBHOOK_SECRET` | Webhook 验证密钥 | `webhook-secret-change-me` |
| `LLM_PROVIDER` | LLM 提供商：`anthropic` 或 `openai_compatible` | `anthropic` |
| `LLM_API_KEY` | LLM API 密钥 | - |
| `LLM_API_BASE` | LLM API 地址 | `https://api.anthropic.com` |
| `LLM_MODEL` | 模型名称 | `claude-sonnet-4-20250514` |
| `LLM_MAX_TOKENS` | 最大输出 token 数 | `4096` |
| `MIN_SEVERITY` | 最低评论严重级别（critical/high/medium/low/info） | `medium` |
| `MAX_DIFF_CHARS` | Diff 最大字符数（超出截断） | `30000` |
| `BOT_PORT` | Bot 服务端口 | `8888` |

### 内网 LLM 配置

#### Ollama

```bash
# .env 配置
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://host.docker.internal:11434/v1
LLM_MODEL=qwen2.5-coder:32b
```

#### vLLM

```bash
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://<vllm-host>:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct
```

> **注意**: Linux 上 `host.docker.internal` 可能不可用，需替换为宿主机实际 IP。
> 可在 docker-compose.yml 中添加 `extra_hosts: ["host.docker.internal:host-gateway"]` 解决。

### 常见问题

**Q: GitLab 启动很慢？**
A: 首次启动需要 3-5 分钟，`scripts/setup.sh` 会自动等待。确保至少有 4GB 可用内存。

**Q: Bot 评论没有出现？**
A: 检查：1) Webhook 是否配置正确 2) `docker logs review-bot` 查看日志 3) LLM API 是否可访问

**Q: 行内评论变成了普通评论？**
A: 当 GitLab API 无法将评论定位到具体行时会自动降级。这通常是因为 diff 已过时。

**Q: 如何跳过 Draft MR？**
A: 默认已跳过。Bot 只审查 open/reopen/update 状态的非 Draft MR。

### 项目结构

```
code-review/
├── docker-compose.yml          # GitLab CE + Runner + Review Bot
├── docker-compose.dev.yml      # 开发模式（热重载）
├── .env.example                # 环境变量模板
├── scripts/
│   ├── setup.sh                # 一键启动
│   ├── wait-for-gitlab.sh      # 等待 GitLab 就绪
│   ├── init-gitlab.sh          # 初始化 GitLab 配置
│   ├── register-runner.sh      # 注册 Runner
│   ├── test-review.sh          # 端到端测试
│   └── teardown.sh             # 清理环境
├── bot/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                  # FastAPI 入口
│   ├── config.py               # 配置管理
│   ├── models.py               # 数据模型
│   ├── gitlab_client.py        # GitLab API 客户端
│   ├── llm_client.py           # LLM 客户端
│   ├── reviewer.py             # 审查编排
│   └── prompts.py              # Prompt 模板
├── sample-project/             # 测试用示例项目
├── README.md
└── IMPLEMENTATION_SPEC.md      # 详细实现规格
```

---

## English

### Introduction

An AI-powered GitLab Merge Request code review bot. When developers create or update an MR, the bot automatically analyzes code changes and provides review feedback as inline comments.

**Features:**
- Automatic MR code review detecting security vulnerabilities and code quality issues
- Inline comments pinpointed to specific code lines
- Multiple LLM backends: Anthropic Claude, OpenAI-compatible APIs (Ollama, vLLM, etc.)
- One-click deployment with Docker Compose
- Works in air-gapped/intranet environments

### Architecture

```
Developer pushes code → GitLab MR created/updated
  → GitLab Webhook POST → review-bot:8888/webhook
  → Bot returns HTTP 200 (immediate response)
  → Background async task:
      1. Fetch MR diff info
      2. Build prompt and call LLM
      3. Parse structured review results
      4. Post inline comments + summary
```

```
┌─────────────── Docker Network: gl-net ────────────────┐
│  GitLab CE (:8080)  ←webhook→  Review Bot (:8888)     │
│  GitLab Runner (docker executor)                       │
└────────────────────────────────────────────────────────┘
                        │ LLM API
                  Local LLM / Anthropic API
```

### Quick Start

#### Prerequisites

- Docker and Docker Compose
- At least 4GB available memory (GitLab CE is resource-intensive)
- LLM API access (Anthropic API key or local LLM service)

#### Five-Step Deployment

```bash
# 1. Clone the repository
git clone https://github.com/r04943083/gitlab-code-review-bot.git
cd gitlab-code-review-bot

# 2. Configure environment variables
cp .env.example .env
# Edit .env, fill in LLM_API_KEY and other settings

# 3. One-click start (build images + start services + wait for GitLab)
bash scripts/setup.sh

# 4. Initialize GitLab (create Token, test project, Webhook)
bash scripts/init-gitlab.sh

# 5. Run end-to-end test
bash scripts/test-review.sh
```

After completion, visit `http://localhost:8080` to view review comments in the MR.

### Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `GITLAB_PORT` | GitLab port | `8080` |
| `GITLAB_ROOT_PASSWORD` | GitLab root password | `changeme123` |
| `GITLAB_TOKEN` | GitLab API Token (auto-generated by init-gitlab.sh) | - |
| `GITLAB_WEBHOOK_SECRET` | Webhook verification secret | `webhook-secret-change-me` |
| `LLM_PROVIDER` | LLM provider: `anthropic` or `openai_compatible` | `anthropic` |
| `LLM_API_KEY` | LLM API key | - |
| `LLM_API_BASE` | LLM API base URL | `https://api.anthropic.com` |
| `LLM_MODEL` | Model name | `claude-sonnet-4-20250514` |
| `LLM_MAX_TOKENS` | Max output tokens | `4096` |
| `MIN_SEVERITY` | Minimum comment severity (critical/high/medium/low/info) | `medium` |
| `MAX_DIFF_CHARS` | Max diff characters (truncated beyond) | `30000` |
| `BOT_PORT` | Bot service port | `8888` |

### Intranet LLM Configuration

#### Ollama

```bash
# .env configuration
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://host.docker.internal:11434/v1
LLM_MODEL=qwen2.5-coder:32b
```

#### vLLM

```bash
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://<vllm-host>:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct
```

> **Note**: `host.docker.internal` may not work on Linux. Use the host machine's actual IP instead.
> You can add `extra_hosts: ["host.docker.internal:host-gateway"]` in docker-compose.yml to resolve this.

### FAQ

**Q: GitLab takes too long to start?**
A: First startup takes 3-5 minutes. `scripts/setup.sh` waits automatically. Ensure at least 4GB of available memory.

**Q: Bot comments don't appear?**
A: Check: 1) Webhook configured correctly 2) `docker logs review-bot` for logs 3) LLM API is accessible

**Q: Inline comments became regular comments?**
A: When GitLab API can't position a comment on a specific line, it automatically falls back. This usually happens when the diff is outdated.

**Q: How to skip Draft MRs?**
A: Already skipped by default. The bot only reviews non-Draft MRs with open/reopen/update actions.

### Project Structure

```
code-review/
├── docker-compose.yml          # GitLab CE + Runner + Review Bot
├── docker-compose.dev.yml      # Dev mode (hot reload)
├── .env.example                # Environment variable template
├── scripts/
│   ├── setup.sh                # One-click start
│   ├── wait-for-gitlab.sh      # Wait for GitLab ready
│   ├── init-gitlab.sh          # Initialize GitLab config
│   ├── register-runner.sh      # Register Runner
│   ├── test-review.sh          # End-to-end test
│   └── teardown.sh             # Cleanup
├── bot/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                  # FastAPI entry point
│   ├── config.py               # Configuration management
│   ├── models.py               # Data models
│   ├── gitlab_client.py        # GitLab API client
│   ├── llm_client.py           # LLM client
│   ├── reviewer.py             # Review orchestration
│   └── prompts.py              # Prompt templates
├── sample-project/             # Sample test project
├── README.md
└── IMPLEMENTATION_SPEC.md      # Detailed implementation spec
```

### License

MIT
