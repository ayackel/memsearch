#!/usr/bin/env python3
"""Extract concise memory facts from the last Copilot CLI turn."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

MAX_USER_CHARS = 1000
MAX_ASSISTANT_CHARS = 3000
INTERNAL_PROMPT_PREFIXES = (
    "[SYSTEM INSTRUCTIONS",
    "You are the Brain Trust panel selector",
    "You are a third-person note-taker",
)


def parse_row(line: str) -> dict[str, Any] | None:
    try:
        value = json.loads(line)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def compact(value: str, limit: int) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    if len(value) <= limit:
        return value
    return value[: limit - 14].rstrip() + "...(truncated)"


def is_internal_prompt(value: str) -> bool:
    value = value.lstrip()
    if value.startswith(INTERNAL_PROMPT_PREFIXES):
        return True
    return re.match(r"You are [A-Z][A-Z0-9_-]+,", value) is not None


def extract(path: Path) -> str:
    rows = [
        row
        for line in path.read_text(encoding="utf-8").splitlines()
        if (row := parse_row(line)) is not None
    ]

    start = None
    for index in range(len(rows) - 1, -1, -1):
        row = rows[index]
        content = row.get("data", {}).get("content", "")
        if row.get("type") == "user.message" and isinstance(content, str) and content.strip():
            start = index
            break
    if start is None:
        return ""

    user_content = rows[start].get("data", {}).get("content", "")
    if is_internal_prompt(user_content):
        return ""
    assistant_content = ""
    for row in rows[start + 1 :]:
        if row.get("type") == "user.message":
            break
        if row.get("type") != "assistant.message":
            continue
        content = row.get("data", {}).get("content", "")
        if isinstance(content, str) and content.strip():
            assistant_content = content

    bullets = [f"- User asked: {compact(user_content, MAX_USER_CHARS)}"]
    if assistant_content:
        bullets.append(f"- Copilot answered: {compact(assistant_content, MAX_ASSISTANT_CHARS)}")
    return "\n".join(bullets)


def main() -> int:
    if len(sys.argv) != 2:
        sys.stderr.write("usage: extract-memory.py <events.jsonl>\n")
        return 2
    path = Path(sys.argv[1])
    if not path.is_file():
        sys.stderr.write(f"transcript not found: {path}\n")
        return 2
    output = extract(path)
    if output:
        sys.stdout.write(output + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
