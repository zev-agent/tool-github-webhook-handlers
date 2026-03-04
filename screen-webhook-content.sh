#!/bin/bash
# screen-webhook-content.sh — Quasar injection screening for webhook content
#
# Thin wrapper around the main screen-content.sh that adds webhook-specific
# context and logging. Falls back to the workspace screen-content.sh.
#
# Usage:
#   echo "$CONTENT" | screen-webhook-content.sh <source>
#   screen-webhook-content.sh <source> <content>
#
# Returns: exit 0 = CLEAN, exit 1 = SUSPICIOUS
# Outputs: JSON verdict from Quasar screening

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${WEBHOOK_LOG_DIR:-$HOME/.config/webhook-handlers/logs}"
mkdir -p "$LOG_DIR"

# Use the workspace screen-content.sh as the backend
SCREEN_BACKEND="${SCREEN_BACKEND:-$HOME/.openclaw/workspace/scripts/screen-content.sh}"

SOURCE="${1:-webhook-unknown}"
CONTENT="${2:-}"

if [ -z "$CONTENT" ]; then
  CONTENT=$(cat)
fi

# Skip screening for empty content
if [ -z "$CONTENT" ]; then
  echo '{"verdict": "CLEAN", "confidence": "high", "reason": "Empty content"}'
  exit 0
fi

# Skip screening for very short content (< 20 chars — unlikely to be injection)
if [ ${#CONTENT} -lt 20 ]; then
  echo '{"verdict": "CLEAN", "confidence": "high", "reason": "Content too short for injection"}'
  exit 0
fi

log_screen() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] SCREEN [$SOURCE]: $*" >> "$LOG_DIR/screening.log"
}

# Check if backend is available
if [ ! -x "$SCREEN_BACKEND" ]; then
  log_screen "WARN: Backend screen-content.sh not found at $SCREEN_BACKEND"
  # Fail open with warning — don't block webhook processing if screening is down
  echo '{"verdict": "CLEAN", "confidence": "low", "reason": "Screening backend unavailable — passed through"}'
  exit 0
fi

# Prepend webhook context to help the screening model
ENRICHED_CONTENT="[Webhook source: $SOURCE]
$CONTENT"

# Run the screening
RESULT=$(echo "$ENRICHED_CONTENT" | "$SCREEN_BACKEND" "github-webhook:$SOURCE" 2>/dev/null) || true
EXIT_CODE=${PIPESTATUS[1]:-$?}

# Parse and log result
VERDICT=$(echo "$RESULT" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('verdict', 'UNKNOWN'))
except:
    print('UNKNOWN')
" 2>/dev/null || echo "UNKNOWN")

log_screen "verdict=$VERDICT source=$SOURCE content_length=${#CONTENT}"

if [ "$VERDICT" = "SUSPICIOUS" ]; then
  log_screen "FLAGGED content from $SOURCE (${#CONTENT} chars): $(echo "$CONTENT" | head -c 200)"
  echo "$RESULT"
  exit 1
elif [ "$VERDICT" = "CLEAN" ]; then
  echo "$RESULT"
  exit 0
else
  # Unknown verdict — treat as suspicious out of caution
  log_screen "UNKNOWN verdict from screening — treating as suspicious"
  echo '{"verdict": "SUSPICIOUS", "confidence": "low", "reason": "Screening returned unparseable result"}'
  exit 1
fi
