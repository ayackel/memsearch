# memsearch Plugin for Copilot CLI

Automatic persistent memory across Copilot CLI sessions. Captures session
summaries into markdown, indexes them with semantic embeddings, and injects
relevant context at session start.

## Install

```bash
bash install.sh
```

## How It Works

**Hooks:**
- `sessionStart` — Bootstraps memsearch, starts file watcher, injects recent memories via semantic search
- `agentStop` — After each assistant turn, parses the transcript and summarizes via `copilot -p --model haiku`
- `sessionEnd` — Stops the file watcher and cleans up background processes
- `userPromptSubmit` — Lightweight hint reminding Copilot about the memory-recall skill

**Skill:**
- `memory-recall` — Forked subagent that searches memsearch for relevant past context

**Data Flow:**
```
Session transcript → parse-transcript.sh → copilot -p (summarize) → daily .md file
                                                                          ↓
                                                                    memsearch index
                                                                          ↓
Next session start → memsearch search → additionalContext injection
```

## Configuration

Uses memsearch's standard config (`~/.memsearch/config.toml` or `.memsearch.toml`).

Default: ONNX embedding (bge-m3, CPU, no API key needed).

## Requirements

- Copilot CLI
- Python 3.8+
- memsearch (`uv tool install 'memsearch[onnx]'`)
