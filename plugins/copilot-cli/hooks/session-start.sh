#!/usr/bin/env bash
# SessionStart hook: bootstrap memsearch, start watcher, inject semantic memory context.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if hook_is_internal; then
  echo '{}'
  exit 0
fi

# Extract initial prompt from hook input (used for semantic search below)
INITIAL_PROMPT=$(_json_val "$INPUT" "initialPrompt" "")

# Installation is explicit. Session startup must never perform network or
# package-management work.
if [ -z "$MEMSEARCH_CMD" ]; then
  echo '{"systemMessage": "[memsearch] CLI unavailable; run plugins/copilot-cli/install.sh"}'
  exit 0
fi

# --- First-time setup: default to onnx provider (no API key required) ---
if [ -n "$MEMSEARCH_CMD" ]; then
  if [ ! -f "$HOME/.memsearch/config.toml" ] && [ ! -f "${_PROJECT_DIR:-.}/.memsearch.toml" ]; then
    $MEMSEARCH_CMD config set embedding.provider onnx &>/dev/null || true
  fi
fi

# --- Read config once without loading the full CLI repeatedly ---
HOOK_SETTINGS=$(load_hook_settings)
PROVIDER=$(_json_val "$HOOK_SETTINGS" "provider" "onnx")
MODEL=$(_json_val "$HOOK_SETTINGS" "model" "")
MILVUS_URI=$(_json_val "$HOOK_SETTINGS" "milvus_uri" "~/.memsearch/milvus.db")
PLUGIN_JSON=$(cat "$SCRIPT_DIR/../plugin.json" 2>/dev/null || echo '{}')
VERSION=$(_json_val "$PLUGIN_JSON" "version" "")

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
  CONFIG_API_KEY=$(_json_val "$HOOK_SETTINGS" "embedding_api_key" "")
  if [[ "$CONFIG_API_KEY" == env:* ]]; then
    CONFIG_API_KEY_ENV=${CONFIG_API_KEY#env:}
    CONFIG_API_KEY=${!CONFIG_API_KEY_ENV:-}
  fi
  if [ -z "$CONFIG_API_KEY" ]; then
    KEY_MISSING=true
  fi
fi

# --- Build status line ---
VERSION_TAG="${VERSION:+ v${VERSION}}"
COLLECTION_HINT=""
if [ -n "$COLLECTION_NAME" ]; then
  COLLECTION_HINT=" | collection: ${COLLECTION_NAME}"
fi
status="[memsearch${VERSION_TAG}] embedding: ${PROVIDER}/${MODEL:-unknown} | milvus: ${MILVUS_URI:-unknown}${COLLECTION_HINT}"
if [ "$KEY_MISSING" = true ]; then
  status+=" | ERROR: ${REQUIRED_KEY} not set — memory search disabled"
  status+=" | Tip: switch to free local embedding: memsearch config set embedding.provider onnx && memsearch index --force"
fi

# --- Build collection description ---
PROJECT_BASENAME=$(basename "${_PROJECT_DIR:-.}")
COLLECTION_DESC="${PROJECT_BASENAME} | ${PROVIDER}/${MODEL:-default}"

# If API key is missing, show status and exit early
if [ "$KEY_MISSING" = true ]; then
  json_status=$(_json_encode_str "$status")
  echo "{\"systemMessage\": $json_status}"
  exit 0
fi

# Server-backed collections can watch safely. Milvus Lite is indexed only
# after a successful memory write, avoiding startup model load and lock races.
start_watch

# --- Always include status ---
json_status=$(_json_encode_str "$status")

# Automatic recall is opt-in. The memory-recall skill remains the default
# retrieval path so ordinary session startup stays fast and deterministic.
RECALL_ENABLED=$(_json_val "$HOOK_SETTINGS" "recall_enabled" "false")
if [ "$RECALL_ENABLED" != "true" ]; then
  echo "{\"systemMessage\": $json_status}"
  exit 0
fi

RECALL_MIN_PROMPT_CHARS=$(_json_val "$HOOK_SETTINGS" "recall_min_prompt_chars" "20")
RECALL_TOP_K=$(_json_val "$HOOK_SETTINGS" "recall_top_k" "5")

if [ ! -d "$MEMORY_DIR" ] || ! ls "$MEMORY_DIR"/*.md &>/dev/null \
  || [ "${#INITIAL_PROMPT}" -lt "$RECALL_MIN_PROMPT_CHARS" ]; then
  echo "{\"systemMessage\": $json_status}"
  exit 0
fi

_search_args=(search "$INITIAL_PROMPT" --top-k "$RECALL_TOP_K")
[ -n "$COLLECTION_NAME" ] && _search_args+=(--collection "$COLLECTION_NAME")
search_results=$($MEMSEARCH_CMD "${_search_args[@]}" 2>/dev/null || true)
if [ -n "$search_results" ] && [ "$search_results" != "No results found." ]; then
  context="# Relevant Memory (semantic search)\n\n$search_results\n"
  json_context=$(_json_encode_str "$context")
  echo "{\"systemMessage\": $json_status, \"additionalContext\": $json_context}"
else
  echo "{\"systemMessage\": $json_status}"
fi
