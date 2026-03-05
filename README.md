# GitLab AI Code Review Bot

基于 AI 的 GitLab Merge Request 代码审查机器人。当开发者创建或更新 MR 时，Bot 自动分析代码变更并以行内评论的形式提供审查意见。

**特性：**
- 自动审查 MR 代码变更，发现安全漏洞、逻辑错误、代码质量问题
- 行内评论精确到具体代码行，支持 GitLab Suggestion 格式
- 支持多种 LLM 后端：Anthropic Claude、OpenAI 兼容 API（Ollama、vLLM 等）
- 模块化两阶段部署，支持脚本和手动操作
- 适配内网无互联网环境

## 架构

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
│  GitLab Runner (docker executor, 可选)                 │
└────────────────────────────────────────────────────────┘
                        │ LLM API
                  本地 LLM / Anthropic API
```

## 前置条件

- Docker 和 Docker Compose v2
- 至少 4GB 可用内存（GitLab CE 需要较多资源）
- LLM API 访问（Anthropic API Key 或本地 LLM 服务）

---

## 第一阶段：安装 GitLab

此阶段仅安装 GitLab，不涉及 AI 组件，可安全地在测试环境验证。

### 脚本方式

```bash
# 克隆仓库
git clone <repo-url>
cd gitlab-code-review

# 一键安装 GitLab（幂等，可重复运行）
bash scripts/01-install-gitlab.sh
```

脚本会自动：检查 Docker → 创建 .env → 启动 GitLab → 等待就绪 → 打印访问信息。

### 手动操作步骤

**1. 准备配置文件**

```bash
cp .env.example .env
# 编辑 .env，按需修改 GITLAB_PORT、GITLAB_ROOT_PASSWORD
```

**2. 启动 GitLab**

```bash
# 仅启动 gitlab 服务（不启动 bot 和 runner）
docker compose up -d gitlab
```

**3. 等待 GitLab 就绪**

首次启动需要 3-5 分钟。可通过以下方式检查：

```bash
# 方式一：使用等待脚本
bash scripts/wait-for-gitlab.sh http://localhost:8080 300

# 方式二：手动检查
curl -f http://localhost:8080/-/health
# 返回 "GitLab OK" 表示就绪
```

**4. 验证登录**

浏览器访问 `http://localhost:8080`，使用以下凭据登录：
- 用户名: `root`
- 密码: `.env` 中的 `GITLAB_ROOT_PASSWORD`（默认 `changeme123`）

---

## 第二阶段：配置 AI 代码审查

此阶段创建 bot 用户、配置 webhook、启动 AI 审查服务。

### 脚本方式

```bash
# 先编辑 .env 设置 LLM_API_KEY
vim .env

# 一键配置（幂等，可重复运行）
bash scripts/02-setup-bot.sh
```

### 手动操作步骤

**1. 创建 Root Access Token**

通过 GitLab UI：
1. 登录 GitLab → 点击头像 → Preferences → Access Tokens
2. Token name: `root-api-token`
3. Scopes: 勾选 `api`
4. 点击 "Create personal access token"
5. 复制生成的 token（以 `glpat-` 开头）

或通过命令行：
```bash
docker exec gitlab gitlab-rails runner '
user = User.find_by_username("root")
token = user.personal_access_tokens.create!(
  name: "root-api-token",
  scopes: [:api],
  expires_at: 365.days.from_now
)
puts token.token
'
```

**2. 创建 Bot 用户**

通过 API：
```bash
ROOT_TOKEN="glpat-你的root-token"
GITLAB_URL="http://localhost:8080"

curl --request POST \
  --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "username": "ai-reviewer",
    "name": "AI Code Reviewer",
    "email": "ai-reviewer@gitlab.local",
    "password": "随机密码",
    "skip_confirmation": true
  }' \
  "${GITLAB_URL}/api/v4/users"
```

或通过 GitLab Admin UI：
1. Admin Area → Users → New user
2. 填写用户名 `ai-reviewer`，邮箱等信息
3. 创建用户

**3. 创建 Bot Token**

```bash
docker exec gitlab gitlab-rails runner '
user = User.find_by_username("ai-reviewer")
token = user.personal_access_tokens.create!(
  name: "review-bot-token",
  scopes: [:api, :read_api, :read_repository, :write_repository],
  expires_at: 365.days.from_now
)
puts token.token
'
```

将生成的 token 写入 `.env` 的 `GITLAB_TOKEN` 字段。

**4. 创建测试项目**

```bash
curl --request POST \
  --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "test-repo",
    "path": "test-repo",
    "initialize_with_readme": true,
    "visibility": "public"
  }' \
  "${GITLAB_URL}/api/v4/projects"
```

