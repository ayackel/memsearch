#!/usr/bin/env bash
# Install the memsearch plugin for Copilot CLI.
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing memsearch plugin for Copilot CLI..."

# Check for memsearch or install via uv
if ! command -v memsearch &>/dev/null; then
  echo "memsearch not found. Installing via uv..."
  if ! command -v uv &>/dev/null; then
    echo "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi
  uv tool install 'memsearch[onnx]'
fi

# Check for copilot CLI
if ! command -v copilot &>/dev/null; then
  echo "Error: Copilot CLI (copilot) not found. Install it first:"
  echo "  https://docs.github.com/en/copilot/how-tos/copilot-cli"
  exit 1
fi

# Uninstall previous version if present
if copilot plugin list 2>/dev/null | grep -q memsearch; then
  echo "Removing previous installation..."
  copilot plugin uninstall memsearch 2>/dev/null || true
fi

# Clean up legacy install locations
for legacy_dir in "$HOME/.copilot/extensions/memsearch" "$HOME/.copilot/installed-plugins/local/memsearch"; do
  if [ -d "$legacy_dir" ]; then
    rm -rf "$legacy_dir"
    echo "Removed legacy install at $legacy_dir"
  fi
done

# Install via the official Copilot CLI plugin command
copilot plugin install "$SCRIPT_DIR"

echo ""
echo "Verify: copilot plugin list | grep memsearch"
echo "The plugin will activate on your next Copilot CLI session."
