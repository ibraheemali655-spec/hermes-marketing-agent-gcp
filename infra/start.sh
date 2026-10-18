#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Start hermes-vm + wait for SSH + optionally start compose + CDP.
# Runs from the operator's WSL machine.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"  # cp config.example.sh config.sh

echo ">>> Starting $VM_NAME"
gcloud compute instances start "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --quiet
echo "    Started."

echo ">>> Waiting for SSH via IAP"
for i in $(seq 1 30); do
    if gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
         --tunnel-through-iap \
         --command="echo ok" \
         --ssh-flag="-o ConnectTimeout=15" \
         --ssh-flag="-o StrictHostKeyChecking=no" \
         --ssh-flag="-o UserKnownHostsFile=/dev/null" 2>/dev/null; then
        echo "    SSH up on attempt $i."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: SSH never came up"
        exit 1
    fi
    sleep 10
done

# Ensure native Hermes services + chrome-cdp are running.
echo ">>> Starting Hermes native services + chrome-cdp on VM"
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
    --tunnel-through-iap \
    --command='
sudo systemctl start hermes-gateway hermes-dashboard 2>/dev/null || true
sudo systemctl start chrome-cdp 2>/dev/null || true
echo ">>> Hermes started."
' \
    --ssh-flag="-o ConnectTimeout=15" \
    --ssh-flag="-o StrictHostKeyChecking=no" \
    --ssh-flag="-o UserKnownHostsFile=/dev/null" 2>&1 | tail -5

echo
echo "Connect:"
echo "  gcloud compute ssh $VM_NAME --tunnel-through-iap"
echo "  ssh -L 9119:localhost:9119 -L 9222:localhost:9222 $VM_NAME  (dashboard + CDP)"
