"""Prompt templates for code review — loaded from external Markdown files."""

import os
from functools import lru_cache
from pathlib import Path

import yaml

PROMPTS_DIR = Path(__file__).parent / "prompts"


def _parse_md_file(path: Path) -> tuple[dict, str]:
    """Parse a Markdown file with optional YAML front matter.

    Returns (front_matter_dict, body_text).
    """
    text = path.read_text(encoding="utf-8")
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            front_matter = yaml.safe_load(parts[1]) or {}
            body = parts[2].strip()
            return front_matter, body
    return {}, text.strip()


def _render_template(template: str, variables: dict) -> str:
    """Replace {{variable}} placeholders in a template string."""
    result = template
    for key, value in variables.items():
        result = result.replace("{{" + key + "}}", value if value is not None else "")
    return result


def _build_supplement_registry() -> dict[str, dict[str, Path]]:
    """Scan supplements/ directory and build {ext: {lang: path}} mapping."""
    registry: dict[str, dict[str, Path]] = {}
    supplements_dir = PROMPTS_DIR / "supplements"
    if not supplements_dir.exists():
        return registry

    for md_file in supplements_dir.glob("*.md"):
        front_matter, _ = _parse_md_file(md_file)
        extensions = front_matter.get("extensions", [])
        lang = front_matter.get("language", "")
        if not extensions or not lang:
            continue
        for ext in extensions:
            if ext not in registry:
                registry[ext] = {}
            registry[ext][lang] = md_file

    return registry


# Build registry at module load time
_supplement_registry = _build_supplement_registry()


@lru_cache(maxsize=32)
def _load_md_body(path_str: str) -> str:
    """Load and cache the body of a markdown file (excludes front matter)."""
    _, body = _parse_md_file(Path(path_str))
    return body


def get_system_prompt(language: str) -> str:
    """Get system prompt for the specified language."""
    lang = language if language in ("zh", "en") else "zh"
    path = PROMPTS_DIR / "system" / f"{lang}.md"
    return _load_md_body(str(path))


def get_file_type_supplement(file_extensions: set[str], language: str) -> str:
    """Return language-specific review supplement based on file extensions.

    Supports multiple supplements if different file types are present.
    """
    lang = language if language in ("zh", "en") else "zh"
    seen_paths: set[str] = set()
    supplements: list[str] = []

    for ext in file_extensions:
        lang_map = _supplement_registry.get(ext)
        if not lang_map:
            continue
        path = lang_map.get(lang) or lang_map.get("zh")
        if path and str(path) not in seen_paths:
            seen_paths.add(str(path))
            supplements.append(_load_md_body(str(path)))

    return "\n\n".join(supplements)


def build_user_prompt(
    diffs: list[dict],
    mr_title: str,
    mr_description: str | None,
    max_chars: int,
    language: str = "zh",
) -> str:
    """Build the user prompt with diff content, truncating if needed."""
    # Build diff text
    diff_parts: list[str] = []
    total_chars = 0

    for diff_info in diffs:
        header = f"\n--- {diff_info['old_path']} -> {diff_info['new_path']} ---\n"
        content = diff_info["diff"]
        section = header + content

        if total_chars + len(section) > max_chars:
            remaining = max_chars - total_chars
            if remaining > 100:
                diff_parts.append(section[:remaining])
                diff_parts.append("\n\n[TRUNCATED: diff too large]")
            break

        diff_parts.append(section)
        total_chars += len(section)

    diffs_text = "".join(diff_parts)

    # Load and render user template
    lang = language if language in ("zh", "en") else "zh"
    path = PROMPTS_DIR / "user" / f"{lang}.md"
    template = _load_md_body(str(path))

    return _render_template(template, {
        "mr_title": mr_title,
        "mr_description": mr_description or "",
        "diffs": diffs_text,
    })
