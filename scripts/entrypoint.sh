#!/usr/bin/env bash
# entrypoint.sh — initialize gog credentials then start openclaw gateway
set -euo pipefail

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

# ── Gmail monitor background loop ─────────────────────────────────────────────
if [[ -n "${GMAIL_MONITOR_ACCOUNT:-}" ]]; then
  MONITOR_SCRIPT="/app/scripts/gmail-monitor.sh"
  INTERVAL="${GMAIL_MONITOR_INTERVAL:-3600}"  # default: 1 hour

  (
    # Run once on startup (with a small delay to let gateway come up)
    sleep 30
    bash "$MONITOR_SCRIPT" || true
    # Then loop
    while sleep "$INTERVAL"; do
      bash "$MONITOR_SCRIPT" || true
    done
  ) &

  echo "[entrypoint] Gmail monitor scheduled every ${INTERVAL}s"
fi

# ── Start openclaw gateway (main process) ─────────────────────────────────────
exec node openclaw.mjs gateway --allow-unconfigured --port 3000 --bind custom
