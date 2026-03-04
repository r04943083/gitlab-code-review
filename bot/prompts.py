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
