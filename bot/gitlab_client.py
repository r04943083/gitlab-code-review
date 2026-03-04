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
                    "Inline comment failed (400) for %s:%d, falling back to MR note: %s",
                    comment.file_path,
                    comment.line,
                    exc.response.text,
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
