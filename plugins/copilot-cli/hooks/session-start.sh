#!/usr/bin/env bash
# SessionStart hook: bootstrap memsearch, start watcher, inject semantic memory context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Extract initial prompt from hook input (used for semantic search below)
INITIAL_PROMPT=$(_json_val "$INPUT" "initialPrompt" "")

# --- Bootstrap: install memsearch via uv if not found ---
if [ -z "$MEMSEARCH_CMD" ]; then
  if ! command -v uvx &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
  fi
  uvx --upgrade --from 'memsearch[onnx]' memsearch --version &>/dev/null || true
  _detect_memsearch
fi

# --- First-time setup: default to onnx provider (no API key required) ---
if [ -n "$MEMSEARCH_CMD" ]; then
  if [ ! -f "$HOME/.memsearch/config.toml" ] && [ ! -f "${_PROJECT_DIR:-.}/.memsearch.toml" ]; then
    $MEMSEARCH_CMD config set embedding.provider onnx 2>/dev/null || true
  fi
fi

# --- Read resolved config and version ---
PROVIDER="onnx"; MODEL=""; MILVUS_URI=""; VERSION=""
if [ -n "$MEMSEARCH_CMD" ]; then
  PROVIDER=$($MEMSEARCH_CMD config get embedding.provider 2>/dev/null || echo "onnx")
  MODEL=$($MEMSEARCH_CMD config get embedding.model 2>/dev/null || echo "")
  MILVUS_URI=$($MEMSEARCH_CMD config get milvus.uri 2>/dev/null || echo "")
  VERSION=$($MEMSEARCH_CMD --version 2>/dev/null | sed 's/.*version //' || echo "")
fi

# --- Check API key availability ---
_required_env_var() {
  case "$1" in
    openai) echo "OPENAI_API_KEY" ;;
    google) echo "GOOGLE_API_KEY" ;;
    voyage) echo "VOYAGE_API_KEY" ;;
    jina)   echo "JINA_API_KEY" ;;
    mistral) echo "MISTRAL_API_KEY" ;;
    *) echo "" ;;  # onnx, ollama, local — no API key needed
  esac
}
REQUIRED_KEY=$(_required_env_var "$PROVIDER")

KEY_MISSING=false
if [ -n "$REQUIRED_KEY" ] && [ -z "${!REQUIRED_KEY:-}" ]; then
  CONFIG_API_KEY=""
  if [ -n "$MEMSEARCH_CMD" ]; then
    CONFIG_API_KEY=$($MEMSEARCH_CMD config get embedding.api_key 2>/dev/null || echo "")
  fi
  if [ -z "$CONFIG_API_KEY" ]; then
    KEY_MISSING=true
  fi
fi

# --- Check PyPI for newer version (non-blocking) ---
UPDATE_HINT=""
if [ -n "$VERSION" ]; then
  _PYPI_JSON=$(curl -s --max-time 2 https://pypi.org/pypi/memsearch/json 2>/dev/null || true)
  LATEST=$(_json_val "$_PYPI_JSON" "info.version" "")
  if [ -n "$LATEST" ] && [ "$LATEST" != "$VERSION" ]; then
    _MS_REAL=$(readlink -f "$(command -v memsearch 2>/dev/null)" 2>/dev/null || echo "")
    if [[ "$MEMSEARCH_CMD" == *"uvx"* ]] || [[ "$_MS_REAL" == *"uv/tools"* ]]; then
      UPGRADE_CMD="uv tool install -U 'memsearch[onnx]'"
    else
      UPGRADE_CMD="pip install --upgrade 'memsearch[onnx]'"
    fi
    UPDATE_HINT=" | UPDATE: v${LATEST} available — run: ${UPGRADE_CMD}"
  fi
fi

# --- Build status line ---
VERSION_TAG="${VERSION:+ v${VERSION}}"
COLLECTION_HINT=""
if [ -n "$COLLECTION_NAME" ]; then
  COLLECTION_HINT=" | collection: ${COLLECTION_NAME}"
fi
status="[memsearch${VERSION_TAG}] embedding: ${PROVIDER}/${MODEL:-unknown} | milvus: ${MILVUS_URI:-unknown}${COLLECTION_HINT}${UPDATE_HINT}"
if [ "$KEY_MISSING" = true ]; then
  status+=" | ERROR: ${REQUIRED_KEY} not set — memory search disabled"
  status+=" | Tip: switch to free local embedding: memsearch config set embedding.provider onnx && memsearch index --force"
fi

# --- Build collection description ---
PROJECT_BASENAME=$(basename "${_PROJECT_DIR:-.}")
COLLECTION_DESC="${PROJECT_BASENAME} | ${PROVIDER}/${MODEL:-default}"

# --- Write session heading to daily memory file ---
ensure_memory_dir
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M)
MEMORY_FILE="$MEMORY_DIR/$TODAY.md"
if [ ! -f "$MEMORY_FILE" ] || ! grep -qF "## Session $NOW" "$MEMORY_FILE"; then
  echo -e "\n## Session $NOW\n" >> "$MEMORY_FILE"
