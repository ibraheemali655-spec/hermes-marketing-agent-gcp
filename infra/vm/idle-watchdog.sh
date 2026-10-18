#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# idle-watchdog.sh — runs ON hermes-vm every 5 min via systemd timer.
# If the VM has been idle for 60 min, sync the scheduler, re-arm the
# Telegram webhook, and shut down.
#
# Idle = all of:
#   - no login sessions (who)
#   - no active CRD client session
#   - no Hermes cron job running (no .tick.lock held)
#   - no Hermes session modified in last 60 min
#
# See docs/architecture.md.
# ============================================================================

IDLE_THRESHOLD_MIN=60
MARKER_FILE="/tmp/hermes-idle-since"
STATE_DIR="$HOME/.hermes"

# --- detect idle conditions ---
is_idle() {
    # 1) Active login sessions? (interactive SSH/console show in `who`)
    if [ -n "$(who 2>/dev/null)" ]; then
        echo "not idle: login sessions active"
        return 1
    fi

    # 2) Active CRD session? (CRD creates /tmp/crd-session-* while connected)
    if ls /tmp/crd-session-* 2>/dev/null | grep -q .; then
        echo "not idle: CRD session active"
        return 1
    fi
    # Alternative check: chrome-remote-desktop session process
    if pgrep -f 'chrome-remote-desktop host' >/dev/null 2>&1 && \
       ! pgrep -f 'remoting_me2me_host' >/dev/null 2>&1; then
        : # host running but no client connected — still consider idle
    elif pgrep -f 'remoting_me2me_host' >/dev/null 2>&1; then
        echo "not idle: CRD client connected"
        return 1
    fi

    # 3) Hermes cron job running? (.tick.lock held = job in progress)
    if [ -f "$STATE_DIR/cron/.tick.lock" ]; then
        if flock -n 9 9<"$STATE_DIR/cron/.tick.lock" 2>/dev/null; then
            : # lock is not held — no job running
        else
            echo "not idle: Hermes cron job in progress"
            return 1
        fi
    fi

    # 4) Hermes session activity? (~/.hermes/sessions is a DIRECTORY — check the
    #    newest file inside it, not the dir's own mtime).
    if [ -d "$STATE_DIR/sessions" ]; then
        cutoff=$(( $(date +%s) - (IDLE_THRESHOLD_MIN * 60) ))
        newest=$(find "$STATE_DIR/sessions" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
        if [ -n "$newest" ] && [ "$newest" -gt "$cutoff" ]; then
            echo "not idle: Hermes session modified recently"
            return 1
        fi
    fi

    return 0
}

if is_idle; then
    if [ ! -f "$MARKER_FILE" ]; then
        echo "idle detected — starting timer ($(date -u +%H:%M:%S))"
        date +%s > "$MARKER_FILE"
        exit 0
    fi

    IDLE_START=$(cat "$MARKER_FILE")
    NOW=$(date +%s)
    ELAPSED_MIN=$(( (NOW - IDLE_START) / 60 ))

    if [ "$ELAPSED_MIN" -lt "$IDLE_THRESHOLD_MIN" ]; then
        echo "still idle, ${ELAPSED_MIN}/${IDLE_THRESHOLD_MIN} min"
        exit 0
    fi

    echo ">>> IDLE for ${ELAPSED_MIN} min — shutting down"

    # 1) Sync next-wake scheduler (so the VM wakes for the next cron job)
    if [ -f "$HOME/sync-next-wake.sh" ]; then
        bash "$HOME/sync-next-wake.sh" || echo "    WARN: sync-next-wake failed"
    fi

    # 2) Re-arm Telegram webhook → waker (so Telegram messages wake the VM)
    # Read bot token from .env (same as Hermes uses)
    if [ -f "$STATE_DIR/.env" ]; then
        BOT_TOKEN=$(grep -oP '(?<=TELEGRAM_BOT_TOKEN=).+' "$STATE_DIR/.env" 2>/dev/null || true)
        if [ -n "$BOT_TOKEN" ]; then
            # Get waker URL from deploy metadata or config
            WAKER_URL=$(grep -oP '(?<=WAKER_URL=).+' "$HOME/.hermes-waker-url" 2>/dev/null || true)
            WEBHOOK_SECRET=$(grep -oP '(?<=WEBHOOK_SECRET=).+' "$HOME/.hermes-waker-url" 2>/dev/null || true)
            if [ -n "$WAKER_URL" ]; then
                curl -sS "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
                    -d "url=${WAKER_URL}/telegram" \
                    -d "secret_token=${WEBHOOK_SECRET}" \
                    | python3 -m json.tool 2>/dev/null || echo "    WARN: setWebhook failed"
                echo "    Webhook re-armed → ${WAKER_URL}/telegram"
            fi
        fi
    fi

    # 3) Shutdown
    rm -f "$MARKER_FILE"
    echo ">>> Executing: shutdown -h now"
    sudo shutdown -h now
else
    # Not idle — reset the marker
    rm -f "$MARKER_FILE"
fi
