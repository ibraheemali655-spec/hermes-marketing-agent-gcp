#!/usr/bin/env bash
# Runs on boot (via hermes-ready-notify.service). Waits for the native Hermes
# gateway service to be active, plus a short grace for it to start long-polling Telegram,
# then pings the owner so they know it's safe to (re)send their message.
set -uo pipefail

# shellcheck disable=SC1091
source "$HOME/.hermes-gcp.env"   # TG_CHAT_ID

T=$(grep -oP '(?<=TELEGRAM_BOT_TOKEN=).+' "$HOME/.hermes/.env" 2>/dev/null | tr -d '\r\n')
[ -z "$T" ] && exit 0

# Wait up to ~150s for the gateway service to reach active state.
for _ in $(seq 1 50); do
    [ "$(systemctl is-active hermes-gateway 2>/dev/null)" = "active" ] && break
    sleep 3
done
# Grace for the gateway to delete the webhook and start its getUpdates loop.
sleep 12

curl -fsS "https://api.telegram.org/bot${T}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=✅ Hermes is up and ready — go ahead (resend your message)." \
    >/dev/null 2>&1 && logger "hermes-ready-notify: sent ready ping"
