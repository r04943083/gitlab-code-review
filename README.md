# GitLab AI Code Review Bot

基于 AI 的 GitLab Merge Request 代码审查机器人。当开发者创建或更新 MR 时，Bot 自动分析代码变更并以行内评论的形式提供审查意见。

**特性：**
- 自动审查 MR 代码变更，覆盖安全漏洞、逻辑错误、并发问题、资源泄漏等 13 个审查维度
- 行内评论精确到具体代码行，支持 GitLab Suggestion 一键采纳
- 支持多种 LLM 后端：Anthropic Claude、OpenAI 兼容 API（Ollama、vLLM 等）
- 提示词外部化为 Markdown 文件，非开发人员也能优化审查规则
- 语言感知的审查补充：自动识别 C/C++、Python 文件并追加专项审查规则
- 中英文双语支持，输出语言与配置严格一致
- 适配内网无互联网环境

## 架构

```
开发者推送代码 → GitLab MR 创建/更新
  → GitLab Webhook POST → review-bot:8888/webhook
  → Bot 返回 HTTP 200（立即响应）
  → 后台异步任务：
      1. 获取 MR diff 信息
      2. 构建 prompt（加载 .md 模板 + 语言补充）
      3. 调用 LLM 获取结构化审查结果
      4. 发布行内评论 + 总结
```

```
┌─────────────── Docker Network: gl-net ────────────────┐
│  GitLab CE (:8080)  ←webhook→  Review Bot (:8888)     │
│  GitLab Runner (docker executor, 可选)                 │
└────────────────────────────────────────────────────────┘
                        │ LLM API
                  本地 LLM / 云端 API
```

---

## 快速开始（全新环境）

如果你没有现成的 GitLab 实例，想从零搭建完整环境（GitLab + Bot），按以下步骤操作：

### 前置条件

- Docker 和 Docker Compose v2
- 至少 4GB 可用内存（GitLab CE 需要较多资源）
- LLM API 访问（Anthropic API Key 或本地 LLM 服务）

### 第一步：安装 GitLab

```bash
git clone https://github.com/luyinghe/gitlab-code-review.git
cd gitlab-code-review

# 一键安装 GitLab（幂等，可重复运行）
bash scripts/01-install-gitlab.sh
```

脚本自动完成：检查 Docker → 创建 `.env` → 启动 GitLab → 等待就绪 → 打印访问信息。

首次启动需要 3-5 分钟。完成后浏览器访问 `http://localhost:8080`，使用 `root` / `.env` 中的 `GITLAB_ROOT_PASSWORD`（默认 `changeme123`）登录。

### 第二步：配置 AI 审查

```bash
# 编辑 .env 设置 LLM API Key
vim .env

# 一键配置（幂等，可重复运行）
bash scripts/02-setup-bot.sh
```

脚本自动完成：创建 root token → 创建 bot 用户 → 生成 bot token → 创建测试项目 → 添加 bot 为项目成员 → 启用本地网络 webhook → 配置 webhook → 构建并启动 bot 容器。

### 第三步：测试

```bash
bash scripts/03-test-review.sh
```

脚本自动完成：创建分支 → 提交包含问题的 C/C++ 代码（6 个文件） → 创建 MR → 轮询等待 bot 评论 → 打印审查结果。

---

## 独立部署（已有 GitLab 实例）

**这是大多数内网用户的场景：你的团队已有一套运行中的 GitLab，只需要部署 Bot 并接入。**

### 概述

你需要完成 3 件事：
1. **在 GitLab 中创建 Bot 账号和 Token**
2. **部署 Bot 容器**
3. **在目标项目中配置 Webhook**

完成后，该项目的所有 MR 都会自动触发 AI 审查。

### 方式一：使用脚本半自动部署

如果你的 Bot 服务器能通过命令行访问 GitLab（即 `curl http://your-gitlab/` 可达），可以直接使用脚本：

```bash
git clone https://github.com/luyinghe/gitlab-code-review.git
cd gitlab-code-review

# 1. 创建并编辑配置
cp .env.example .env
```

编辑 `.env`，**必须修改以下字段**：

