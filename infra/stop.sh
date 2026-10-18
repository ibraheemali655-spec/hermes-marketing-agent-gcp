#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Gracefully stop hermes-vm: sync scheduler, re-arm webhook, then shut down.
# Runs from the operator's WSL machine.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"  # cp config.example.sh config.sh

echo ">>> Running idle-watchdog pre-shutdown logic on $VM_NAME"
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
    --tunnel-through-iap \
    --command='bash ~/sync-next-wake.sh || true' \
    --ssh-flag="-o ConnectTimeout=20" \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --ssh-flag="-o UserKnownHostsFile=/dev/null" 2>&1 | tail -5

echo ">>> Stopping $VM_NAME"
gcloud compute instances stop "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet
echo "    Stopped. Scheduler and webhook are armed for wake-on-demand."
