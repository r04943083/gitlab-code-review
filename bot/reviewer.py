"""Review orchestrator that ties together GitLab, LLM, and posting results."""

import logging

from config import Settings
from gitlab_client import GitLabClient
from llm_client import LLMClient
from models import InlineComment, ReviewResult
from prompts import build_user_prompt, get_system_prompt

logger = logging.getLogger(__name__)

# Files to skip during review
SKIP_EXTENSIONS = {".lock", ".min.js", ".min.css", ".map", ".woff", ".woff2", ".ttf", ".eot", ".ico", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf"}
SKIP_FILENAMES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock", "Cargo.lock", "go.sum", "composer.lock"}


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
                logger.info("No reviewable files in MR !%d", mr_iid)
                await self.gitlab.post_mr_note(
                    project_id, mr_iid, "No reviewable files found in this MR."
                )
                return

            logger.info(
                "Reviewing %d/%d files in MR !%d",
                len(filtered),
                len(diffs),
                mr_iid,
            )

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

            logger.info(
                "Review complete for MR !%d: %d comments posted", mr_iid, posted
            )

        except Exception:
            logger.exception("Error reviewing MR !%d in project %d", mr_iid, project_id)
            try:
                await self.gitlab.post_mr_note(
                    project_id,
                    mr_iid,
                    "⚠️ Code review bot encountered an error while reviewing this MR. "
                    "Please check the bot logs for details.",
                )
            except Exception:
                logger.exception("Failed to post error note on MR !%d", mr_iid)

    def _should_review(self, diff) -> bool:
        """Determine if a file should be reviewed."""
        if diff.deleted_file:
            return False

        path = diff.new_path.lower()

        # Skip by filename
        filename = path.rsplit("/", 1)[-1]
        if filename in SKIP_FILENAMES:
            return False

        # Skip by extension
        for ext in SKIP_EXTENSIONS:
            if path.endswith(ext):
                return False

        # Skip large diffs
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