```bash
# 指向你的 GitLab 实例（不是 localhost）
GITLAB_URL=http://your-gitlab.internal.com
GITLAB_EXTERNAL_URL=http://your-gitlab.internal.com

# LLM 配置（以下三种选一种）

# 方式 A：Anthropic Claude（需要外网或代理）
LLM_PROVIDER=anthropic
LLM_API_KEY=sk-ant-xxxxx
LLM_API_BASE=https://api.anthropic.com

# 方式 B：内网 Ollama
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://your-ollama-host:11434/v1
LLM_MODEL=qwen2.5-coder:32b

# 方式 C：内网 vLLM
LLM_PROVIDER=openai_compatible
LLM_API_KEY=vllm
LLM_API_BASE=http://your-vllm-host:8000/v1
LLM_MODEL=Qwen/Qwen2.5-Coder-32B-Instruct
```

然后启动：

```bash
# 使用独立部署配置（仅启动 Bot，不启动 GitLab）
docker compose -f docker-compose.standalone.yml up -d --build
```

接着在 GitLab 中手动配置 Webhook（见下方步骤 3）。

### 方式二：完全手动部署

适用于无法运行脚本、或需要精确控制每一步的场景。

#### 步骤 1：在 GitLab 中创建 Bot 用户

**通过 GitLab 管理界面：**
1. 以管理员账号登录 GitLab
2. 进入 **Admin Area** → **Users** → **New user**
3. 填写：
   - Username: `ai-reviewer`
   - Name: `AI Code Reviewer`
   - Email: `ai-reviewer@your-company.com`
   - 取消勾选 "User can create top-level groups"
4. 创建后在该用户页面设置密码

**或通过 API（需要管理员 Token）：**
```bash
GITLAB_URL="http://your-gitlab.internal.com"
ADMIN_TOKEN="glpat-your-admin-token"

curl --request POST \
  --header "PRIVATE-TOKEN: ${ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "username": "ai-reviewer",
    "name": "AI Code Reviewer",
    "email": "ai-reviewer@your-company.com",
    "password": "随机强密码",
    "skip_confirmation": true
  }' \
  "${GITLAB_URL}/api/v4/users"
```

#### 步骤 2：为 Bot 用户创建 Access Token

**通过 GitLab 界面：**
1. 以管理员身份进入 **Admin Area** → **Users** → 点击 `ai-reviewer`
2. 点击 **Impersonate**（模拟登录为该用户）
3. 进入 **Preferences** → **Access Tokens**
4. Token name: `review-bot-token`
5. Scopes: 勾选 `api`、`read_api`、`read_repository`、`write_repository`
6. 创建并**复制 Token**（以 `glpat-` 开头，只显示一次）
7. 点击 **Stop impersonation** 退出模拟

**或通过 Rails Console（需要 SSH 访问 GitLab 服务器）：**
```bash
# SSH 到 GitLab 服务器
sudo gitlab-rails runner '
user = User.find_by_username("ai-reviewer")
token = user.personal_access_tokens.create!(
  name: "review-bot-token",
  scopes: [:api, :read_api, :read_repository, :write_repository],
  expires_at: 365.days.from_now
)
puts token.token
'
```

**如果 GitLab 运行在 Docker 中：**
```bash
docker exec <gitlab-container-name> gitlab-rails runner '
user = User.find_by_username("ai-reviewer")
token = user.personal_access_tokens.create!(
  name: "review-bot-token",
  scopes: [:api, :read_api, :read_repository, :write_repository],
  expires_at: 365.days.from_now
)
puts token.token
'
```

#### 步骤 3：将 Bot 添加为项目成员

对每个需要 AI 审查的项目，将 `ai-reviewer` 添加为 **Developer** 角色：

**通过 GitLab 界面：**
1. 进入项目 → **Settings** → **Members**
2. 邀请 `ai-reviewer`，角色选择 **Developer**

**或通过 API：**
```bash
# 获取 bot 用户 ID
BOT_USER_ID=$(curl -sf --header "PRIVATE-TOKEN: ${ADMIN_TOKEN}" \
  "${GITLAB_URL}/api/v4/users?username=ai-reviewer" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")

# 添加到项目（替换 PROJECT_ID 为你的项目 ID）
curl --request POST \
  --header "PRIVATE-TOKEN: ${ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{\"user_id\": ${BOT_USER_ID}, \"access_level\": 30}" \
  "${GITLAB_URL}/api/v4/projects/PROJECT_ID/members"
```

