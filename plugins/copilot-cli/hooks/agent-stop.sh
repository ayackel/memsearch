#!/usr/bin/env bash
# agentStop hook: parse last turn, summarize, append to daily memory.
# CRITICAL: This hook MUST return {} immediately and do all work in background.
# Blocking here causes session termination to hang (zombie processes accumulate).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Emit response immediately — never block session termination.
echo '{}'

# Skip if memsearch unavailable
if [ -z "$MEMSEARCH_CMD" ]; then
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
    exit 0
  fi
fi

# Get transcript path — from hook input, fallback to session state dir
TRANSCRIPT_PATH=$(_json_val "$INPUT" "transcriptPath" "")
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_PATH="$SESSION_STATE_DIR/events.jsonl"
fi

if [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

LINE_COUNT=$(wc -l < "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
if [ "$LINE_COUNT" -lt 3 ]; then
  exit 0
fi

# Check checkpoint — skip if we already summarized this turn
LAST_LINE_COUNT=""
if [ -f "$CHECKPOINT_FILE" ]; then
  LAST_LINE_COUNT=$(cat "$CHECKPOINT_FILE" 2>/dev/null || true)
fi
CURRENT_LINE_COUNT="$LINE_COUNT"
if [ "$LAST_LINE_COUNT" = "$CURRENT_LINE_COUNT" ]; then
  exit 0
fi

ensure_memory_dir

# Parse transcript — extract the last turn
PARSED=$("$SCRIPT_DIR/parse-transcript.sh" "$TRANSCRIPT_PATH" 2>/dev/null || true)

if [ -z "$PARSED" ] || [ "$PARSED" = "(empty transcript)" ] || [ "$PARSED" = "(no user message found)" ] || [ "$PARSED" = "(empty turn)" ]; then
  exit 0
fi

# --- All validation passed. Fork summarization into background with a timeout. ---
# Use setsid to fully detach so the hook process can exit immediately.
# The 30s timeout kills the summarization if it hangs (copilot -p, network, etc.)

_do_summarize() {
  local TODAY NOW MEMORY_FILE AGENT_NAME PROMPT_FILE SYSTEM_PROMPT
  local SUMMARY SUMMARIZE_PROVIDER SUMMARIZE_MODEL CONFIG_MODEL FULL_PROMPT

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
  SUMMARY=""
  SUMMARIZE_PROVIDER=""
  if [ -n "$MEMSEARCH_CMD" ]; then
    SUMMARIZE_PROVIDER=$($MEMSEARCH_CMD config get plugins.copilot-cli.summarize.provider 2>/dev/null || true)
  fi

  if [ -n "$SUMMARIZE_PROVIDER" ] && [ "$SUMMARIZE_PROVIDER" != "native" ] && [ -n "$MEMSEARCH_CMD" ]; then
    SUMMARY=$(printf '%s' "$PARSED" | MEMSEARCH_NO_WATCH=1 $MEMSEARCH_CMD summarize \
      --plugin copilot-cli \
      --agent-name "$AGENT_NAME" \
      2>/dev/null || true)
  elif command -v copilot &>/dev/null; then
    SUMMARIZE_MODEL="claude-haiku-4.5"
    if [ -n "$MEMSEARCH_CMD" ]; then
      CONFIG_MODEL=$($MEMSEARCH_CMD config get plugins.copilot-cli.summarize.model 2>/dev/null || true)
      if [ -n "$CONFIG_MODEL" ]; then
        SUMMARIZE_MODEL="$CONFIG_MODEL"
      fi
    fi
    FULL_PROMPT="${SYSTEM_PROMPT}

Transcript:
${PARSED}"
    # 25s timeout for the copilot call itself (leaves 5s margin within the 30s outer timeout)
    SUMMARY=$(timeout 25 env MEMSEARCH_NO_WATCH=1 copilot \
      --model "$SUMMARIZE_MODEL" \
      -p "$FULL_PROMPT" \
      </dev/null 2>/dev/null || true)
  fi

  # Fallback to raw transcript if summarization failed/timed out
  if [ -z "$SUMMARY" ]; then
    SUMMARY="$PARSED"
  fi

  # Strip any interactive interruption banner ("● Operation cancelled by user")
  # that leaks into stdout when a signalled copilot subprocess is aborted, then
  # drop the dangling bullet glyph the cut leaves behind.
  SUMMARY=${SUMMARY%%Operation cancelled by user*}
  SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/●[[:space:]]*$//')

  # Update checkpoint regardless so a cancelled turn is not re-processed.
  mkdir -p "$(dirname "$CHECKPOINT_FILE")"
  echo "$CURRENT_LINE_COUNT" > "$CHECKPOINT_FILE"

  # Nothing meaningful left (e.g. a cancelled turn) — don't write an empty entry.
  if [ -z "$(printf '%s' "$SUMMARY" | tr -d '[:space:]-')" ]; then
    return 0
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

  # Re-index
  run_memsearch index "$MEMORY_DIR"
}

# Export variables needed by the background function
export MEMSEARCH_CMD MEMSEARCH_NO_WATCH=1 MEMORY_DIR SESSION_ID
export TRANSCRIPT_PATH CHECKPOINT_FILE CURRENT_LINE_COUNT PARSED
export COLLECTION_NAME COLLECTION_DESC SCRIPT_DIR

# Run in background with 30s hard timeout, fully detached from parent.
# setsid puts the summarizer in its own session with no controlling terminal, so
# a Ctrl-C in the interactive session cannot deliver SIGINT to the nested
# `copilot -p` call (which would otherwise leak its "Operation cancelled by user"
# banner into the summary). Fall back to plain background if setsid is missing.
if command -v setsid &>/dev/null; then
  setsid timeout 30 bash -c "$(declare -f _do_summarize _json_val _json_encode_str run_memsearch ensure_memory_dir kill_orphaned_index); _do_summarize" </dev/null &>/dev/null &
else
  (timeout 30 bash -c "$(declare -f _do_summarize _json_val _json_encode_str run_memsearch ensure_memory_dir kill_orphaned_index); _do_summarize") </dev/null &>/dev/null &
fi
disown
