#!/usr/bin/env bash
# userPromptSubmit hook: lightweight hint reminding Copilot about the memory-recall skill.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if hook_is_internal; then
  echo '{}'
  exit 0
fi

if [ -z "$MEMSEARCH_CMD" ]; then
  echo '{}'
  exit 0
fi

HOOK_SETTINGS=$(load_hook_settings)
HINT_ENABLED=$(_json_val "$HOOK_SETTINGS" "hint_enabled" "false")
if [ "$HINT_ENABLED" != "true" ]; then
  echo '{}'
  exit 0
fi

PROMPT=$(_json_val "$INPUT" "prompt" "")
MIN_PROMPT_CHARS=$(_json_val "$HOOK_SETTINGS" "hint_min_prompt_chars" "20")
if [ -z "$PROMPT" ] || [ "${#PROMPT}" -lt "$MIN_PROMPT_CHARS" ]; then
  echo '{}'
  exit 0
fi

echo '{"systemMessage": "[memsearch] Memory available"}'