#### 步骤 4：部署 Bot 容器

在一台能同时访问 GitLab 和 LLM API 的服务器上：

```bash
git clone https://github.com/luyinghe/gitlab-code-review.git
cd gitlab-code-review
cp .env.example .env
```

编辑 `.env`：

```bash
# 必填项
GITLAB_URL=http://your-gitlab.internal.com     # GitLab 地址（Bot 服务器能访问到的地址）
GITLAB_TOKEN=glpat-xxxxxx                       # 步骤 2 中复制的 Token
GITLAB_WEBHOOK_SECRET=your-random-secret        # 自定义密钥，步骤 5 配置 Webhook 时要一致

# LLM 配置（按你的环境选择）
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://your-llm-host:11434/v1
LLM_MODEL=qwen2.5-coder:32b

# 审查语言
REVIEW_LANGUAGE=zh
```

启动：

```bash
docker compose -f docker-compose.standalone.yml up -d --build
```

验证：

```bash
curl http://localhost:8888/health
# 期望返回: {"status":"ok"}
```

#### 步骤 5：配置 Webhook

**通过 GitLab 界面（推荐）：**
1. 进入项目 → **Settings** → **Webhooks**
2. 填写：
   - **URL**: `http://<bot-server-ip>:8888/webhook`
   - **Secret Token**: 与 `.env` 中 `GITLAB_WEBHOOK_SECRET` 一致
   - **Trigger**: 仅勾选 **Merge request events**
   - **SSL verification**: 如果不是 HTTPS，取消勾选
3. 点击 **Add webhook**
4. 可以点 **Test** → **Merge request events** 测试连通性

**或通过 API：**
```bash
curl --request POST \
  --header "PRIVATE-TOKEN: ${ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data "{
    \"url\": \"http://<bot-server-ip>:8888/webhook\",
    \"token\": \"your-random-secret\",
    \"merge_requests_events\": true,
    \"push_events\": false,
    \"enable_ssl_verification\": false
  }" \
  "${GITLAB_URL}/api/v4/projects/PROJECT_ID/hooks"
```

#### 步骤 6：启用本地网络 Webhook（重要！）

如果 Bot 和 GitLab 在同一内网，GitLab 默认会阻止向内网地址发送 Webhook。需要管理员启用：

**通过 GitLab 界面：**
1. 以管理员登录 → **Admin Area** → **Settings** → **Network** → **Outbound requests**
2. 勾选 **Allow requests to the local network from web hooks and services**
3. 保存

**或通过 Rails Console：**
```bash
# Docker 方式
docker exec <gitlab-container-name> gitlab-rails runner \
  "ApplicationSetting.first.update!(allow_local_requests_from_web_hooks_and_services: true)"

# 直接 SSH 方式
sudo gitlab-rails runner \
  "ApplicationSetting.first.update!(allow_local_requests_from_web_hooks_and_services: true)"
```

#### 完成！

现在在该项目中创建或更新 MR，等待 30-60 秒（取决于 LLM 响应速度），刷新 MR 页面即可看到 Bot 的行内评论和审查总结。

**如果要为更多项目启用 AI 审查**，只需重复步骤 3（添加 Bot 为成员）和步骤 5（配置 Webhook），无需重复部署。

---

## 提示词架构

Bot 的审查行为完全由 Markdown 提示词文件驱动，无需修改 Python 代码即可调整审查规则。

### 目录结构

```
bot/prompts/
├── system/                  # 系统提示词（定义审查行为和输出格式）
│   ├── zh.md               #   中文版
│   └── en.md               #   英文版
├── supplements/             # 语言专项补充（按文件类型自动追加）
│   ├── cpp_zh.md           #   C/C++ 专项（中文）
│   ├── cpp_en.md           #   C/C++ 专项（英文）
│   ├── python_zh.md        #   Python 专项（中文）
│   └── python_en.md        #   Python 专项（英文）
└── user/                    # 用户提示词模板（MR 信息填充）
    ├── zh.md               #   中文模板
    └── en.md               #   英文模板
```

