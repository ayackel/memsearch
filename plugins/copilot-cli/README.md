# memsearch Plugin for Copilot CLI

Persistent memory across Copilot CLI sessions. Captures concise turn facts into
markdown and indexes them with semantic embeddings. Recall is explicit by
default through the `memory-recall` skill.

## Install

```bash
bash install.sh
```

## How It Works

**Hooks:**
- `sessionStart` — Reports status and starts a watcher for server-backed Milvus
- `agentStop` — After each assistant turn, extracts concise user/answer facts and indexes them
- `sessionEnd` — Stops the file watcher and cleans up background processes
- `userPromptSubmit` — Optional hint reminding Copilot about the memory-recall skill

**Skill:**
- `memory-recall` — Forked subagent that searches memsearch for relevant past context

**Data Flow:**
```
Session transcript → extract-memory.py → daily .md file
                                                                          ↓
                                                                    memsearch index
                                                                          ↓
memory-recall skill → memsearch search/expand → curated historical context
```

## Configuration

Uses memsearch's standard config (`~/.memsearch/config.toml` or `.memsearch.toml`).

Default: ONNX embedding (bge-m3, CPU, no API key needed).

Copilot turn capture defaults to deterministic extraction, avoiding recursive
nested Copilot sessions. Set
`plugins.copilot-cli.summarize.provider = "native"` to opt into LLM
summarization through `copilot -p`, or name a configured memsearch LLM provider.

Automatic startup recall and prompt hints are disabled by default:

```toml
[plugins.copilot-cli.recall]
enabled = true
top_k = 5
min_prompt_chars = 20

[plugins.copilot-cli.prompt_hint]
enabled = true
min_prompt_chars = 20
```

To remove old empty session headings and raw-transcript entries:

```bash
python3 scripts/clean-memory.py /path/to/project/.memsearch/memory --dry-run
python3 scripts/clean-memory.py /path/to/project/.memsearch/memory
```

## Requirements

- Copilot CLI
- Python 3.8+
- memsearch (`uv tool install 'memsearch[onnx]'`)
