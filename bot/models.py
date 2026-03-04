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
