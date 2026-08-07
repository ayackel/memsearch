#!/usr/bin/env bash
# Install the memsearch plugin for Copilot CLI.
#
# Usage:
#   bash install.sh          # Install from GitHub (recommended)
#   bash install.sh --local  # Install from this local directory
#
# Update:
#   /plugin update memsearch   (inside Copilot CLI)
#   copilot plugin update memsearch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_SOURCE="ayackel/memsearch:plugins/copilot-cli"

# Parse args
LOCAL_INSTALL=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_INSTALL=true
fi

echo "Installing memsearch plugin for Copilot CLI..."

# Check for memsearch or install via uv
if ! command -v uv &>/dev/null; then
  echo "Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v memsearch &>/dev/null; then
  echo "memsearch not found. Installing via uv..."
  uv tool install 'memsearch[onnx]'
else
  echo "Upgrading memsearch..."
  uv tool install --force 'memsearch[onnx]'
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
if [ "$LOCAL_INSTALL" = true ]; then
  echo "Installing from local directory: $SCRIPT_DIR"
  copilot plugin install "$SCRIPT_DIR"
else
  echo "Installing from GitHub: $GITHUB_SOURCE"
  copilot plugin install "$GITHUB_SOURCE"
fi

echo ""
echo "✓ Installed: $(copilot plugin list 2>/dev/null | grep memsearch)"
echo ""
echo "Update later with: /plugin update memsearch"
echo "The plugin will activate on your next Copilot CLI session."
