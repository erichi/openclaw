#!/usr/bin/env bash
# gmail-monitor.sh — archive unwanted Gmail and report via Telegram
#
# Setup (once):
#   gog auth credentials /path/to/client_secret.json
#   gog auth add you@gmail.com --services gmail
#   cp scripts/gmail-monitor.env.example ~/.openclaw/gmail-monitor.env
#   # edit ~/.openclaw/gmail-monitor.env with your values
#
# Run manually:
#   bash scripts/gmail-monitor.sh
#
# Run on a schedule (cron, every hour):
#   0 * * * * bash /path/to/openclaw/scripts/gmail-monitor.sh >> /tmp/gmail-monitor.log 2>&1

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

# Load optional local config file (useful for local dev)
ENV_FILE="${GMAIL_MONITOR_ENV:-$HOME/.openclaw/gmail-monitor.env}"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

# Required env vars — set via fly secrets (server) or ~/.openclaw/gmail-monitor.env (local)
# GOG_ACCOUNT maps to GMAIL_MONITOR_ACCOUNT for clarity in fly secrets
GOG_ACCOUNT="${GOG_ACCOUNT:-${GMAIL_MONITOR_ACCOUNT:-}}"
OPENCLAW_TELEGRAM_TARGET="${OPENCLAW_TELEGRAM_TARGET:-${GMAIL_MONITOR_TELEGRAM_TARGET:-}}"

: "${GOG_ACCOUNT:?Set GOG_ACCOUNT or GMAIL_MONITOR_ACCOUNT}"
: "${OPENCLAW_TELEGRAM_TARGET:?Set OPENCLAW_TELEGRAM_TARGET or GMAIL_MONITOR_TELEGRAM_TARGET}"

# Optional
DRY_RUN="${DRY_RUN:-0}"
MAX_PER_QUERY="${MAX_PER_QUERY:-200}"
REPORT_ONLY_IF_FOUND="${REPORT_ONLY_IF_FOUND:-1}"

export GOG_ACCOUNT

# ── Unwanted email rules ───────────────────────────────────────────────────────
# Each entry: "Label|gmail search query"
# Gmail search syntax: https://support.google.com/mail/answer/7190
RULES=(
  "Newsletters|in:inbox category:promotions unsubscribe"
  "Mailing lists|in:inbox list:* -is:important"
  "Social notifications|in:inbox category:social -is:important"
  "Automated updates|in:inbox category:updates -is:starred -is:important"
  "No-reply|in:inbox from:no-reply OR from:noreply -is:starred -is:important"
)

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

send_telegram() {
  local msg="$1"
  log "Sending Telegram report to $OPENCLAW_TELEGRAM_TARGET..."
  # openclaw is available in the container as a symlink to openclaw.mjs
  # It connects to the local gateway on port 3000
  if openclaw message send --to "$OPENCLAW_TELEGRAM_TARGET" --body-file - <<< "$msg" 2>/dev/null; then
    log "Report sent."
  elif openclaw message send --to "$OPENCLAW_TELEGRAM_TARGET" --message "$msg" 2>/dev/null; then
    log "Report sent."
  else
    log "WARNING: failed to send Telegram report; printing to stdout instead."
    echo "$msg"
  fi
}

archive_messages() {
  local ids=("$@")
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "  [dry-run] would archive ${#ids[@]} messages: ${ids[*]:0:5}..."
  else
    gog gmail archive "${ids[@]}" --force --no-input 2>&1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

log "Starting Gmail monitor for $GOG_ACCOUNT"

total_archived=0
report_lines=()

for rule in "${RULES[@]}"; do
  label="${rule%%|*}"
  query="${rule#*|}"

  log "Checking: $label ($query)"

  # Search for matching messages
  raw=$(gog gmail messages search "$query" \
    --max "$MAX_PER_QUERY" \
    --json --no-input 2>/dev/null || true)

  if [[ -z "$raw" ]] || [[ "$raw" == "null" ]] || [[ "$raw" == "[]" ]]; then
    log "  No messages found."
    continue
  fi

  # Extract message IDs
  mapfile -t ids < <(echo "$raw" | python3 -c "
import sys, json
msgs = json.load(sys.stdin)
if isinstance(msgs, dict) and 'messages' in msgs:
    msgs = msgs['messages']
for m in (msgs if isinstance(msgs, list) else []):
    mid = m.get('id') or m.get('messageId') or m.get('message_id', '')
    if mid:
        print(mid)
" 2>/dev/null)

  count="${#ids[@]}"
  if [[ "$count" -eq 0 ]]; then
    log "  No message IDs extracted."
    continue
  fi

  log "  Found $count messages — archiving..."
  archive_messages "${ids[@]}"
  total_archived=$((total_archived + count))
  report_lines+=("• $label: $count archived")
done

log "Done. Total archived: $total_archived"

# ── Send report ───────────────────────────────────────────────────────────────

if [[ "$total_archived" -eq 0 && "${REPORT_ONLY_IF_FOUND}" == "1" ]]; then
  log "Nothing to report (inbox clean)."
  exit 0
fi

timestamp=$(date '+%Y-%m-%d %H:%M')
if [[ "$total_archived" -gt 0 ]]; then
  msg="📬 Gmail cleanup — $timestamp
Account: $GOG_ACCOUNT
Total archived: $total_archived

$(printf '%s\n' "${report_lines[@]}")"
else
  msg="✅ Gmail inbox clean — $timestamp
Account: $GOG_ACCOUNT
Nothing to archive."
fi

send_telegram "$msg"
