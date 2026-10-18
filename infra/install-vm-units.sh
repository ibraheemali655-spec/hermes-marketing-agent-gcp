#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Install the power-management layer onto the VM:
#   - copies vm/{idle-watchdog.sh,sync-next-wake.sh,nextwake.py,hermes-ready-notify.sh}
#   - writes ~/.hermes-gcp.env (non-secret settings the on-VM scripts read)
#   - renders units/* for $VM_USER and enables them
#
# Runs from the operator's machine. Idempotent.
#
# HOLD MODE (default): does NOT write ~/.hermes-waker-url, so nothing touches
# the Telegram webhook (useful while another gateway still owns the bot).
# At cutover, pass the waker URL + webhook secret printed by waker/deploy.sh:
#   HERMES_WAKER_URL=https://... HERMES_WEBHOOK_SECRET=hw-... ./install-vm-units.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"  # cp config.example.sh config.sh

SSH=(gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap
     --ssh-flag=-o\ ConnectTimeout=90 --ssh-flag=-o\ StrictHostKeyChecking=no
     --ssh-flag=-o\ UserKnownHostsFile=/dev/null)
SCP=(gcloud compute scp --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap
     --scp-flag=-o\ ConnectTimeout=90)

VM_HOME="/home/${VM_USER}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo ">>> [1/5] Rendering units for ${VM_USER}"
mkdir -p "$STAGE/units"
for f in "$SCRIPT_DIR"/units/*; do
    sed -e "s#__VM_USER__#${VM_USER}#g" -e "s#__VM_HOME__#${VM_HOME}#g" "$f" > "$STAGE/units/$(basename "$f")"
done
cat > "$STAGE/hermes-gcp.env" <<EOF
PROJECT_ID=${PROJECT_ID}
REGION=${REGION}
SCHEDULER_JOB_NAME=${SCHEDULER_JOB_NAME}
WAKE_LEAD_MIN=${WAKE_LEAD_MIN}
TG_CHAT_ID=${TG_CHAT_ID}
EOF

echo ">>> [2/5] Copying on-VM scripts"
"${SCP[@]}" "$SCRIPT_DIR"/vm/* "$STAGE/hermes-gcp.env" "$VM_NAME":~/
"${SSH[@]}" --command='mv ~/hermes-gcp.env ~/.hermes-gcp.env && chmod 600 ~/.hermes-gcp.env'

echo ">>> [3/5] Copying systemd units"
"${SCP[@]}" --recurse "$STAGE/units" "$VM_NAME":~/hermes-units

echo ">>> [4/5] (optional) waker re-arm wiring"
if [ -n "${HERMES_WAKER_URL:-}" ]; then
    "${SSH[@]}" --command="printf 'WAKER_URL=%s\nWEBHOOK_SECRET=%s\n' '${HERMES_WAKER_URL}' '${HERMES_WEBHOOK_SECRET:-}' > ~/.hermes-waker-url && chmod 600 ~/.hermes-waker-url && echo 'waker-url written (cutover wiring active)'"
else
    "${SSH[@]}" --command="rm -f ~/.hermes-waker-url; echo 'HOLD mode: idle-watchdog will NOT touch the Telegram webhook'"
fi

echo ">>> [5/5] Installing + enabling units"
"${SSH[@]}" --command='
set -e
chmod +x ~/idle-watchdog.sh ~/sync-next-wake.sh ~/nextwake.py ~/hermes-ready-notify.sh
sudo cp ~/hermes-units/* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now idle-watchdog.timer sync-next-wake.path
# Webhook lifecycle only once the waker is wired: when awake the gateway long-polls,
# so release the webhook on boot and re-arm it on every shutdown.
if [ -f ~/.hermes-waker-url ]; then
    sudo systemctl enable --now hermes-webhook-release.service hermes-webhook-arm.service hermes-ready-notify.service
    echo "webhook lifecycle + ready-notify enabled"
fi
systemctl is-active idle-watchdog.timer sync-next-wake.path
'
echo "==========================================================================="
echo "Power management installed on $VM_NAME."
echo "  idle-watchdog.timer  every 5 min; stops the VM after 60 min idle"
echo "  sync-next-wake.path  rewrites Cloud Scheduler when ~/.hermes/cron/jobs.json changes"
echo "==========================================================================="
