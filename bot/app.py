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
        attrs.iid,
        attrs.title,
        payload.user.username,
    )

    background_tasks.add_task(
        reviewer.review_mr,
        payload.project.id,
        attrs.iid,
        attrs.title,
        None,
    )

    return {"status": "accepted", "mr_iid": attrs.iid}


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}
