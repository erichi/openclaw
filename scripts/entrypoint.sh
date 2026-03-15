#!/usr/bin/env bash
# entrypoint.sh — initialize gog credentials then start openclaw gateway
set -euo pipefail

STATE_DIR="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"

# ── gog credential setup ──────────────────────────────────────────────────────
# Credentials and token are injected as fly secrets (env vars).
# gog on Linux uses file-based keyring; set that up before any gog calls.

if [[ -n "${GOG_CREDENTIALS_JSON:-}" ]]; then
  GOG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gogcli"
  mkdir -p "$GOG_CONFIG_DIR"
  echo "$GOG_CREDENTIALS_JSON" > "$GOG_CONFIG_DIR/credentials.json"

  # Switch keyring to file backend (no system keychain in container)
  gog auth keyring file --no-input 2>/dev/null || true

  if [[ -n "${GOG_TOKEN_JSON:-}" ]]; then
    TOKEN_IMPORT=$(mktemp)
    echo "$GOG_TOKEN_JSON" > "$TOKEN_IMPORT"
    gog auth tokens import "$TOKEN_IMPORT" --no-input 2>/dev/null || true
    rm -f "$TOKEN_IMPORT"
  fi

  echo "[entrypoint] gog credentials configured for ${GMAIL_MONITOR_ACCOUNT:-unknown}"
fi

# ── Gmail cleanup cron job bootstrap ─────────────────────────────────────────
# Bootstrap the gmail-cleanup cron job if it isn't already in the store.
# Subsequent changes should be made via: openclaw cron edit gmail-cleanup
CRON_STORE="$STATE_DIR/cron/jobs.json"
JOB_EXISTS=$(python3 -c "
import json, sys
try:
  jobs = json.load(open('$CRON_STORE')).get('jobs', [])
  print('yes' if any(j.get('id') == 'gmail-cleanup' for j in jobs) else 'no')
except: print('no')
" 2>/dev/null || echo "no")
if [[ "$JOB_EXISTS" == "no" ]] && [[ -n "${GMAIL_MONITOR_ACCOUNT:-}" ]]; then
  mkdir -p "$(dirname "$CRON_STORE")"
  NOW_MS=$(date +%s)000
  python3 - <<PYEOF > "$CRON_STORE"
import json, sys
print(json.dumps({
  "version": 1,
  "jobs": [{
    "id": "gmail-cleanup",
    "name": "Gmail Inbox Cleanup",
    "description": "Archive unwanted inbox emails and report via Telegram",
    "enabled": True,
    "createdAtMs": $NOW_MS,
    "updatedAtMs": $NOW_MS,
    "schedule": { "kind": "every", "everyMs": 3600000 },
    "sessionTarget": "isolated",
    "wakeMode": "now",
    "payload": {
      "kind": "agentTurn",
      "lightContext": True,
      "message": "Run gmail inbox cleanup. Use the gog skill: search all 5 categories (newsletters, mailing lists, social, automated updates, no-reply senders), archive matches, and report a summary. Never archive starred or important emails."
    },
    "delivery": {
      "mode": "announce",
      "channel": "telegram",
      "to": "${GMAIL_MONITOR_TELEGRAM_TARGET:-}"
    },
    "failureAlert": {
      "channel": "telegram",
      "to": "${GMAIL_MONITOR_TELEGRAM_TARGET:-}",
      "after": 3,
      "cooldownMs": 3600000
    },
    "state": {}
  }]
}, indent=2))
PYEOF
  echo "[entrypoint] Gmail cleanup cron job bootstrapped at $CRON_STORE"
fi

# ── Start openclaw gateway (main process) ─────────────────────────────────────
exec node openclaw.mjs gateway --allow-unconfigured --port 3000 --bind custom
