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
