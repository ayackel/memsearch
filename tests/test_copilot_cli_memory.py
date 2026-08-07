from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import time
from pathlib import Path

EXTRACT_SCRIPT = Path("plugins/copilot-cli/hooks/extract-memory.py")
CLEAN_SCRIPT = Path("plugins/copilot-cli/scripts/clean-memory.py")


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")


def _load_clean_module():
    spec = importlib.util.spec_from_file_location("clean_memory", CLEAN_SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_extract_memory_uses_last_turn_and_omits_tools(tmp_path: Path) -> None:
    transcript = tmp_path / "events.jsonl"
    _write_jsonl(
        transcript,
        [
            {"type": "user.message", "data": {"content": "old question"}},
            {"type": "assistant.message", "data": {"content": "old answer"}},
            {"type": "user.message", "data": {"content": "Why did the build fail?"}},
            {
                "type": "assistant.message",
                "data": {
                    "content": "Checking.",
                    "toolRequests": [{"name": "bash", "arguments": {"command": "cat secret.log"}}],
                },
            },
            {
                "type": "tool.execution_complete",
                "data": {"success": False, "result": {"content": "raw traceback"}},
            },
            {"type": "assistant.message", "data": {"content": "The build failed because Java 21 is required."}},
        ],
    )

    result = subprocess.run(
        ["python3", str(EXTRACT_SCRIPT), str(transcript)],
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout == (
        "- User asked: Why did the build fail?\n"
        "- Copilot answered: The build failed because Java 21 is required.\n"
    )
    assert "old question" not in result.stdout
    assert "traceback" not in result.stdout
    assert "secret.log" not in result.stdout


def test_extract_memory_skips_internal_agent_prompt(tmp_path: Path) -> None:
    transcript = tmp_path / "events.jsonl"
    _write_jsonl(
        transcript,
        [
            {"type": "session.start", "data": {}},
            {"type": "user.message", "data": {"content": "You are FIDO, monitor the build."}},
            {"type": "assistant.message", "data": {"content": "Build passed."}},
        ],
    )

    result = subprocess.run(
        ["python3", str(EXTRACT_SCRIPT), str(transcript)],
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout == ""


def test_clean_memory_removes_empty_and_raw_sections() -> None:
    module = _load_clean_module()
    original = """# 2026-08-07

## Session 10:00

## Session 10:01
<!-- session:good -->
- User asked: What changed?
- Copilot answered: Fixed the hook.

## Session 10:02
<!-- session:bad -->
=== Transcript of a conversation between a human and Copilot CLI ===
[Human]: dump everything
[Tool output] (bash): noisy
"""

    cleaned = module.clean_text(original)

    assert "Session 10:00" not in cleaned
    assert "Session 10:01" in cleaned
    assert "Fixed the hook" in cleaned
    assert "Session 10:02" in cleaned
    assert "- User asked: dump everything" in cleaned
    assert "[Tool output]" not in cleaned


def test_clean_memory_removes_raw_legacy_entry_but_keeps_sibling() -> None:
    module = _load_clean_module()
    original = """## Session 21:25

### 21:32
- Copilot answered: useful result

### 21:37
=== Transcript of a conversation between a human and Copilot CLI ===
[Human]: injected skill context
[Tool output] (bash): noisy
"""

    cleaned = module.clean_text(original)

    assert "Session 21:25" in cleaned
    assert "### 21:32" in cleaned
    assert "useful result" in cleaned
    assert "### 21:37" in cleaned
    assert "- User asked: injected skill context" in cleaned
    assert "[Human]:" not in cleaned


def test_clean_memory_removes_raw_legacy_entry_without_session_heading() -> None:
    module = _load_clean_module()
    original = """### 00:00
=== Transcript of a conversation between a human and Copilot CLI ===
[Human]: system plumbing

### 01:00
- User asked: real question
- Copilot answered: real answer
"""

    cleaned = module.clean_text(original)

    assert "### 00:00" in cleaned
    assert "- User asked: system plumbing" in cleaned
    assert "### 01:00" in cleaned
    assert "real answer" in cleaned


def test_clean_memory_removes_internal_agent_entry() -> None:
    module = _load_clean_module()
    original = """## Session 20:57
<!-- session:internal -->
- User asked: [SYSTEM INSTRUCTIONS - follow these exactly] You are the Brain Trust panel selector.
- Copilot answered: {"intent": "critique"}

## Session 21:00
- User asked: Explain the result.
- Copilot answered: The build passed.
"""

    cleaned = module.clean_text(original)

    assert "Session 20:57" not in cleaned
    assert "Brain Trust panel selector" not in cleaned
    assert "Session 21:00" in cleaned


def test_convert_raw_body_uses_final_assistant_message() -> None:
    module = _load_clean_module()
    body = """<!-- session:test -->
=== Transcript of a conversation between a human and Copilot CLI ===
[Human]: Find the error for document 8000ee1c.
[Copilot CLI]: Checking.
[Copilot CLI calls tool]: memsearch search(...)
[Tool output]: noisy historical transcript
[Copilot CLI]: Document 8000ee1c failed with BlobNotFound.
"""

    converted = module.convert_raw_body(body)

    assert "<!-- session:test -->" in converted
    assert "- User asked: Find the error for document 8000ee1c." in converted
    assert "- Copilot answered: Document 8000ee1c failed with BlobNotFound." in converted
    assert "noisy historical transcript" not in converted


def test_agent_stop_detaches_and_writes_extracted_memory(tmp_path: Path) -> None:
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_memsearch = fake_bin / "memsearch"
    fake_memsearch.write_text(
        """#!/usr/bin/env bash
if [ "$1 $2 $3" = "config get plugins.copilot-cli.summarize.enabled" ]; then echo true
elif [ "$1 $2 $3" = "config get plugins.copilot-cli.summarize.provider" ]; then echo extract
elif [ "$1 $2 $3" = "config get embedding.provider" ]; then echo onnx
elif [ "$1" = "index" ]; then exit 0
else echo ""
fi
""",
        encoding="utf-8",
    )
    fake_memsearch.chmod(0o755)

    project = tmp_path / "project"
    project.mkdir()
    transcript = tmp_path / "events.jsonl"
    _write_jsonl(
        transcript,
        [
            {"type": "session.start", "data": {}},
            {"type": "user.message", "data": {"content": "Fix the recursion bug"}},
            {"type": "assistant.message", "data": {"content": "Added the missing hook guard."}},
        ],
    )
    hook_input = {
        "transcriptPath": str(transcript),
        "stopReason": "end_turn",
        "stop_hook_active": False,
        "sessionId": "test-session",
        "cwd": str(project),
    }
    env = {
        **os.environ,
        "HOME": str(tmp_path),
        "PATH": f"{fake_bin}:{os.environ['PATH']}",
    }

    result = subprocess.run(
        ["bash", "plugins/copilot-cli/hooks/agent-stop.sh"],
        input=json.dumps(hook_input),
        capture_output=True,
        text=True,
        check=True,
        env=env,
    )

    assert result.stdout == "{}\n"
    memory_dir = project / ".memsearch" / "memory"
    deadline = time.monotonic() + 5
    memory_files: list[Path] = []
    while time.monotonic() < deadline:
        memory_files = list(memory_dir.glob("*.md"))
        if memory_files:
            break
        time.sleep(0.05)

    assert len(memory_files) == 1
    content = memory_files[0].read_text(encoding="utf-8")
    assert "## Session " in content
    assert "- User asked: Fix the recursion bug" in content
    assert "- Copilot answered: Added the missing hook guard." in content
    assert "=== Transcript" not in content
