#!/bin/bash
# handle-github-webhook.sh — Route incoming GitHub webhook events
#
# Usage:
#   echo "$PAYLOAD" | handle-github-webhook.sh "$EVENT_TYPE"
#   handle-github-webhook.sh "$EVENT_TYPE" "$PAYLOAD_FILE"
#
# Expects:
#   - OPENCLAW binary at $OPENCLAW (default: ~/.nvm/versions/node/v25.5.0/bin/openclaw)
#   - channels.env sourced (MORDECAI_CHANNEL, DONUT_CHANNEL, ZEV_COMMANDS_CHANNEL, QUASAR_CHANNEL)
#   - screen-webhook-content.sh in same directory
#   - queue.sh accessible at QUEUE_SCRIPT (default: ~/.openclaw/workspace/scripts/queue.sh)
#   - triage-issue.sh accessible at TRIAGE_SCRIPT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${WEBHOOK_LOG_DIR:-$HOME/.config/webhook-handlers/logs}"
mkdir -p "$LOG_DIR"

OPENCLAW="${OPENCLAW:-$HOME/.nvm/versions/node/v25.5.0/bin/openclaw}"
QUEUE_SCRIPT="${QUEUE_SCRIPT:-$HOME/.openclaw/workspace/scripts/queue.sh}"
TRIAGE_SCRIPT="${TRIAGE_SCRIPT:-$HOME/.openclaw/workspace/scripts/triage-issue.sh}"
SCREEN_SCRIPT="${SCREEN_SCRIPT:-$SCRIPT_DIR/screen-webhook-content.sh}"

# Source channels config
CHANNELS_ENV="${CHANNELS_ENV:-$HOME/.openclaw/workspace/config/channels.env}"
if [ -f "$CHANNELS_ENV" ]; then
  source "$CHANNELS_ENV"
fi

# --- Input ---

EVENT_TYPE="${1:-}"
PAYLOAD_FILE="${2:-}"

if [ -z "$EVENT_TYPE" ]; then
  echo "Usage: $0 <event_type> [payload_file]" >&2
  exit 1
fi

if [ -n "$PAYLOAD_FILE" ] && [ -f "$PAYLOAD_FILE" ]; then
  PAYLOAD=$(cat "$PAYLOAD_FILE")
else
  PAYLOAD=$(cat)
fi

if [ -z "$PAYLOAD" ]; then
  echo "Error: empty payload" >&2
  exit 1
fi

# --- Helpers ---

log() {
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$ts] $EVENT_TYPE: $*" >> "$LOG_DIR/webhook.log"
}

notify() {
  local channel="$1" message="$2"
  $OPENCLAW message send --channel discord --target "$channel" --message "$message" 2>/dev/null || true
}

# Extract a field from the JSON payload
jq_field() {
  echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
keys = '$1'.split('.')
for k in keys:
    if isinstance(d, dict):
        d = d.get(k, '')
    else:
        d = ''
        break
print(d if d is not None else '')
" 2>/dev/null
}

# Screen content via Quasar before processing
screen_content() {
  local source="$1" content="$2"
  if [ -x "$SCREEN_SCRIPT" ]; then
    echo "$content" | "$SCREEN_SCRIPT" "$source" 2>/dev/null
    return $?
  fi
  # If screen script unavailable, pass through with warning
  log "WARN: screen script not available, skipping injection check"
  return 0
}

# --- Parse common fields ---

ACTION=$(jq_field "action")
REPO_FULL=$(jq_field "repository.full_name")

log "Received: action=$ACTION repo=$REPO_FULL"

# ============================================================
# Event routing
# ============================================================

case "$EVENT_TYPE" in

  # ----------------------------------------------------------
  # pull_request events
  # ----------------------------------------------------------
  pull_request)
    PR_NUMBER=$(jq_field "number")
    PR_TITLE=$(jq_field "pull_request.title")
    PR_URL=$(jq_field "pull_request.html_url")
    PR_USER=$(jq_field "pull_request.user.login")
    MERGED=$(jq_field "pull_request.merged")
    HEAD_BRANCH=$(jq_field "pull_request.head.ref")

    case "$ACTION" in
      opened|synchronize)
        log "PR #$PR_NUMBER $ACTION by $PR_USER: $PR_TITLE"
        notify "${MORDECAI_CHANNEL:-}" ":octocat: **PR #$PR_NUMBER $ACTION** ($REPO_FULL)
