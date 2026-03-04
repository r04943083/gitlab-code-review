# GitLab AI Code Review Bot - Implementation Specification

This document contains the complete implementation details for every file in the project. It is designed to be used as a reference for other AI systems or developers to reproduce the project.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Data Flow](#data-flow)
3. [Project Structure](#project-structure)
4. [Infrastructure Files](#infrastructure-files)
5. [Bot Application](#bot-application)
6. [Shell Scripts](#shell-scripts)
7. [Sample Project](#sample-project)
8. [Deployment Guide](#deployment-guide)
9. [Key Implementation Details](#key-implementation-details)

---

## Architecture Overview

The bot uses a **Webhook Server** architecture (not CI Pipeline):

```
┌─────────────────── Docker Network: gl-net ───────────────────┐
│  GitLab CE (:8080)  ←webhook→  Review Bot (:8888)            │
│  GitLab Runner (docker executor)                              │
└───────────────────────────────────────────────────────────────┘
                          │ LLM API
                    Local LLM / Anthropic API
```

**Why Webhook Server over CI Pipeline:**
- CI Pipeline requires Runner to access LLM API; complex in air-gapped networks
- Webhook Server lives on the same Docker network as GitLab, directly calling local LLM
- More flexible: supports @mention triggers, incremental review
- Independent process, easier to maintain and debug

---

## Data Flow

```
Developer pushes code → GitLab MR created/updated
  → GitLab webhook POST → review-bot:8888/webhook
  → Bot returns HTTP 200 (immediate response)
  → Background task:
      1. Validate X-Gitlab-Token header
      2. GET /api/v4/.../merge_requests/:iid (fetch diff_refs SHAs)
      3. GET /api/v4/.../merge_requests/:iid/diffs (fetch file changes)
      4. Build prompt + call LLM API → JSON structured output
      5. Parse inline_comments array
      6. POST each as Discussion (inline comment with position info)
      7. POST summary Note
```

---

## Project Structure

```
code-review/
├── docker-compose.yml          # GitLab CE + Runner + Review Bot
├── docker-compose.dev.yml      # Dev mode override (hot reload)
├── .env.example                # Environment variable template
├── .gitignore
├── scripts/
│   ├── setup.sh                # One-click start
│   ├── wait-for-gitlab.sh      # Poll GitLab health
│   ├── init-gitlab.sh          # Initialize GitLab (token/project/webhook)
│   ├── register-runner.sh      # Register GitLab Runner
│   ├── test-review.sh          # End-to-end test
│   └── teardown.sh             # Cleanup
├── bot/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py                  # FastAPI webhook entry point
│   ├── config.py               # pydantic-settings configuration
│   ├── models.py               # Pydantic data models
│   ├── gitlab_client.py        # GitLab API async client
│   ├── llm_client.py           # Multi-provider LLM client
│   ├── reviewer.py             # Core review orchestration
│   └── prompts.py              # Review prompt templates
├── sample-project/
│   ├── .gitlab-ci.yml
│   └── src/bad_example.py
├── README.md
└── IMPLEMENTATION_SPEC.md
```

---

## Infrastructure Files

### `.env.example`

All environment variables with sensible defaults:

```bash
# GitLab Configuration
GITLAB_PORT=8080
GITLAB_ROOT_PASSWORD=changeme123
GITLAB_EXTERNAL_URL=http://localhost:8080

# Filled automatically by init-gitlab.sh
GITLAB_TOKEN=

# Webhook secret for validating incoming requests
GITLAB_WEBHOOK_SECRET=webhook-secret-change-me

# LLM Configuration
# Provider: "anthropic" or "openai_compatible"
LLM_PROVIDER=anthropic
LLM_API_KEY=
LLM_API_BASE=https://api.anthropic.com
LLM_MODEL=claude-sonnet-4-20250514
LLM_MAX_TOKENS=4096

# Review Settings
# Minimum severity to post: critical, high, medium, low, info
MIN_SEVERITY=medium
MAX_DIFF_CHARS=30000

# Bot Configuration
BOT_PORT=8888
```

### `docker-compose.yml`

Three services on a shared `gl-net` bridge network:

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:16.11.10-ce.0
    container_name: gitlab
    hostname: gitlab
    ports:
      - "${GITLAB_PORT:-8080}:8080"
    shm_size: "256m"
    environment:
      GITLAB_ROOT_PASSWORD: "${GITLAB_ROOT_PASSWORD:-changeme123}"
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab:8080'
        nginx['listen_port'] = 8080
        nginx['listen_https'] = false
        puma['worker_processes'] = 2
        sidekiq['concurrency'] = 5
        prometheus_monitoring['enable'] = false
        grafana['enable'] = false
        gitlab_exporter['enable'] = false
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/-/health"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
    networks:
      - gl-net

  runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    depends_on:
      gitlab:
        condition: service_healthy
    volumes:
      - runner-config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - gl-net

  bot:
    build: ./bot
    container_name: review-bot
    ports:
      - "${BOT_PORT:-8888}:8888"
    depends_on:
      gitlab:
        condition: service_healthy
    environment:
      - GITLAB_INTERNAL_URL=http://gitlab:8080
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
    networks:
      - gl-net

networks:
  gl-net:
    driver: bridge

volumes:
  gitlab-config:
  gitlab-logs:
  gitlab-data:
  runner-config:
```

**Key design decisions:**
- GitLab CE pinned to `16.11.10-ce.0` for stability
- Memory optimization: puma workers=2, sidekiq concurrency=5, monitoring disabled
- `shm_size: 256m` prevents GitLab shared memory issues
- Bot uses `GITLAB_INTERNAL_URL=http://gitlab:8080` (Docker internal DNS)
- Runner mounts Docker socket for docker-in-docker executor
- Health check with 180s start_period gives GitLab time to boot

### `docker-compose.dev.yml`

```yaml
services:
  bot:
    volumes:
      - ./bot:/app
    command: ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8888", "--reload"]
```

Usage: `docker compose -f docker-compose.yml -f docker-compose.dev.yml up`

### `.gitignore`

```
.env
__pycache__/
.venv/
*.pyc
.idea/
.vscode/
gitlab-data/
runner-config/
```

---

## Bot Application

### `bot/requirements.txt`

```
fastapi
uvicorn[standard]
httpx
pydantic
pydantic-settings
anthropic
openai
python-json-logger
```

### `bot/Dockerfile`

```dockerfile
FROM python:3.12-slim

RUN groupadd --gid 1000 appuser && \
    useradd --uid 1000 --gid 1000 --create-home appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

USER appuser

EXPOSE 8888

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8888"]
```

### `bot/models.py`

Three categories of Pydantic models:

```python
"""Pydantic models for the code review bot."""

from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field


# --- Webhook payload models ---

class ProjectInfo(BaseModel):
    id: int
    path_with_namespace: str
    web_url: str


class UserInfo(BaseModel):
    username: str


class ObjectAttributes(BaseModel):
    iid: int
    title: str
    state: str
    action: str
    work_in_progress: bool = False
    draft: bool = False
    source_branch: str
    target_branch: str
    url: str


class MRWebhookPayload(BaseModel):
    object_kind: str
    event_type: str
    project: ProjectInfo
    object_attributes: ObjectAttributes
    user: UserInfo


# --- GitLab API response models ---

class DiffRefs(BaseModel):
    base_sha: str
    start_sha: str
    head_sha: str


class MRDetail(BaseModel):
    iid: int
    title: str
    description: Optional[str] = None
    diff_refs: DiffRefs


class FileDiff(BaseModel):
    old_path: str
    new_path: str
    diff: str
    new_file: bool
    renamed_file: bool
    deleted_file: bool


# --- Review result models ---

class Severity(str, Enum):
    critical = "critical"
    high = "high"
    medium = "medium"
    low = "low"
    info = "info"


class InlineComment(BaseModel):
    file_path: str
    line: int
    severity: Severity
    category: str
    message: str
    suggestion: Optional[str] = None
    line_type: str = Field(default="new", pattern=r"^(new|old|context)$")


class ReviewResult(BaseModel):
    summary: str
    inline_comments: list[InlineComment] = []
    stats: dict = {}
```

### `bot/config.py`

```python
"""Configuration via environment variables."""

from pydantic_settings import BaseSettings

from models import Severity


SEVERITY_ORDER = {
    Severity.info: 0,
    Severity.low: 1,
    Severity.medium: 2,
    Severity.high: 3,
    Severity.critical: 4,
}


class Settings(BaseSettings):
    # GitLab
    GITLAB_INTERNAL_URL: str = "http://gitlab:8080"
    GITLAB_TOKEN: str = ""
    GITLAB_WEBHOOK_SECRET: str = ""

    # LLM provider: "anthropic" or "openai_compatible"
    LLM_PROVIDER: str = "anthropic"
    LLM_MODEL: str = "claude-sonnet-4-20250514"
    LLM_API_KEY: str = ""
    LLM_API_BASE: str = "https://api.anthropic.com"
    LLM_MAX_TOKENS: int = 4096

    # Review settings
    MIN_SEVERITY: Severity = Severity.medium
    MAX_DIFF_CHARS: int = 30000
    MAX_FILE_SIZE: int = 100000

    # App
    LOG_LEVEL: str = "INFO"
    BOT_PORT: int = 8888

    model_config = {"env_file": ".env", "extra": "ignore"}

    def should_post_comment(self, severity: Severity) -> bool:
        return SEVERITY_ORDER[severity] >= SEVERITY_ORDER[self.MIN_SEVERITY]
```

### `bot/prompts.py`

```python
"""Prompt templates for code review."""

SYSTEM_PROMPT = """You are a senior software engineer performing a code review on a merge request.

Analyze the provided diffs and produce a JSON response with the following schema:

{
  "summary": "Brief overall assessment of the merge request",
  "inline_comments": [
    {
      "file_path": "path/to/file",
      "line": <line_number_in_new_file>,
      "severity": "critical|high|medium|low|info",
      "category": "bug|security|performance|style|maintainability|logic|error-handling",
      "message": "Description of the issue",
      "suggestion": "Optional: suggested fix or improved code",
      "line_type": "new|old|context"
    }
  ],
  "stats": {
    "files_reviewed": <int>,
    "total_issues": <int>,
    "by_severity": {"critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0}
  }
}

Review rules:
- Focus on bugs, security issues, logic errors, and significant problems
- Do NOT comment on trivial style issues or formatting
- line_type should be "new" for added lines (+), "old" for deleted lines (-), "context" for unchanged lines
- The line number must reference the actual line in the diff
- Be concise and actionable in your messages
- If there are no issues, return an empty inline_comments array
- Return ONLY valid JSON, no other text"""


def build_user_prompt(
    diffs: list[dict], mr_title: str, mr_description: str | None, max_chars: int
) -> str:
    """Build the user prompt with diff content, truncating if needed."""
    parts = [
        f"## Merge Request: {mr_title}",
    ]
    if mr_description:
        parts.append(f"\n### Description:\n{mr_description}")

    parts.append("\n### Diffs:\n")

    total_chars = sum(len(p) for p in parts)

    for diff_info in diffs:
        header = f"\n--- {diff_info['old_path']} -> {diff_info['new_path']} ---\n"
        content = diff_info["diff"]
        section = header + content

        if total_chars + len(section) > max_chars:
            remaining = max_chars - total_chars
            if remaining > 100:
                parts.append(section[:remaining])
                parts.append("\n\n[TRUNCATED: diff too large]")
            break

        parts.append(section)
        total_chars += len(section)

    return "".join(parts)
```

### `bot/llm_client.py`

```python
"""LLM client supporting Anthropic and OpenAI-compatible APIs."""

import json
import logging
import re

import anthropic
import openai

from config import Settings
from prompts import SYSTEM_PROMPT

logger = logging.getLogger(__name__)


class LLMClient:
    def __init__(self, config: Settings):
        self.config = config

    async def review(self, user_prompt: str) -> dict:
        """Send the review prompt to the configured LLM and return parsed JSON."""
        if self.config.LLM_PROVIDER == "anthropic":
            raw = await self._call_anthropic(user_prompt)
        else:
            raw = await self._call_openai_compatible(user_prompt)

        return self.parse_json_response(raw)

    async def _call_anthropic(self, user_prompt: str) -> str:
        client = anthropic.AsyncAnthropic(api_key=self.config.LLM_API_KEY)
        try:
            message = await client.messages.create(
                model=self.config.LLM_MODEL,
                max_tokens=self.config.LLM_MAX_TOKENS,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_prompt}],
            )
            return message.content[0].text
        finally:
            await client.close()

    async def _call_openai_compatible(self, user_prompt: str) -> str:
        client = openai.AsyncOpenAI(
            api_key=self.config.LLM_API_KEY or "no-key",
            base_url=self.config.LLM_API_BASE,
        )
        try:
            response = await client.chat.completions.create(
                model=self.config.LLM_MODEL,
                messages=[
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                max_tokens=self.config.LLM_MAX_TOKENS,
            )
            return response.choices[0].message.content
        finally:
            await client.close()

    @staticmethod
    def parse_json_response(text: str) -> dict:
        """Parse JSON from LLM response, handling various formats."""
        text = text.strip()

        # Try bare JSON first
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass

        # Try ```json code blocks
        match = re.search(r"```(?:json)?\s*\n?(.*?)\n?\s*```", text, re.DOTALL)
        if match:
            try:
                return json.loads(match.group(1).strip())
            except json.JSONDecodeError:
                pass

        # Try to find embedded JSON object
        start = text.find("{")
        end = text.rfind("}")
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(text[start : end + 1])
            except json.JSONDecodeError:
                pass

        logger.error("Failed to parse JSON from LLM response: %s", text[:200])
        raise ValueError(f"Could not parse JSON from LLM response: {text[:200]}")
```

### `bot/gitlab_client.py`

```python
"""Async GitLab API client using httpx."""

import logging

import httpx

from config import Settings
from models import DiffRefs, FileDiff, InlineComment, MRDetail

logger = logging.getLogger(__name__)


class GitLabClient:
    def __init__(self, config: Settings, http_client: httpx.AsyncClient | None = None):
        self.config = config
        self._client = http_client

    @property
    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            raise RuntimeError("HTTP client not initialized. Call start() first.")
        return self._client

    async def start(self) -> None:
        if self._client is None:
            self._client = httpx.AsyncClient(
                base_url=f"{self.config.GITLAB_INTERNAL_URL}/api/v4",
                headers={"PRIVATE-TOKEN": self.config.GITLAB_TOKEN},
                timeout=30.0,
            )

    async def close(self) -> None:
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def get_mr_detail(self, project_id: int, mr_iid: int) -> MRDetail:
        """Fetch MR details including diff_refs."""
        resp = await self.client.get(
            f"/projects/{project_id}/merge_requests/{mr_iid}"
        )
        resp.raise_for_status()
        data = resp.json()
        return MRDetail(
            iid=data["iid"],
            title=data["title"],
            description=data.get("description"),
            diff_refs=DiffRefs(**data["diff_refs"]),
        )

    async def get_mr_diffs(self, project_id: int, mr_iid: int) -> list[FileDiff]:
        """Fetch the list of file diffs for a merge request."""
        resp = await self.client.get(
            f"/projects/{project_id}/merge_requests/{mr_iid}/diffs"
        )
        resp.raise_for_status()
        return [FileDiff(**d) for d in resp.json()]

    async def post_inline_discussion(
        self,
        project_id: int,
        mr_iid: int,
        comment: InlineComment,
        diff_refs: DiffRefs,
    ) -> None:
        """Create an inline discussion on the MR. Falls back to a plain note on error."""
        position: dict = {
            "position_type": "text",
            "base_sha": diff_refs.base_sha,
            "start_sha": diff_refs.start_sha,
            "head_sha": diff_refs.head_sha,
            "new_path": comment.file_path,
            "old_path": comment.file_path,
        }

        # Set line fields based on line_type
        if comment.line_type == "old":
            position["old_line"] = comment.line
        elif comment.line_type == "new":
            position["new_line"] = comment.line
        else:
            # context line: set both
            position["old_line"] = comment.line
            position["new_line"] = comment.line

        body = self._format_comment_body(comment)

        try:
            resp = await self.client.post(
                f"/projects/{project_id}/merge_requests/{mr_iid}/discussions",
                json={"body": body, "position": position},
            )
            resp.raise_for_status()
            logger.info(
                "Posted inline comment on %s:%d", comment.file_path, comment.line
            )
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 400:
                logger.warning(
                    "Inline comment failed (400) for %s:%d, falling back to MR note",
                    comment.file_path,
                    comment.line,
                )
                await self.post_mr_note(project_id, mr_iid, body)
            else:
                raise

    async def post_mr_note(self, project_id: int, mr_iid: int, body: str) -> None:
        """Post a simple note (comment) on the MR."""
        resp = await self.client.post(
            f"/projects/{project_id}/merge_requests/{mr_iid}/notes",
            json={"body": body},
        )
        resp.raise_for_status()
        logger.info("Posted MR note on MR !%d", mr_iid)

    @staticmethod
    def _format_comment_body(comment: InlineComment) -> str:
        icon = {
            "critical": "🔴",
            "high": "🟠",
            "medium": "🟡",
            "low": "🔵",
            "info": "ℹ️",
        }.get(comment.severity.value, "")

        parts = [
            f"{icon} **[{comment.severity.value.upper()}]** _{comment.category}_",
            "",
            comment.message,
        ]
        if comment.suggestion:
            parts.extend(["", "```suggestion", comment.suggestion, "```"])
        return "\n".join(parts)
```

**Critical: Inline comment position rules:**

| Comment target | Position fields |
|---------------|-----------------|
| Added line (+) | Only `new_line` |
| Deleted line (-) | Only `old_line` |
| Context line | Both `new_line` + `old_line` |

SHAs must come from the API (`mr_detail.diff_refs`), not the webhook payload (may be stale).

### `bot/reviewer.py`

```python
"""Review orchestrator that ties together GitLab, LLM, and posting results."""

import logging

from config import Settings
from gitlab_client import GitLabClient
from llm_client import LLMClient
from models import InlineComment, ReviewResult
from prompts import build_user_prompt

logger = logging.getLogger(__name__)

SKIP_EXTENSIONS = {
    ".lock", ".min.js", ".min.css", ".map", ".woff", ".woff2",
    ".ttf", ".eot", ".ico", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf",
}
SKIP_FILENAMES = {
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    "poetry.lock", "Cargo.lock", "go.sum", "composer.lock",
}


class ReviewOrchestrator:
    def __init__(self, config: Settings, gitlab: GitLabClient, llm: LLMClient):
        self.config = config
        self.gitlab = gitlab
        self.llm = llm

    async def review_mr(
        self,
        project_id: int,
        mr_iid: int,
        mr_title: str,
        mr_description: str | None,
    ) -> None:
        """Orchestrate a full MR review."""
        logger.info("Starting review for MR !%d in project %d", mr_iid, project_id)

        try:
            # 1. Get MR detail for diff_refs
            mr_detail = await self.gitlab.get_mr_detail(project_id, mr_iid)

            # 2. Get file diffs
            diffs = await self.gitlab.get_mr_diffs(project_id, mr_iid)

            # 3. Filter files
            filtered = [d for d in diffs if self._should_review(d)]
            if not filtered:
                await self.gitlab.post_mr_note(
                    project_id, mr_iid, "No reviewable files found in this MR."
                )
                return

            # 4. Build prompt
            diff_dicts = [
                {"old_path": d.old_path, "new_path": d.new_path, "diff": d.diff}
                for d in filtered
            ]
            user_prompt = build_user_prompt(
                diff_dicts, mr_title, mr_description, self.config.MAX_DIFF_CHARS
            )

            # 5. Call LLM
            result_data = await self.llm.review(user_prompt)

            # 6. Parse response
            result = ReviewResult(**result_data)

            # 7. Post inline comments (filtered by severity)
            posted = 0
            for comment in result.inline_comments:
                if self.config.should_post_comment(comment.severity):
                    await self.gitlab.post_inline_discussion(
                        project_id, mr_iid, comment, mr_detail.diff_refs
                    )
                    posted += 1

            # 8. Post summary note
            summary = self._build_summary(result, posted)
            await self.gitlab.post_mr_note(project_id, mr_iid, summary)

        except Exception:
            logger.exception("Error reviewing MR !%d", mr_iid)
            try:
                await self.gitlab.post_mr_note(
                    project_id, mr_iid,
                    "⚠️ Code review bot encountered an error. Check bot logs.",
                )
            except Exception:
                logger.exception("Failed to post error note on MR !%d", mr_iid)

    def _should_review(self, diff) -> bool:
        if diff.deleted_file:
            return False
        path = diff.new_path.lower()
        filename = path.rsplit("/", 1)[-1]
        if filename in SKIP_FILENAMES:
            return False
        for ext in SKIP_EXTENSIONS:
            if path.endswith(ext):
                return False
        if len(diff.diff) > self.config.MAX_FILE_SIZE:
            return False
        return True

    @staticmethod
    def _build_summary(result: ReviewResult, posted: int) -> str:
        parts = ["## 🤖 Code Review Summary", "", result.summary, ""]
        if result.stats:
            stats = result.stats
            parts.append(f"**Files reviewed:** {stats.get('files_reviewed', 'N/A')}")
            parts.append(f"**Issues found:** {stats.get('total_issues', 0)}")
            by_sev = stats.get("by_severity", {})
            if by_sev:
                sev_parts = [f"{k}: {v}" for k, v in by_sev.items() if v]
                if sev_parts:
                    parts.append(f"**By severity:** {', '.join(sev_parts)}")
        parts.append(f"**Comments posted:** {posted}")
        return "\n".join(parts)
```

### `bot/app.py`

```python
"""FastAPI application for the code review bot webhook."""

import logging
from contextlib import asynccontextmanager

from fastapi import BackgroundTasks, FastAPI, Header, HTTPException, Request

from config import Settings
from gitlab_client import GitLabClient
from llm_client import LLMClient
from models import MRWebhookPayload
from reviewer import ReviewOrchestrator

logger = logging.getLogger(__name__)

config = Settings()
gitlab = GitLabClient(config)
llm = LLMClient(config)
reviewer = ReviewOrchestrator(config, gitlab, llm)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup/shutdown lifecycle."""
    logging.basicConfig(level=config.LOG_LEVEL)
    await gitlab.start()
    logger.info("Bot started, listening for webhooks")
    yield
    await gitlab.close()
    logger.info("Bot shut down")


app = FastAPI(title="Code Review Bot", lifespan=lifespan)


@app.post("/webhook")
async def webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_gitlab_token: str = Header(None),
):
    """Handle GitLab webhook events."""
    # Validate webhook secret
    if config.GITLAB_WEBHOOK_SECRET:
        if x_gitlab_token != config.GITLAB_WEBHOOK_SECRET:
            raise HTTPException(status_code=403, detail="Invalid webhook token")

    body = await request.json()

    # Only handle merge_request events
    if body.get("object_kind") != "merge_request":
        return {"status": "ignored", "reason": "not a merge_request event"}

    payload = MRWebhookPayload(**body)
    attrs = payload.object_attributes

    # Only handle open/reopen/update actions
    if attrs.action not in ("open", "reopen", "update"):
        return {"status": "ignored", "reason": f"action '{attrs.action}' not handled"}

    # Skip draft/WIP MRs
    if attrs.draft or attrs.work_in_progress:
        return {"status": "ignored", "reason": "MR is draft/WIP"}

    logger.info(
        "Scheduling review for MR !%d (%s) by %s",
        attrs.iid, attrs.title, payload.user.username,
    )

    background_tasks.add_task(
        reviewer.review_mr,
        payload.project.id, attrs.iid, attrs.title, None,
    )

    return {"status": "accepted", "mr_iid": attrs.iid}


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}
```

---

## Shell Scripts

### `scripts/wait-for-gitlab.sh`

Polls GitLab health endpoint until HTTP 200. Default timeout: 300 seconds.

```bash
#!/usr/bin/env bash
set -euo pipefail

GITLAB_URL="${1:-http://localhost:8080}"
TIMEOUT="${2:-300}"

echo "Waiting for GitLab at ${GITLAB_URL} (timeout: ${TIMEOUT}s)..."

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
```

### `scripts/setup.sh`

One-click setup: checks prerequisites, creates .env, builds and starts services.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

echo "=== Code Review Bot Setup ==="

# Check prerequisites
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker is not installed."
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo "ERROR: docker compose is not available."
    exit 1
fi

# Ensure .env exists
if [ ! -f .env ]; then
    cp .env.example .env
    echo ".env created from .env.example. Edit it to set LLM_API_KEY."
fi

# Build and start
docker compose build
docker compose up -d

# Wait for GitLab
"$SCRIPT_DIR/wait-for-gitlab.sh" "http://localhost:${GITLAB_PORT:-8080}" 300

echo ""
echo "=== Setup Complete ==="
echo "Next: bash scripts/init-gitlab.sh"
```

### `scripts/init-gitlab.sh`

**The most critical script.** Creates PAT via rails runner, creates test project, configures webhook.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

set -a; source .env; set +a

GITLAB_URL="http://localhost:${GITLAB_PORT:-8080}"

"$SCRIPT_DIR/wait-for-gitlab.sh" "$GITLAB_URL" 300

# Create PAT (idempotent)
GITLAB_TOKEN=$(docker exec gitlab gitlab-rails runner "
token = PersonalAccessToken.find_by(name: 'review-bot-token', revoked: false)
if token && !token.expired?
  puts token.token
else
  user = User.find_by_username('root')
  token = user.personal_access_tokens.create!(
    name: 'review-bot-token',
    scopes: [:api, :read_api, :read_repository, :write_repository],
    expires_at: 365.days.from_now
  )
  puts token.token
end
" 2>/dev/null)

# Write token to .env
if grep -q "^GITLAB_TOKEN=" .env; then
    sed -i "s|^GITLAB_TOKEN=.*|GITLAB_TOKEN=${GITLAB_TOKEN}|" .env
else
    echo "GITLAB_TOKEN=${GITLAB_TOKEN}" >> .env
fi

# Create test project via API
# Configure webhook: http://review-bot:8888/webhook
# Restart bot to pick up new token
```

### `scripts/test-review.sh`

End-to-end test: creates branch, commits bad code, creates MR, polls for bot comments.

### `scripts/register-runner.sh`

Gets runner registration token via rails runner, registers runner with docker executor.

### `scripts/teardown.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
docker compose down -v --remove-orphans
```

---

## Sample Project

### `sample-project/src/bad_example.py`

Contains intentional security vulnerabilities for testing:
1. Hardcoded credentials (password, API key)
2. SQL injection via string formatting
3. Command injection via `os.system()` and `subprocess.call(shell=True)`
4. Pickle deserialization of untrusted data
5. Insecure random for security tokens
6. Missing input validation on financial operations
7. Bare `except:` catching all exceptions
8. Path traversal vulnerability
9. Logging sensitive data (passwords)

---

## Key Implementation Details

### 1. GitLab Initial Token Creation

The most fragile part. Uses `gitlab-rails runner` inside the container:

```ruby
token = PersonalAccessToken.find_by(name: 'review-bot-token', revoked: false)
if token && !token.expired?
  puts token.token
else
  user = User.find_by_username('root')
  token = user.personal_access_tokens.create!(
    name: 'review-bot-token',
    scopes: [:api, :read_api, :read_repository, :write_repository],
    expires_at: 365.days.from_now
  )
  puts token.token
end
```

### 2. Inline Comment Position Object

The GitLab Discussions API requires a `position` object:

```json
{
  "position_type": "text",
  "base_sha": "...",
  "start_sha": "...",
  "head_sha": "...",
  "new_path": "file.py",
  "old_path": "file.py",
  "new_line": 42
}
```

Rules:
- **Added line (+)**: Only `new_line`
- **Deleted line (-)**: Only `old_line`
- **Context line**: Both `new_line` + `old_line`
- SHAs from API `diff_refs`, not webhook payload

### 3. Error Handling Matrix

| Scenario | Handling |
|----------|----------|
| LLM returns non-JSON | `parse_json_response` tries 3 extraction methods, then posts error note |
| Inline comment position invalid | HTTP 400 → fallback to plain MR note |
| MR diff too large | `build_user_prompt` truncates to MAX_DIFF_CHARS |
| Token invalid | Log error, review aborts |
| Draft MR | Return 200 immediately, no processing |

### 4. Intranet LLM Configuration

```bash
LLM_PROVIDER=openai_compatible
LLM_API_KEY=ollama
LLM_API_BASE=http://host.docker.internal:11434/v1
LLM_MODEL=qwen2.5-coder:32b
```

On Linux, `host.docker.internal` may not resolve. Use host IP or add to docker-compose.yml:
```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

---

## Deployment Guide

### External Network (Development)

```bash
git clone https://github.com/r04943083/gitlab-code-review-bot.git
cd gitlab-code-review-bot
cp .env.example .env
# Edit .env: set LLM_API_KEY
bash scripts/setup.sh
bash scripts/init-gitlab.sh
bash scripts/test-review.sh
```

### Air-Gapped Intranet

1. On external machine: `docker save` all images → transfer via USB
2. On internal machine: `docker load` images
3. Configure `.env` with local LLM endpoint
4. Run the same scripts

### Verification Checklist

1. `docker compose config` validates without errors
2. All 3 services are healthy: `docker compose ps`
3. `init-gitlab.sh` creates token + project + webhook
4. `test-review.sh` shows bot comment within 120s
5. `http://localhost:8080` shows inline comments on MR
6. Switch `LLM_PROVIDER` to `openai_compatible`, restart bot, verify still works
