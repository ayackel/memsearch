#!/usr/bin/env bash
# Parse a Copilot CLI events.jsonl transcript — extract and format the LAST TURN only.
#
# A "turn" = the last user.message event plus all subsequent events until
# the next user.message or EOF.
#
# Skips: hook.*, session.*, assistant.turn_start/end (non-content lifecycle events).
# Tool results are truncated to MAX_RESULT_CHARS (default 1000).
#
# Usage: bash parse-transcript.sh <events_jsonl_path>

set -euo pipefail

TRANSCRIPT_PATH="${1:-}"

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo "ERROR: transcript not found: $TRANSCRIPT_PATH" >&2
  exit 1
fi

LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -eq 0 ]; then
  echo "(empty transcript)"
  exit 0
fi

MAX_RESULT_CHARS="${MEMSEARCH_MAX_RESULT_CHARS:-1000}"

python3 -c '
import json, sys

MAX_RESULT_CHARS = int(sys.argv[2])

SKIP_TYPES = frozenset([
    "hook.start", "hook.end",
    "session.start", "session.resume", "session.warning", "session.shutdown",
    "assistant.turn_start", "assistant.turn_end",
])


def truncate(text, max_chars):
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "...(truncated)"


def find_last_turn_start(lines):
    """Scan backwards for the last user.message event."""
    for i in range(len(lines) - 1, -1, -1):
        try:
            obj = json.loads(lines[i])
            if obj.get("type") == "user.message":
                content = obj.get("data", {}).get("content", "")
                if isinstance(content, str) and content.strip():
                    return i
        except Exception:
            pass
    return None


def summarize_args(args, max_per_value=120, max_total=400):
    """Summarize tool arguments concisely."""
    if not isinstance(args, dict):
        return str(args)[:max_total]
    parts = []
    for k, v in args.items():
        v_str = str(v)
        if len(v_str) > max_per_value:
            v_str = v_str[:max_per_value] + "..."
        parts.append(f"{k}={v_str}")
    summary = ", ".join(parts)
    if len(summary) > max_total:
        summary = summary[:max_total] + "..."
    return summary


def format_turn(lines):
    """Format a turn into structured text for LLM summarization."""
    output = ["=== Transcript of a conversation between a human and Copilot CLI ==="]

    # Track tool call IDs to their tool names for result attribution
    tool_names = {}

    for raw_line in lines:
        try:
            obj = json.loads(raw_line)
        except Exception:
            continue

        event_type = obj.get("type", "")
        data = obj.get("data", {})

        if event_type in SKIP_TYPES:
            continue

        if event_type == "user.message":
            content = data.get("content", "")
            if isinstance(content, str) and content.strip():
                output.append(f"[Human]: {content.strip()}")

        elif event_type == "assistant.message":
            # Assistant text content
            content = data.get("content", "")
            if isinstance(content, str) and content.strip():
                output.append(f"[Copilot CLI]: {content.strip()}")

            # Inline tool requests (assistant declares tool calls)
            for req in data.get("toolRequests", []):
                call_id = req.get("toolCallId", "")
                name = req.get("name", "unknown")
                args = req.get("arguments", {})
                tool_names[call_id] = name
                output.append(f"[Copilot CLI calls tool]: {name}({summarize_args(args)})")

        elif event_type == "tool.execution_start":
            call_id = data.get("toolCallId", "")
            name = data.get("toolName", "unknown")
            args = data.get("arguments", {})
            tool_names[call_id] = name
            # Only emit if not already emitted via toolRequests
            # (toolRequests appear in assistant.message before execution_start)

        elif event_type == "tool.execution_complete":
            call_id = data.get("toolCallId", "")
            name = tool_names.get(call_id, "tool")
            success = data.get("success", True)
            result = data.get("result", {})
            content = ""
            if isinstance(result, dict):
                content = result.get("content", "") or result.get("detailedContent", "")
            elif isinstance(result, str):
                content = result
            if content:
                content = truncate(str(content), MAX_RESULT_CHARS)
                label = "[Tool error]" if not success else "[Tool output]"
                output.append(f"{label} ({name}): {content}")

    return "\n".join(output)


# --- Main ---
transcript_path = sys.argv[1]
with open(transcript_path) as f:
    lines = f.readlines()

if not lines:
    print("(empty transcript)")
    sys.exit(0)

start_idx = find_last_turn_start(lines)
if start_idx is None:
    print("(no user message found)")
    sys.exit(0)

last_turn = lines[start_idx:]
formatted = format_turn(last_turn)

if not formatted.strip():
    print("(empty turn)")
    sys.exit(0)

print(formatted)
' "$TRANSCRIPT_PATH" "$MAX_RESULT_CHARS"
