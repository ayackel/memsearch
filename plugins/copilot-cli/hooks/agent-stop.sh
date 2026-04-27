#!/usr/bin/env bash
# agentStop hook: parse last turn, summarize with copilot -p, append to daily memory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Skip if memsearch unavailable
if [ -z "$MEMSEARCH_CMD" ]; then
  echo '{}'
  exit 0
fi

# Skip if embedding provider needs an API key we don't have
_required_env_var() {
  case "$1" in
    openai) echo "OPENAI_API_KEY" ;; google) echo "GOOGLE_API_KEY" ;;
    voyage) echo "VOYAGE_API_KEY" ;; jina) echo "JINA_API_KEY" ;;
    mistral) echo "MISTRAL_API_KEY" ;; *) echo "" ;;
  esac
}
_PROVIDER=$($MEMSEARCH_CMD config get embedding.provider 2>/dev/null || echo "onnx")
_REQ_KEY=$(_required_env_var "$_PROVIDER")
if [ -n "$_REQ_KEY" ] && [ -z "${!_REQ_KEY:-}" ]; then
  _CONFIG_API_KEY=$($MEMSEARCH_CMD config get embedding.api_key 2>/dev/null || echo "")
  if [ -z "$_CONFIG_API_KEY" ]; then
    echo '{}'
    exit 0
  fi
fi

# Get transcript path — from hook input, fallback to session state dir
TRANSCRIPT_PATH=$(_json_val "$INPUT" "transcriptPath" "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_PATH="$SESSION_STATE_DIR/events.jsonl"
fi

if [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo '{}'
  exit 0
fi

LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -lt 3 ]; then
  echo '{}'
  exit 0
fi

# Check checkpoint — skip if we already summarized this turn
LAST_LINE_COUNT=""
if [ -f "$CHECKPOINT_FILE" ]; then
  LAST_LINE_COUNT=$(cat "$CHECKPOINT_FILE" 2>/dev/null || true)
fi
CURRENT_LINE_COUNT="$LINE_COUNT"
if [ "$LAST_LINE_COUNT" = "$CURRENT_LINE_COUNT" ]; then
  echo '{}'
  exit 0
fi

ensure_memory_dir

# Parse transcript — extract the last turn
PARSED=$("$SCRIPT_DIR/parse-transcript.sh" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$PARSED" ] || [ "$PARSED" = "(empty transcript)" ] || [ "$PARSED" = "(no user message found)" ] || [ "$PARSED" = "(empty turn)" ]; then
  echo '{}'
  exit 0
fi

TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
MEMORY_FILE="$MEMORY_DIR/$TODAY.md"

# Load summarization prompt
AGENT_NAME="Copilot CLI"
PROMPT_FILE=""
if [ -n "$MEMSEARCH_CMD" ]; then
  PROMPT_FILE=$($MEMSEARCH_CMD config get prompts.summarize 2>/dev/null || true)
fi
if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  SYSTEM_PROMPT=$(sed "s/{{AGENT_NAME}}/$AGENT_NAME/g" "$PROMPT_FILE")
elif [ -f "$SCRIPT_DIR/../prompts/summarize.txt" ]; then
  SYSTEM_PROMPT=$(sed "s/{{AGENT_NAME}}/$AGENT_NAME/g" "$SCRIPT_DIR/../prompts/summarize.txt")
else
  SYSTEM_PROMPT="You are a third-person note-taker. Summarize the transcript as 2-6 bullet points. Write in third person. Output ONLY bullet points."
fi

# Summarize with copilot -p (non-interactive mode)
# copilot -p takes the full prompt as a text argument (no --system-prompt flag),
# so we prepend the system prompt as instructions before the transcript.
# MEMSEARCH_NO_WATCH=1 prevents child copilot from triggering hooks.
SUMMARY=""
if command -v copilot &>/dev/null; then
  FULL_PROMPT="${SYSTEM_PROMPT}

---
Transcript:
${PARSED}"
  # TODO: Verify copilot -p accepts --model claude-haiku-4.5 and --allow-all-tools.
  # If copilot -p doesn't support --model or the model name differs, adjust accordingly.
  SUMMARY=$(MEMSEARCH_NO_WATCH=1 copilot -p \
    --model claude-haiku-4.5 \
    --allow-all-tools \
    "$FULL_PROMPT" \
    2>/dev/null || true)
fi

# Fallback to raw transcript if copilot unavailable or empty
if [ -z "$SUMMARY" ]; then
  SUMMARY="$PARSED"
fi

# Append to daily memory file with session anchor
{
  echo "### $NOW"
  if [ -n "$SESSION_ID" ]; then
    echo "<!-- session:${SESSION_ID} transcript:${TRANSCRIPT_PATH} -->"
  fi
  echo "$SUMMARY"
  echo ""
} >> "$MEMORY_FILE"

# Update checkpoint
echo "$CURRENT_LINE_COUNT" > "$CHECKPOINT_FILE"

# Re-index immediately
kill_orphaned_index
run_memsearch index "$MEMORY_DIR"

echo '{}'
