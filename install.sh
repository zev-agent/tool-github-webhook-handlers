#!/bin/bash
# install.sh — Deploy webhook handler scripts to OpenClaw workspace
# Run after PR is approved and merged.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.openclaw/workspace/scripts"

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Target directory $TARGET_DIR does not exist" >&2
  exit 1
fi

echo "Installing webhook handler scripts to $TARGET_DIR..."

cp "$SCRIPT_DIR/handle-github-webhook.sh" "$TARGET_DIR/handle-github-webhook.sh"
cp "$SCRIPT_DIR/screen-webhook-content.sh" "$TARGET_DIR/screen-webhook-content.sh"

chmod +x "$TARGET_DIR/handle-github-webhook.sh"
chmod +x "$TARGET_DIR/screen-webhook-content.sh"

echo "Installed:"
echo "  $TARGET_DIR/handle-github-webhook.sh"
echo "  $TARGET_DIR/screen-webhook-content.sh"
echo ""
echo "Done. Scripts are ready to receive webhook events."