fi

# If API key is missing, show status and exit early
if [ "$KEY_MISSING" = true ]; then
  json_status=$(_json_encode_str "$status")
  echo "{\"systemMessage\": $json_status}"
  exit 0
fi

# --- Start file watcher (Server) or one-time index (Lite) ---
start_watch

# Lite mode: background one-time index (ONNX model loading takes ~10s)
if [[ "$MILVUS_URI" != http* ]] && [[ "$MILVUS_URI" != tcp* ]]; then
  kill_orphaned_index
  (
    _index_args=("$MEMORY_DIR")
    [ -n "$COLLECTION_NAME" ] && _index_args+=(--collection "$COLLECTION_NAME")
    [ -n "$COLLECTION_DESC" ] && _index_args+=(--description "$COLLECTION_DESC")
    INDEX_OUTPUT=$($MEMSEARCH_CMD index "${_index_args[@]}" 2>&1) || true
    if echo "$INDEX_OUTPUT" | grep -q "dimension mismatch"; then
      _reset_args=(--yes)
      [ -n "$COLLECTION_NAME" ] && _reset_args+=(--collection "$COLLECTION_NAME")
      $MEMSEARCH_CMD reset "${_reset_args[@]}" 2>/dev/null || true
      $MEMSEARCH_CMD index "${_index_args[@]}" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  echo $! > "$INDEX_PIDFILE"
fi

# --- Always include status ---
json_status=$(_json_encode_str "$status")

# No memory files yet? Just emit status.
if [ ! -d "$MEMORY_DIR" ] || ! ls "$MEMORY_DIR"/*.md &>/dev/null; then
  echo "{\"systemMessage\": $json_status}"
  exit 0
fi

context=""

# --- Semantic search: use initial prompt as query for relevant memory ---
if [ -n "$INITIAL_PROMPT" ] && [ -n "$MEMSEARCH_CMD" ]; then
  _search_args=(search "$INITIAL_PROMPT" --top-k 5)
  [ -n "$COLLECTION_NAME" ] && _search_args+=(--collection "$COLLECTION_NAME")
  search_results=$($MEMSEARCH_CMD "${_search_args[@]}" 2>/dev/null || true)
  if [ -n "$search_results" ] && [ "$search_results" != "No results found." ]; then
    context="# Relevant Memory (semantic search)\n\n$search_results\n"
  fi
fi

# --- Fallback: recent file headings if search returned nothing ---
if [ -z "$context" ]; then
  recent_files=$(ls -1 "$MEMORY_DIR"/*.md 2>/dev/null | sort -r | head -2)
  if [ -n "$recent_files" ]; then
    context="# Recent Memory\n\n"
    while IFS= read -r f; do
      basename_f=$(basename "$f")
      content=$(grep -E '^(#{2,4} |- )' "$f" 2>/dev/null | head -40 || true)
      if [ -n "$content" ]; then
        context+="## $basename_f\n$content\n\n"
      fi
    done <<< "$recent_files"
  fi
fi

# --- Emit JSON output ---
# Copilot CLI uses top-level additionalContext (not nested under hookSpecificOutput)
if [ -n "$context" ]; then
  json_context=$(_json_encode_str "$context")
  echo "{\"systemMessage\": $json_status, \"additionalContext\": $json_context}"
else
  echo "{\"systemMessage\": $json_status}"
fi
