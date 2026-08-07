#!/usr/bin/env bash
# sessionEnd hook: stop the memsearch watch singleton and clean up.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if hook_is_internal; then
  echo '{}'
  exit 0
fi

stop_watch

echo '{}'
exit 0
