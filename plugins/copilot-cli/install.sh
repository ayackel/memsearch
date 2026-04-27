#!/usr/bin/env bash
# Install the memsearch plugin for Copilot CLI.
# Usage: bash install.sh

set -euo pipefail

PLUGIN_NAME="memsearch"
INSTALL_DIR="$HOME/.copilot/installed-plugins/local/$PLUGIN_NAME"
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

# Create plugin directory
mkdir -p "$INSTALL_DIR"

# Copy plugin files (resolve symlinks via cp -L for portability)
cp -rL "$SCRIPT_DIR/hooks" "$INSTALL_DIR/"
cp -rL "$SCRIPT_DIR/scripts" "$INSTALL_DIR/"
cp -rL "$SCRIPT_DIR/prompts" "$INSTALL_DIR/"
cp -rL "$SCRIPT_DIR/skills" "$INSTALL_DIR/"

# Make hooks executable
chmod +x "$INSTALL_DIR"/hooks/*.sh
chmod +x "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

# Register in Copilot CLI config if not already present
CONFIG_FILE="$HOME/.copilot/config.json"
if [ -f "$CONFIG_FILE" ]; then
  if ! python3 -c "
import json, re, sys, os
with open('$CONFIG_FILE') as f:
    raw = f.read()
cleaned = re.sub(r'^\s*//.*$', '', raw, flags=re.MULTILINE)
cfg = json.loads(cleaned)
for p in cfg.get('installedPlugins', []):
    if p.get('name') == 'memsearch':
        sys.exit(0)  # already registered
home = os.path.expanduser('~')
version = '$(memsearch --version 2>/dev/null | sed "s/.*version //" || echo "0.0.0")'
cfg.setdefault('installedPlugins', []).append({
    'name': 'memsearch', 'marketplace': 'local', 'version': version,
    'installed_at': '$(date -u +%Y-%m-%dT%H:%M:%S.000Z)', 'enabled': True,
    'cache_path': f'{home}/.copilot/installed-plugins/local/memsearch'
})
with open('$CONFIG_FILE', 'w') as f:
    json.dump(cfg, f, indent=2)
print('Registered in Copilot CLI config', file=sys.stderr)
" 2>&1; then
    echo "Warning: Could not register in config.json (plugin will still work via hooks discovery)"
  fi
fi

# Clean up legacy install location
LEGACY_DIR="$HOME/.copilot/extensions/$PLUGIN_NAME"
if [ -d "$LEGACY_DIR" ]; then
  rm -rf "$LEGACY_DIR"
  echo "Removed legacy install at $LEGACY_DIR"
fi

echo ""
echo "✓ Installed to $INSTALL_DIR"
echo ""
echo "Verify: memsearch --version"
echo "The plugin will activate on your next Copilot CLI session."
