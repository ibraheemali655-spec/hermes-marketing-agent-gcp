#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Provision hermes-vm  
# ----------------------------------------------------------------------------
# Creates the VPC, IAP-only SSH firewall, and the e2-custom-6-20480 / 60 GB
# hermes-vm instance with the cloud-init startup script attached. All steps
# are idempotent (re-runs warn and skip existing resources).
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load deployment config.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"  # cp config.example.sh config.sh

# Idempotency helper: run `gcloud … describe` first.
exists_gcloud() {
    "$@" >/dev/null 2>&1
}

echo "==========================================================================="
echo "hermes-vm provisioning"
echo "    Project:  $PROJECT_ID"
echo "    Zone:     $ZONE"
echo "    Machine:  $MACHINE_TYPE"
echo "    BootDisk: ${BOOT_DISK_GB} GB pd-balanced"
echo "    Network:  $NETWORK_NAME"
echo "    SA:       $SA_EMAIL"
echo "==========================================================================="

# -----------------------------------------------------------------[1/4] VPC
echo ">>> [1/4] VPC $NETWORK_NAME"
if exists_gcloud gcloud compute networks describe "$NETWORK_NAME" --project="$PROJECT_ID"; then
    echo "    Network already exists. Skipping."
else
    gcloud compute networks create "$NETWORK_NAME" \
        --subnet-mode=auto \
        --project="$PROJECT_ID"
fi

# --------------------------------------------------------[2/4] Firewall rules
echo ">>> [2/4] IAP-only SSH firewall (no public port 22)"
FW_SSH="${NETWORK_NAME}-allow-iap-ssh"
if exists_gcloud gcloud compute firewall-rules describe "$FW_SSH" --project="$PROJECT_ID"; then
    echo "    SSH FW already exists. Skipping."
else
    gcloud compute firewall-rules create "$FW_SSH" \
        --network="$NETWORK_NAME" \
        --allow=tcp:22 \
        --target-tags=ssh-server \
        --source-ranges=35.235.240.0/20 \
        --project="$PROJECT_ID"
fi

FW_INT="${NETWORK_NAME}-allow-internal"
if exists_gcloud gcloud compute firewall-rules describe "$FW_INT" --project="$PROJECT_ID"; then
    echo "    Internal FW already exists. Skipping."
else
    gcloud compute firewall-rules create "$FW_INT" \
        --network="$NETWORK_NAME" \
        --allow=tcp,udp,icmp \
        --source-ranges=10.128.0.0/9 \
        --project="$PROJECT_ID"
fi

# CRD is **outbound-only** — no inbound firewall rule is needed for it.

# -----------------------------------------------------------[3/4] VM instance
echo ">>> [3/4] VM $VM_NAME"
STARTUP_SCRIPT="${SCRIPT_DIR}/startup.sh"
if [ ! -f "$STARTUP_SCRIPT" ]; then
    echo "ERROR: $STARTUP_SCRIPT not found. startup.sh must sit next to this script."
    exit 1
fi

if exists_gcloud gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID"; then
    echo "    VM already exists. Skipping creation. (Re-running startup script requires a reboot or"
    echo "    \`gcloud compute ssh $VM_NAME --tunnel-through-iap --command='sudo bash $STARTUP_SCRIPT'\`)"
else
    echo "    Creating VM (startup.sh runs on first boot)..."
    gcloud compute instances create "$VM_NAME" \
        --machine-type="$MACHINE_TYPE" \
        --zone="$ZONE" \
        --image-family=ubuntu-2404-lts-amd64 \
        --image-project=ubuntu-os-cloud \
        --boot-disk-size="${BOOT_DISK_GB}GB" \
        --boot-disk-type=pd-balanced \
        --service-account="$SA_EMAIL" \
        --scopes=cloud-platform \
        --tags=ssh-server \
        --network="$NETWORK_NAME" \
        --metadata=enable-oslogin=FALSE,vm-user="$VM_USER" \
        --metadata-from-file=startup-script="$STARTUP_SCRIPT" \
        --project="$PROJECT_ID"
fi

# --------------------------------------------------[4/4] Wait for SSH via IAP
echo ">>> [4/4] Waiting for SSH via IAP (cloud-init may still be installing packages)..."
# NOTE: the pure-Python IAP tunnel is slow to complete the SSH banner exchange
# (gcloud suggests installing NumPy to speed it up). A short ConnectTimeout
# produces false "timed out during banner exchange" failures even on a healthy
# VM, so use a generous ConnectTimeout here.
MAX_ATTEMPTS=20
ATTEMPT=0
SSH_OK=false
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    if gcloud compute ssh "$VM_NAME" \
            --zone="$ZONE" --project="$PROJECT_ID" \
            --tunnel-through-iap \
            --command="echo ok" \
            --ssh-flag="-o ConnectTimeout=90" \
            --ssh-flag="-o ServerAliveInterval=15" \
            --ssh-flag="-o StrictHostKeyChecking=no" \
            --ssh-flag="-o UserKnownHostsFile=/dev/null" 2>/dev/null; then
        SSH_OK=true
        echo "    SSH reachable on attempt $ATTEMPT."
        break
    fi
    if [ $((ATTEMPT % 6)) -eq 0 ]; then
        echo "    attempt $ATTEMPT/$MAX_ATTEMPTS..."
    fi
    sleep 10
done

if [ "$SSH_OK" = false ]; then
    echo "ERROR: SSH never came up via IAP after $MAX_ATTEMPTS attempts."
    echo "       Check serial console:"
    echo "       gcloud compute instances get-serial-port-output $VM_NAME --zone=$ZONE | tail -200"
    exit 1
fi

# ----------------------------------------------------------------[ Summary ]
echo "==========================================================================="
echo "SUCCESS: hermes-vm provisioned"
echo "    Connect:    gcloud compute ssh $VM_NAME --tunnel-through-iap"
echo "    Cloud-init: gcloud compute ssh $VM_NAME --tunnel-through-iap \\"
echo "                    --command='sudo tail -100 /var/log/hermes-startup.log'"
echo "    Status:     gcloud compute ssh $VM_NAME --tunnel-through-iap \\"
echo "                    --command='cloud-init status --wait'"
echo "    NOTE: VM has a public IP for OUTBOUND only (apt/CRD). The firewall"
echo "    blocks all inbound except IAP→22, so there is no public port 22."
echo "==========================================================================="
