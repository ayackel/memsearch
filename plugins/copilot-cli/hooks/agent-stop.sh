#!/usr/bin/env bash
# agentStop hook: detach immediately, capture the last turn, and index it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

_required_env_var() {
  case "$1" in
    openai) echo "OPENAI_API_KEY" ;;
    google) echo "GOOGLE_API_KEY" ;;
    voyage) echo "VOYAGE_API_KEY" ;;
    jina) echo "JINA_API_KEY" ;;
    mistral) echo "MISTRAL_API_KEY" ;;
    *) echo "" ;;
  esac
}

_record_failure() {
  local reason="$1" provider="${2:-unknown}"
  local error_file="$SESSION_STATE_DIR/.memsearch_summary_error"
  mkdir -p "$SESSION_STATE_DIR"
  printf '%s line_count=%s provider=%s reason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CURRENT_LINE_COUNT:-unknown}" "$provider" "$reason" > "$error_file"
}

_run_worker() {
  if [ -z "$MEMSEARCH_CMD" ]; then
    return 0
  fi

  local summarize_enabled
  summarize_enabled=$($MEMSEARCH_CMD config get plugins.copilot-cli.summarize.enabled 2>/dev/null || echo "true")
  if [ "$summarize_enabled" = "false" ]; then
    return 0
  fi

  local provider required_key config_api_key
  provider=$($MEMSEARCH_CMD config get embedding.provider 2>/dev/null || echo "onnx")
  required_key=$(_required_env_var "$provider")
  if [ -n "$required_key" ] && [ -z "${!required_key:-}" ]; then
    config_api_key=$($MEMSEARCH_CMD config get embedding.api_key 2>/dev/null || echo "")
    if [ -z "$config_api_key" ]; then
      return 0
    fi
  fi

  local transcript_path
  transcript_path=$(_json_val "$INPUT" "transcriptPath" "")
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    transcript_path="$SESSION_STATE_DIR/events.jsonl"
  fi
  if [ ! -f "$transcript_path" ]; then
    return 0
  fi

  local line_count last_line_count=""
  line_count=$(wc -l < "$transcript_path" 2>/dev/null || echo "0")
  if [ "$line_count" -lt 3 ]; then
    return 0
  fi
  CURRENT_LINE_COUNT="$line_count"

  if [ -f "$CHECKPOINT_FILE" ]; then
    last_line_count=$(cat "$CHECKPOINT_FILE" 2>/dev/null || true)
  fi
  if [ "$last_line_count" = "$CURRENT_LINE_COUNT" ]; then
    return 0
  fi

  local summarize_provider summary="" parsed=""
  summarize_provider=$($MEMSEARCH_CMD config get plugins.copilot-cli.summarize.provider 2>/dev/null || echo "extract")
  [ -z "$summarize_provider" ] && summarize_provider="extract"

  if [ "$summarize_provider" = "extract" ]; then
    summary=$(python3 "$SCRIPT_DIR/extract-memory.py" "$transcript_path" 2>/dev/null || true)
  else
    parsed=$("$SCRIPT_DIR/parse-transcript.sh" "$transcript_path" 2>/dev/null || true)
    if [ -z "$parsed" ] || [ "$parsed" = "(empty transcript)" ] \
      || [ "$parsed" = "(no user message found)" ] || [ "$parsed" = "(empty turn)" ]; then
      _record_failure "empty-transcript" "$summarize_provider"
      return 0
    fi

    if [ "$summarize_provider" != "native" ]; then
      summary=$(printf '%s' "$parsed" | MEMSEARCH_NO_WATCH=1 $MEMSEARCH_CMD summarize \
        --plugin copilot-cli \
        --agent-name "Copilot CLI" \
        2>/dev/null || true)
    elif command -v copilot &>/dev/null; then
      local prompt_file system_prompt summarize_model config_model full_prompt
      prompt_file=$($MEMSEARCH_CMD config get prompts.summarize 2>/dev/null || true)
      if [ -n "$prompt_file" ] && [ -f "$prompt_file" ]; then
        system_prompt=$(sed "s/{{AGENT_NAME}}/Copilot CLI/g" "$prompt_file")
      elif [ -f "$SCRIPT_DIR/../prompts/summarize.txt" ]; then
        system_prompt=$(sed "s/{{AGENT_NAME}}/Copilot CLI/g" "$SCRIPT_DIR/../prompts/summarize.txt")
      else
        system_prompt="You are a third-person note-taker. Summarize the transcript as 2-6 bullet points. Output only bullet points."
      fi
      summarize_model="claude-haiku-4.5"
      config_model=$($MEMSEARCH_CMD config get plugins.copilot-cli.summarize.model 2>/dev/null || true)
      [ -n "$config_model" ] && summarize_model="$config_model"
      full_prompt="${system_prompt}

Transcript:
${parsed}"
      summary=$(timeout 25 env MEMSEARCH_NO_WATCH=1 MEMSEARCH_IN_SUMMARY_WORKER=1 copilot \
        --model "$summarize_model" \
        -p "$full_prompt" \
        </dev/null 2>/dev/null || true)
    fi
  fi

  summary=${summary%%Operation cancelled by user*}
  summary=$(printf '%s' "$summary" | sed 's/●[[:space:]]*$//')
  if [ -z "$(printf '%s' "$summary" | tr -d '[:space:]-')" ]; then
    _record_failure "empty-summary" "$summarize_provider"
    mkdir -p "$(dirname "$CHECKPOINT_FILE")"
    echo "$CURRENT_LINE_COUNT" > "$CHECKPOINT_FILE"
    return 0
  fi

  ensure_memory_dir
  local today now memory_file
  today=$(date +%Y-%m-%d)
  now=$(date +%H:%M)
  memory_file="$MEMORY_DIR/$today.md"

  if command -v flock &>/dev/null; then
    exec 9>"$MEMORY_DIR/.memory-write.lock"
    if ! flock -w 30 9; then
      _record_failure "write-lock-timeout" "$summarize_provider"
      return 0
    fi
  fi

  {
    echo "## Session $now"
    if [ -n "$SESSION_ID" ]; then
      echo "<!-- session:${SESSION_ID} transcript:${transcript_path} -->"
    fi
    echo "$summary"
    echo ""
  } >> "$memory_file"

  mkdir -p "$(dirname "$CHECKPOINT_FILE")"
  echo "$CURRENT_LINE_COUNT" > "$CHECKPOINT_FILE"

  if run_memsearch_checked index "$MEMORY_DIR"; then
    rm -f "$SESSION_STATE_DIR/.memsearch_summary_error"
  else
    _record_failure "index-failed" "$summarize_provider"
  fi
}

if [ "${1:-}" = "--worker" ]; then
  _run_worker
  exit 0
fi

# The hook process itself performs only cheap recursion checks, then detaches.
echo '{}'

stop_hook_active=$(_json_val "$INPUT" "stop_hook_active" "false")
stop_reason=$(_json_val "$INPUT" "stopReason" "")
if hook_is_internal || [ "$stop_hook_active" = "true" ]; then
  exit 0
fi
if [ -n "$stop_reason" ] && [ "$stop_reason" != "end_turn" ]; then
  exit 0
fi

export MEMSEARCH_HOOK_INPUT="$INPUT"
export MEMSEARCH_NO_WATCH=1
export MEMSEARCH_IN_SUMMARY_WORKER=1

if command -v setsid &>/dev/null; then
  setsid timeout 60 bash "$0" --worker </dev/null &>/dev/null &
else
  timeout 60 bash "$0" --worker </dev/null &>/dev/null &
fi
disown
