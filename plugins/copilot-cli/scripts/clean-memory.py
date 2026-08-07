#!/usr/bin/env python3
"""Remove known Copilot memory corruption patterns with backup files."""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

SESSION_RE = re.compile(r"(?m)^## Session [^\n]*\n")
ENTRY_RE = re.compile(r"(?m)^### \d{2}:\d{2}[^\n]*\n")
ROLE_MARKER_RE = re.compile(
    r"(?m)^\[(Human|Copilot CLI|Copilot CLI calls tool|Tool output|Tool error)\](?: \([^)]*\))?:[^\n]*"
)
RAW_MARKERS = (
    "=== Transcript of a conversation",
    "[Human]:",
    "[Copilot CLI calls tool]:",
    "[Tool output]",
    "[Tool error]",
    "Operation cancelled by user",
)
INTERNAL_ENTRY_RE = re.compile(
    r"(?m)^- User asked: (?:\[SYSTEM INSTRUCTIONS|You are the Brain Trust panel selector|"
    r"You are a third-person note-taker|You are [A-Z][A-Z0-9_-]+,)"
)


def clean_text(text: str) -> str:
    text = remove_raw_entries(text)
    matches = list(SESSION_RE.finditer(text))
    if not matches:
        return text

    prefix = text[: matches[0].start()].rstrip()
    kept: list[str] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        section = text[match.start() : end].strip()
        body = text[match.end() : end].strip()
        body_without_comments = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL).strip()
        if not body_without_comments:
            continue
        if INTERNAL_ENTRY_RE.search(body_without_comments):
            continue
        if any(marker in body_without_comments for marker in RAW_MARKERS):
            converted = convert_raw_body(body)
            if not converted:
                continue
            kept.append(f"{match.group(0).strip()}\n{converted}")
            continue
        kept.append(section)

    parts = [part for part in [prefix, "\n\n".join(kept)] if part]
    return "\n\n".join(parts).rstrip() + ("\n" if parts else "")


def remove_raw_entries(text: str) -> str:
    matches = list(ENTRY_RE.finditer(text))
    if not matches:
        return text

    prefix = text[: matches[0].start()].rstrip()
    kept: list[str] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        section = text[match.start() : end].strip()
        body = text[match.end() : end].strip()
        if any(marker in body for marker in RAW_MARKERS):
            converted = convert_raw_body(body)
            if converted:
                kept.append(f"{match.group(0).strip()}\n{converted}")
            continue
        kept.append(section)

    parts = [part for part in [prefix, "\n\n".join(kept)] if part]
    return "\n\n".join(parts).rstrip() + ("\n" if parts else "")


def compact(value: str, limit: int) -> str:
    value = re.sub(r"\s+", " ", value).strip()
    if len(value) <= limit:
        return value
    return value[: limit - 14].rstrip() + "...(truncated)"


def convert_raw_body(body: str) -> str:
    anchors = re.findall(r"<!--.*?-->", body, flags=re.DOTALL)
    matches = list(ROLE_MARKER_RE.finditer(body))
    human = ""
    assistant = ""
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        label = match.group(1)
        marker_text = match.group(0)
        content = marker_text.split(":", 1)[1] + body[match.end() : end]
        if label == "Human" and content.strip():
            human = content
        elif label == "Copilot CLI" and content.strip():
            assistant = content

    bullets: list[str] = []
    if human:
        compact_human = compact(human, 1000)
        if INTERNAL_ENTRY_RE.match(f"- User asked: {compact_human}"):
            return ""
        bullets.append(f"- User asked: {compact_human}")
    if assistant:
        bullets.append(f"- Copilot answered: {compact(assistant, 3000)}")
    if not bullets:
        return ""
    return "\n".join([*anchors, *bullets])


def clean_file(path: Path, *, dry_run: bool, from_backups: bool) -> bool:
    backup = path.with_suffix(path.suffix + ".bak")
    source = backup if from_backups and backup.is_file() else path
    original = source.read_text(encoding="utf-8")
    cleaned = clean_text(original)
    current = path.read_text(encoding="utf-8")
    if cleaned == current:
        return False
    if not dry_run:
        if not backup.exists():
            shutil.copy2(path, backup)
        path.write_text(cleaned, encoding="utf-8")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("directories", nargs="+", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--from-backups", action="store_true")
    args = parser.parse_args()

    changed = 0
    for directory in args.directories:
        for path in sorted(directory.glob("*.md")):
            if clean_file(path, dry_run=args.dry_run, from_backups=args.from_backups):
                changed += 1
                sys.stdout.write(f"{path}\n")
    action = "Would clean" if args.dry_run else "Cleaned"
    sys.stdout.write(f"{action} {changed} files\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