**$PR_TITLE** by \`$PR_USER\`
$PR_URL"
        ;;

      closed)
        if [ "$MERGED" = "True" ] || [ "$MERGED" = "true" ]; then
          log "PR #$PR_NUMBER merged: $PR_TITLE"
          notify "${MORDECAI_CHANNEL:-}" ":white_check_mark: **PR #$PR_NUMBER merged** ($REPO_FULL)
**$PR_TITLE** by \`$PR_USER\`
$PR_URL"

          # Update queue.json if this PR is tracked
          if [ -x "$QUEUE_SCRIPT" ]; then
            # Find tracked issue by PR number
            TRACKED_ISSUE=$(python3 -c "
import json
with open('$HOME/.config/mordecai-watcher/queue.json') as f:
    queue = json.load(f)
for item in queue:
    if str(item.get('pr', '')) == '$PR_NUMBER':
        print(item['issue'])
        break
" 2>/dev/null || true)

            if [ -n "$TRACKED_ISSUE" ]; then
              "$QUEUE_SCRIPT" done "$TRACKED_ISSUE"
              log "Queue: marked issue #$TRACKED_ISSUE as merged (PR #$PR_NUMBER)"
              notify "${ZEV_COMMANDS_CHANNEL:-}" ":package: Queue updated: issue #$TRACKED_ISSUE marked merged via PR #$PR_NUMBER"
            fi
          fi
        else
          log "PR #$PR_NUMBER closed without merge"
        fi
        ;;

      *)
        log "Unhandled pull_request action: $ACTION"
        ;;
    esac
    ;;

  # ----------------------------------------------------------
  # pull_request_review events
  # ----------------------------------------------------------
  pull_request_review)
    PR_NUMBER=$(jq_field "pull_request.number")
    PR_TITLE=$(jq_field "pull_request.title")
    PR_URL=$(jq_field "pull_request.html_url")
    REVIEW_STATE=$(jq_field "review.state")
    REVIEWER=$(jq_field "review.user.login")
    REVIEW_BODY=$(jq_field "review.body")

    case "$REVIEW_STATE" in
      changes_requested)
        log "PR #$PR_NUMBER: changes requested by $REVIEWER"

        # Screen review body
        if screen_content "github-review:$REVIEWER" "$REVIEW_BODY"; then
          notify "${MORDECAI_CHANNEL:-}" ":pencil: **Changes requested** on PR #$PR_NUMBER ($REPO_FULL)
**$PR_TITLE** — reviewer: \`$REVIEWER\`
$PR_URL

Mordecai: address the review comments and push fixes."
        else
          log "SUSPICIOUS review body from $REVIEWER on PR #$PR_NUMBER — flagged"
          notify "${QUASAR_CHANNEL:-}" ":warning: **Injection screen FLAGGED** review on PR #$PR_NUMBER by \`$REVIEWER\` ($REPO_FULL). Review body held for manual inspection."
        fi
        ;;

      approved)
        log "PR #$PR_NUMBER: approved by $REVIEWER"
        notify "${MORDECAI_CHANNEL:-}" ":white_check_mark: **PR #$PR_NUMBER approved** by \`$REVIEWER\` ($REPO_FULL)
**$PR_TITLE**
$PR_URL"
        ;;

      *)
        log "Unhandled review state: $REVIEW_STATE"
        ;;
    esac
    ;;

  # ----------------------------------------------------------
  # issue_comment events
  # ----------------------------------------------------------
  issue_comment)
    COMMENT_BODY=$(jq_field "comment.body")
    COMMENT_USER=$(jq_field "comment.user.login")
    COMMENT_URL=$(jq_field "comment.html_url")
    ISSUE_NUMBER=$(jq_field "issue.number")
    ISSUE_TITLE=$(jq_field "issue.title")
    IS_PR=$(jq_field "issue.pull_request.url")

    case "$ACTION" in
      created)
        log "Comment on #$ISSUE_NUMBER by $COMMENT_USER"

        # Screen comment content
        if ! screen_content "github-comment:$COMMENT_USER" "$COMMENT_BODY"; then
          log "SUSPICIOUS comment from $COMMENT_USER on #$ISSUE_NUMBER — held"
          notify "${QUASAR_CHANNEL:-}" ":warning: **Injection screen FLAGGED** comment on #$ISSUE_NUMBER by \`$COMMENT_USER\` ($REPO_FULL).
$COMMENT_URL
Content held for manual review."
          exit 0
        fi

        if [ -n "$IS_PR" ]; then
          # Comment on a PR — route to Mordecai if actionable
          log "PR comment on #$ISSUE_NUMBER — routing to Mordecai"
          notify "${MORDECAI_CHANNEL:-}" ":speech_balloon: **New comment on PR #$ISSUE_NUMBER** ($REPO_FULL)
**$ISSUE_TITLE** — by \`$COMMENT_USER\`
$COMMENT_URL

> $(echo "$COMMENT_BODY" | head -c 300)"
        else
          # Comment on an issue — surface to Zev for triage
          log "Issue comment on #$ISSUE_NUMBER — surfacing to Zev"
          notify "${ZEV_COMMANDS_CHANNEL:-}" ":speech_balloon: **New comment on issue #$ISSUE_NUMBER** ($REPO_FULL)
**$ISSUE_TITLE** — by \`$COMMENT_USER\`
$COMMENT_URL

> $(echo "$COMMENT_BODY" | head -c 300)"
        fi
        ;;

      *)
        log "Unhandled issue_comment action: $ACTION"
        ;;
    esac
    ;;

  # ----------------------------------------------------------
  # issues events
  # ----------------------------------------------------------
  issues)
    ISSUE_NUMBER=$(jq_field "issue.number")
    ISSUE_TITLE=$(jq_field "issue.title")
    ISSUE_URL=$(jq_field "issue.html_url")
    ISSUE_BODY=$(jq_field "issue.body")
    ISSUE_USER=$(jq_field "issue.user.login")
    LABELS=$(echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
labels = [l['name'] for l in d.get('issue', {}).get('labels', [])]
print(','.join(labels))
" 2>/dev/null || true)

    case "$ACTION" in
      opened)
        log "Issue #$ISSUE_NUMBER opened by $ISSUE_USER: $ISSUE_TITLE"

        # Screen issue content
        if ! screen_content "github-issue:$ISSUE_USER" "$ISSUE_BODY"; then
          log "SUSPICIOUS issue body from $ISSUE_USER on #$ISSUE_NUMBER — held"
          notify "${QUASAR_CHANNEL:-}" ":warning: **Injection screen FLAGGED** new issue #$ISSUE_NUMBER by \`$ISSUE_USER\` ($REPO_FULL).
$ISSUE_URL
Content held for manual review."
          exit 0
        fi

        # Add to triage queue
        notify "${ZEV_COMMANDS_CHANNEL:-}" ":new: **New issue #$ISSUE_NUMBER** ($REPO_FULL)
**$ISSUE_TITLE** by \`$ISSUE_USER\`
$ISSUE_URL

> $(echo "$ISSUE_BODY" | head -c 300)

Queued for triage."

        # Run triage if script available
        if [ -x "$TRIAGE_SCRIPT" ]; then
          TRIAGE_RESULT=$("$TRIAGE_SCRIPT" "$REPO_FULL" "$ISSUE_NUMBER" 2>/dev/null || true)
          if [ -n "$TRIAGE_RESULT" ]; then
            log "Triage result for #$ISSUE_NUMBER: $TRIAGE_RESULT"
          fi
        fi
        ;;

      labeled)
        LABEL_NAME=$(jq_field "label.name")
        log "Issue #$ISSUE_NUMBER labeled: $LABEL_NAME"

        if [ "$LABEL_NAME" = "design-review" ]; then
          log "Design review requested for #$ISSUE_NUMBER — notifying Donut"
          notify "${DONUT_CHANNEL:-}" ":art: **Design review requested** — issue #$ISSUE_NUMBER ($REPO_FULL)
**$ISSUE_TITLE**
$ISSUE_URL

Donut: please review the UX/design implications and share your take."
        fi
        ;;

      *)
        log "Unhandled issues action: $ACTION"
        ;;
    esac
    ;;

  # ----------------------------------------------------------
  # Unknown event type
  # ----------------------------------------------------------
  *)
    log "Unhandled event type: $EVENT_TYPE (action=$ACTION)"
    ;;
esac