### 加载流程

```
MR 触发审查
  │
  ├─ 1. 加载 system/{lang}.md          → 系统提示词（审查维度、输出格式）
  ├─ 2. 扫描 MR 中的文件扩展名
  │     ├─ .cpp/.h  → 追加 supplements/cpp_{lang}.md
  │     ├─ .py      → 追加 supplements/python_{lang}.md
  │     └─ 其他     → 不追加补充
  └─ 3. 加载 user/{lang}.md            → 填充 MR 标题、描述、diff
```

### 文件格式

每个 `.md` 文件由两部分组成：

```markdown
---
type: supplement          # 类型：system / supplement / user
language: zh              # 语言：zh / en
extensions: [".py"]       # 仅 supplement 类型需要：匹配的文件扩展名
---

（下方是实际的提示词正文，支持 Markdown 格式）
```

- `system/*.md`：YAML front matter 中的 `type` 和 `language` 仅用于标识，正文是完整的系统提示词
- `supplements/*.md`：`extensions` 字段决定该补充在哪些文件类型出现时被追加
- `user/*.md`：正文中使用 `{{mr_title}}`、`{{mr_description}}`、`{{diffs}}` 占位符

### 当前审查维度（13 项）

系统提示词中定义了以下审查维度，按优先级分层：

| 分类 | 维度 | 说明 |
|------|------|------|
| **核心问题** | 安全漏洞 | 注入、溢出、硬编码密钥 |
| | 逻辑错误 | 条件错误、off-by-one、死循环 |
| | 资源泄漏 | 内存、文件句柄、数据库连接 |
| | 严重性能 | O(n^2) 可优化、循环内 I/O |
| **健壮性** | 错误处理 | 空 catch、吞异常、信息不足 |
| | 边界条件 | 空值、溢出、越界、除零 |
| | 类型安全 | 不安全转换、精度丢失 |
| **并发与架构** | 并发问题 | 数据竞争、死锁、竞态条件 |
| | API 设计 | 破坏性变更、缺少版本控制 |
| **可维护性** | 可测试性 | 硬编码依赖、紧耦合 |
| | 配置硬编码 | 魔法数字、硬编码 URL |
| | 日志完整性 | 关键路径缺日志、敏感信息泄漏 |

---

## 如何优化提示词

### 改进审查规则

直接编辑 `bot/prompts/system/zh.md`（或 `en.md`），修改审查维度的描述或添加新维度。修改后重启 Bot 即可生效：

```bash
docker compose -f docker-compose.standalone.yml restart bot
```

**常见优化方向：**

- **增加行业特定检查**：如金融领域添加"浮点精度"检查，嵌入式领域添加"栈溢出"检查
- **调整审查严格度**：修改"审查原则"部分，控制评论的详略程度
- **添加项目特定规则**：如"本项目禁止使用 `eval()`"、"所有 API 必须有鉴权"

### 添加新语言专项

以 Java 为例，只需创建两个文件（中英文），无需改任何 Python 代码：

**1. 创建 `bot/prompts/supplements/java_zh.md`：**

```markdown
---
type: supplement
language: zh
extensions: [".java"]
---

## Java 专项审查要点

### 并发安全
- 未同步的共享可变状态
- `synchronized` 粒度过大导致性能问题
- `ConcurrentHashMap` 的复合操作非原子

### 资源管理
- 未使用 try-with-resources 管理 `AutoCloseable` 资源
- JDBC 连接/Statement 未正确关闭

（...继续添加你关心的检查项...）
```

**2. 创建 `bot/prompts/supplements/java_en.md`：**（同样结构，英文版本）

**3. 重启 Bot：**

```bash
docker compose -f docker-compose.standalone.yml restart bot
```

现在当 MR 中包含 `.java` 文件时，Bot 会自动追加 Java 专项审查规则。

### 调整用户提示词模板

编辑 `bot/prompts/user/zh.md` 可以改变提交给 LLM 的上下文格式。例如添加额外提示：