或通过 GitLab UI：Projects → New project → Create blank project。

**5. 添加 Bot 为项目成员**

```bash
# 获取 bot 用户 ID
BOT_USER_ID=$(curl -sf --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  "${GITLAB_URL}/api/v4/users?username=ai-reviewer" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")

# 获取项目 ID
PROJECT_ID=$(curl -sf --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  "${GITLAB_URL}/api/v4/projects?search=test-repo" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")

# 添加为 Developer（access_level=30）
curl --request POST \
  --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{\"user_id\": ${BOT_USER_ID}, \"access_level\": 30}" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/members"
```

**6. 配置 Webhook**

通过 GitLab UI：
1. 进入项目 → Settings → Webhooks
2. 填写：
   - **URL**: `http://review-bot:8888/webhook`
   - **Secret Token**: 与 `.env` 中 `GITLAB_WEBHOOK_SECRET` 一致
   - **Trigger**: 仅勾选 `Merge request events`
   - **SSL verification**: 取消勾选
3. 点击 "Add webhook"

或通过 API：
```bash
curl --request POST \
  --header "PRIVATE-TOKEN: ${ROOT_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{
    \"url\": \"http://review-bot:8888/webhook\",
    \"token\": \"你的webhook-secret\",
    \"merge_requests_events\": true,
    \"push_events\": false,
    \"enable_ssl_verification\": false
  }" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/hooks"
```

**7. 启动 Bot 容器**

```bash
# 确保 .env 中 GITLAB_TOKEN 和 LLM_API_KEY 已设置
docker compose up -d --build bot
```

**8. 验证健康检查**

```bash
curl http://localhost:8888/health
# 期望返回: {"status":"ok"}
```

---

## 测试验证

### 脚本方式

```bash
bash scripts/03-test-review.sh
```

脚本会自动：创建分支 → 提交有问题的代码 → 创建 MR → 等待 bot 评论 → 打印结果。

### 手动测试步骤

1. 在 `test-repo` 项目中创建新分支
2. 添加一些包含安全漏洞或逻辑错误的代码
3. 创建 Merge Request（目标分支: main）
4. 等待 30-60 秒，刷新 MR 页面
5. 检查 MR 中是否出现 bot 的行内评论和总结

---

## 运维管理

### 检查服务状态

```bash
bash scripts/check-status.sh
```

### 仅移除 Bot（保留 GitLab 数据）

```bash
bash scripts/teardown-bot.sh
# 重新配置: bash scripts/02-setup-bot.sh
```

### 全量清理（移除所有容器和卷）

```bash
bash scripts/teardown-all.sh
```

### 查看日志

```bash
# Bot 日志
docker compose logs -f bot

# GitLab 日志
docker compose logs -f gitlab
```

---

## 独立部署（已有 GitLab 实例）

如果你的团队已有 GitLab 实例，只需部署 Bot：

```bash
# 1. 编辑 .env 配置
cp .env.example .env
# 设置 GITLAB_URL, GITLAB_TOKEN, LLM_API_KEY 等

# 2. 使用独立部署配置
docker compose -f docker-compose.standalone.yml up -d --build

# 3. 在 GitLab 中配置 Webhook
#    项目 → Settings → Webhooks
#    URL: http://<bot-server>:8888/webhook
#    Secret Token: 与 .env 中 GITLAB_WEBHOOK_SECRET 一致
#    Trigger: Merge request events
```

**注意**：如果 Bot 和 GitLab 在同一内网，需要在 GitLab Admin 中允许本地网络 Webhook：
- Admin Area → Settings → Network → Outbound requests
- 勾选 `Allow requests to the local network from web hooks and services`

---

## 高级：Claude Code 集成提升 Review 质量

Bot 提供自动化的基础代码审查，但对于需要深度理解的复杂代码，可以结合 Claude Code 进一步提升审查质量。

### 工作流程

两者互补使用：
- **Bot（自动）**：每个 MR 自动完成基础审查——安全漏洞、常见 bug、逻辑错误
- **Claude Code（手动）**：开发者在合并前对重要 MR 进行深度审查

### 使用方式

```bash
# 1. 安装 Claude Code
# 参考: https://docs.anthropic.com/en/docs/claude-code

# 2. 在项目目录中启动 Claude Code
cd your-project
claude

# 3. 使用内置命令进行深度审查
/review-pr          # 深度审查当前分支的所有变更
/simplify           # 简化复杂代码
```

### 典型场景

| 场景 | Bot 自动审查 | Claude Code 深度审查 |
|------|-------------|---------------------|
| 常规功能 MR | ✓ 足够 | 可选 |
| 核心模块重构 | ✓ 基础检查 | ✓ 建议使用 |
| 安全敏感代码 | ✓ 基础扫描 | ✓ 强烈建议 |
| 新架构设计 | ✓ 基础检查 | ✓ 强烈建议 |

