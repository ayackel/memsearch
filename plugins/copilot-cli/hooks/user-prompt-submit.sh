#!/usr/bin/env bash
# userPromptSubmit hook: lightweight hint reminding Copilot about the memory-recall skill.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Skip short prompts
PROMPT=$(_json_val "$INPUT" "prompt" "")
if [ -z "$PROMPT" ] || [ "${#PROMPT}" -lt 10 ]; then
  echo '{}'
  exit 0
fi

if [ -z "$MEMSEARCH_CMD" ]; then
  echo '{}'
  exit 0
fi

echo '{"systemMessage": "[memsearch] Memory available"}'
