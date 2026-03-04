# tool-github-webhook-handlers

GitHub webhook handler scripts for OpenClaw. Routes `pull_request`, `pull_request_review`, `issue_comment`, and `issues` events.

**Built by:** Signet (ops/infra agent)
**Date:** 2026-03-03

## Scripts

### `handle-github-webhook.sh`

Main router. Receives a GitHub webhook payload and routes it based on event type and action.

```bash
echo "$PAYLOAD" | ./handle-github-webhook.sh "pull_request"
./handle-github-webhook.sh "issues" /path/to/payload.json
```

### `screen-webhook-content.sh`

Quasar injection screening wrapper. Screens webhook content (issue bodies, comments, review text) before processing.

```bash
echo "$CONTENT" | ./screen-webhook-content.sh "github-comment:username"
```

## Events Handled

| Event | Action | Behavior |
|-------|--------|----------|
| `pull_request` | `opened`, `synchronize` | Log to #mordecai-logs |
| `pull_request` | `closed` (merged) | Update queue.json if tracked PR |
| `pull_request_review` | `changes_requested` | Screen + notify Mordecai |
| `pull_request_review` | `approved` | Log approval |
| `issue_comment` | `created` (on PR) | Screen + route to Mordecai |
| `issue_comment` | `created` (on issue) | Screen + surface to Zev |
| `issues` | `opened` | Screen + add to triage queue |
| `issues` | `labeled` (`design-review`) | Notify Donut |

## Requirements

- `openclaw` CLI (for Discord notifications)
- `channels.env` with channel IDs (`MORDECAI_CHANNEL`, `DONUT_CHANNEL`, `ZEV_COMMANDS_CHANNEL`, `QUASAR_CHANNEL`)
- `screen-content.sh` (workspace script — Quasar's injection screener)
- `queue.sh` (workspace script — Mordecai's task queue)
- `triage-issue.sh` (workspace script — issue triage)
- `python3` (for JSON parsing)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENCLAW` | `~/.nvm/.../openclaw` | Path to openclaw binary |
| `CHANNELS_ENV` | `~/.openclaw/workspace/config/channels.env` | Channel IDs config |
| `QUEUE_SCRIPT` | `~/.openclaw/workspace/scripts/queue.sh` | Queue management script |
| `TRIAGE_SCRIPT` | `~/.openclaw/workspace/scripts/triage-issue.sh` | Triage script |
| `SCREEN_SCRIPT` | `./screen-webhook-content.sh` | Screening script |
| `SCREEN_BACKEND` | `~/.openclaw/workspace/scripts/screen-content.sh` | Backend screener |
| `WEBHOOK_LOG_DIR` | `~/.config/webhook-handlers/logs` | Log directory |

## Deployment

After PR approval, install to workspace:

```bash
./install.sh
```

This copies scripts to `~/.openclaw/workspace/scripts/` and sets permissions.

## Integration with github-webhook-proxy

The proxy (`~/.local/bin/github-webhook-proxy`) forwards payloads to OpenClaw's hook endpoint. To wire these scripts in, the proxy or an OpenClaw hook pack needs to call `handle-github-webhook.sh` with the event type header and payload body.

The proxy env config (`~/.config/github-webhook-proxy/env`) currently forwards to:
```
OPENCLAW_HOOK_URL=http://127.0.0.1:18789/hooks/agent
```

An OpenClaw hook pack or a systemd service that reads from the hooks endpoint and calls the handler script is the recommended integration path.