### 提升 Bot Review 质量（可选）

如需增强 Bot 自身的审查能力：

1. **优化 Prompt**：修改 `bot/prompts.py` 添加更详细的审查规则
2. **分文件审查**：修改 `bot/reviewer.py` 逐文件发送 diff 而非一次性发送
3. **获取完整上下文**：在 prompt 中包含完整文件内容而非仅 diff
4. **添加 Checklist**：在 prompt 中加入项目特定的审查清单

---

## 配置参考表

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GITLAB_PORT` | GitLab 端口 | `8080` |
| `GITLAB_ROOT_PASSWORD` | GitLab root 密码 | `changeme123` |
| `GITLAB_TOKEN` | Bot 的 GitLab API Token（自动生成） | - |
| `GITLAB_WEBHOOK_SECRET` | Webhook 验证密钥 | `webhook-secret-change-me` |
| `BOT_USERNAME` | Bot 用户名 | `ai-reviewer` |
| `BOT_NAME` | Bot 显示名称 | `AI Code Reviewer` |
| `LLM_PROVIDER` | LLM 提供商：`anthropic` 或 `openai_compatible` | `anthropic` |
| `LLM_API_KEY` | LLM API 密钥 | - |
| `LLM_API_BASE` | LLM API 地址 | `https://api.anthropic.com` |
| `LLM_MODEL` | 模型名称 | `claude-sonnet-4-20250514` |
| `LLM_MAX_TOKENS` | 最大输出 token 数 | `4096` |
| `MIN_SEVERITY` | 最低评论级别（critical/high/medium/low/info） | `medium` |
| `MAX_DIFF_CHARS` | Diff 最大字符数 | `30000` |
| `REVIEW_LANGUAGE` | 审查语言：`zh`（中文）或 `en`（英文） | `zh` |
| `BOT_PORT` | Bot 服务端口 | `8888` |

### 内网 LLM 配置示例

**Ollama：**
```bash
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://host.docker.internal:11434/v1
LLM_MODEL=qwen2.5-coder:32b
```

**vLLM：**
```bash
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://<vllm-host>:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct
```

> **注意**: Linux 上 `host.docker.internal` 可能不可用，需替换为宿主机实际 IP，
> 或在 docker-compose.yml 中添加 `extra_hosts: ["host.docker.internal:host-gateway"]`。

---

## 故障排除

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| GitLab 启动很慢 | 首次启动需 3-5 分钟 | 耐心等待，确保至少 4GB 内存 |
| Bot 评论没有出现 | Webhook/LLM 配置问题 | `docker compose logs bot` 查看日志 |
| Webhook 403 | Secret Token 不匹配 | 检查 .env 和 GitLab webhook 配置 |
| Webhook 422 | URL 无效/被拒绝 | 在 GitLab Admin 中启用本地网络 webhook |
| 行内评论变成普通评论 | diff 已过时 | 正常降级行为，不影响使用 |
| Token 超限 | diff 太大 | 减小 `MAX_DIFF_CHARS` |
| 评论延迟长 | LLM 响应慢 | 考虑使用更快的模型或增加资源 |

---

## 项目结构

```
gitlab-code-review/
├── docker-compose.yml              # GitLab + Bot + Runner（按服务启动）
├── docker-compose.dev.yml          # 开发模式（热重载）
├── docker-compose.standalone.yml   # 独立部署（仅 Bot）
├── .env.example                    # 环境变量模板
├── scripts/
│   ├── 01-install-gitlab.sh        # Phase 1: 安装 GitLab
│   ├── 02-setup-bot.sh            # Phase 2: 配置 AI 审查
│   ├── 03-test-review.sh          # 端到端测试
│   ├── teardown-bot.sh            # 移除 Bot（保留 GitLab）
│   ├── teardown-all.sh            # 全量清理
│   ├── check-status.sh            # 检查服务状态
│   ├── wait-for-gitlab.sh         # 等待 GitLab 就绪
│   └── register-runner.sh         # 注册 Runner（可选）
├── bot/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                      # FastAPI Webhook 入口
│   ├── config.py                   # 配置管理
│   ├── models.py                   # 数据模型
│   ├── gitlab_client.py           # GitLab API 客户端
│   ├── llm_client.py              # LLM 客户端（Anthropic/OpenAI）
│   ├── reviewer.py                # 审查编排
│   └── prompts.py                 # Prompt 模板
├── sample-project/                 # 测试用示例项目
├── README.md                       # 本文档
└── IMPLEMENTATION_SPEC.md          # 详细实现规格（技术参考）
```

---

## License

MIT