```markdown
---
type: user
language: zh
---

## 合并请求：{{mr_title}}

### 描述：
{{mr_description}}

### 特别注意：
本项目使用微服务架构，请特别关注跨服务调用的错误处理。

### 代码变更：
{{diffs}}
```

### 提示词调优技巧

1. **语言约束**：如果输出语言不符合预期，检查 `system/*.md` 首尾的语言约束声明是否完整
2. **输出格式**：不要修改 JSON 输出格式定义，否则会导致解析失败
3. **审查深度**：减少维度可以让 LLM 在重点维度上给出更深入的分析
4. **补充冲突**：多个 supplement 同时匹配时会全部追加，注意总长度不要超过 LLM 上下文限制
5. **测试验证**：修改提示词后，建议提交一个包含已知问题的 MR 来验证效果

---

## 运维管理

### 检查服务状态

```bash
bash scripts/check-status.sh
```

### 查看日志

```bash
# Bot 日志
docker compose logs -f bot
# 或独立部署
docker compose -f docker-compose.standalone.yml logs -f bot
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

---

## 配置参考表

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GITLAB_URL` | GitLab 地址（独立部署时必填） | - |
| `GITLAB_PORT` | GitLab 端口（全量部署时使用） | `8080` |
| `GITLAB_ROOT_PASSWORD` | GitLab root 密码 | `changeme123` |
| `GITLAB_TOKEN` | Bot 的 GitLab API Token | - |
| `GITLAB_WEBHOOK_SECRET` | Webhook 验证密钥 | `webhook-secret-change-me` |
| `BOT_USERNAME` | Bot 用户名 | `ai-reviewer` |
| `BOT_NAME` | Bot 显示名称 | `AI Code Reviewer` |
| `LLM_PROVIDER` | LLM 提供商：`anthropic` / `openai_compatible` | `anthropic` |
| `LLM_API_KEY` | LLM API 密钥 | - |
| `LLM_API_BASE` | LLM API 地址 | `https://api.anthropic.com` |
| `LLM_MODEL` | 模型名称 | `claude-sonnet-4-20250514` |
| `LLM_MAX_TOKENS` | 最大输出 token 数 | `4096` |
| `MIN_SEVERITY` | 最低评论级别（critical/high/medium/low/info） | `medium` |
| `MAX_DIFF_CHARS` | Diff 最大字符数 | `30000` |
| `REVIEW_LANGUAGE` | 审查语言：`zh`（中文）/ `en`（英文） | `zh` |
| `BOT_PORT` | Bot 服务端口 | `8888` |

---

## 故障排除

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| GitLab 启动很慢 | 首次启动需 3-5 分钟 | 耐心等待，确保至少 4GB 内存 |
| Bot 评论没有出现 | Webhook/LLM 配置问题 | 查看 bot 日志排查 |
| Webhook 403 | Secret Token 不匹配 | 检查 `.env` 和 GitLab webhook 配置是否一致 |
| Webhook 422 | URL 无效/被拒绝 | 在 GitLab Admin 中启用本地网络 webhook（见上方步骤 6） |
| 行内评论变成普通评论 | diff 已过时 | 正常降级行为，不影响使用 |
| Token 超限 | diff 太大 | 减小 `MAX_DIFF_CHARS` 或使用更大上下文窗口的模型 |
| 评论延迟长 | LLM 响应慢 | 考虑使用更快的模型或增加资源 |
| 设置中文但输出英文 | 提示词语言约束不足 | 确认 `REVIEW_LANGUAGE=zh` 且使用最新提示词文件 |

---

## 项目结构

```
gitlab-code-review/
├── docker-compose.yml              # 全量部署：GitLab + Bot + Runner
├── docker-compose.dev.yml          # 开发模式（热重载）
├── docker-compose.standalone.yml   # 独立部署：仅 Bot
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
│   ├── prompts.py                 # 提示词加载器（从 .md 文件加载）
│   └── prompts/                   # 提示词 Markdown 文件
│       ├── system/                #   系统提示词（zh.md / en.md）
│       ├── supplements/           #   语言专项补充（cpp/python × zh/en）
│       └── user/                  #   用户提示词模板（zh.md / en.md）
├── sample-project/                 # 测试用示例项目
└── README.md
```

---

## License

MIT
