#!/usr/bin/env bash
# Install the memsearch plugin for Copilot CLI.
# Usage: bash install.sh

set -euo pipefail

PLUGIN_NAME="memsearch"
INSTALL_DIR="$HOME/.copilot/extensions/$PLUGIN_NAME"
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

# Create extension directory
mkdir -p "$INSTALL_DIR"

# Copy plugin files
cp -r "$SCRIPT_DIR/hooks" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/scripts" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/prompts" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/skills" "$INSTALL_DIR/"

# Make hooks executable
chmod +x "$INSTALL_DIR"/hooks/*.sh
chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

# Resolve symlinks (copy actual files for portability)
if [ -L "$INSTALL_DIR/scripts/derive-collection.sh" ]; then
  REAL_FILE=$(readlink -f "$INSTALL_DIR/scripts/derive-collection.sh")
  rm "$INSTALL_DIR/scripts/derive-collection.sh"
  cp "$REAL_FILE" "$INSTALL_DIR/scripts/derive-collection.sh"
  chmod +x "$INSTALL_DIR/scripts/derive-collection.sh"
fi

echo ""
echo "✓ Installed to $INSTALL_DIR"
echo ""
echo "Verify: memsearch --version"
echo "The plugin will activate on your next Copilot CLI session."
