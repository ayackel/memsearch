#!/usr/bin/env bash
# sessionEnd hook: stop the memsearch watch singleton and clean up.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

stop_watch
kill_orphaned_index

exit 0
