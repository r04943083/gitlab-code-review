"""FastAPI application for the code review bot webhook."""

import asyncio
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

# Track in-progress reviews to prevent duplicates
_active_reviews: set[str] = set()
_lock = asyncio.Lock()


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


async def _guarded_review(key: str, project_id: int, mr_iid: int, title: str, desc):
    """Run review with deduplication guard."""
    try:
        await reviewer.review_mr(project_id, mr_iid, title, desc)
    finally:
        async with _lock:
            _active_reviews.discard(key)


@app.post("/webhook")
async def webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    x_gitlab_token: str = Header(None),
):
    """Handle GitLab webhook events."""
    if config.GITLAB_WEBHOOK_SECRET:
        if x_gitlab_token != config.GITLAB_WEBHOOK_SECRET:
            raise HTTPException(status_code=403, detail="Invalid webhook token")

    body = await request.json()

    if body.get("object_kind") != "merge_request":
        return {"status": "ignored", "reason": "not a merge_request event"}

    payload = MRWebhookPayload(**body)
    attrs = payload.object_attributes

    if attrs.action not in ("open", "reopen", "update"):
        return {"status": "ignored", "reason": f"action '{attrs.action}' not handled"}

    if attrs.draft or attrs.work_in_progress:
        return {"status": "ignored", "reason": "MR is draft/WIP"}

    # Deduplicate: skip if this MR is already being reviewed
    review_key = f"{payload.project.id}:{attrs.iid}"
    async with _lock:
        if review_key in _active_reviews:
            logger.info("Skipping duplicate review for MR !%d", attrs.iid)
            return {"status": "ignored", "reason": "review already in progress"}
        _active_reviews.add(review_key)

    logger.info(
        "Scheduling review for MR !%d (%s) by %s",
        attrs.iid,
        attrs.title,
        payload.user.username,
    )

    background_tasks.add_task(
        _guarded_review,
        review_key,
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
