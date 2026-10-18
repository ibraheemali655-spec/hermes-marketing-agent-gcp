#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deployment configuration. Copy to infra/config.sh (git-ignored) and fill in.
# Sourced by every script under infra/.
# ============================================================================

# GCP project / location
export PROJECT_ID="your-gcp-project-id"
export REGION="us-west1"
export ZONE="us-west1-b"

# VM: sized to mirror the desktop VM the agent ran on before
# (6 vCPU / 20 GB is enough for GNOME Flashback + Chrome + VS Code + the agent).
export VM_NAME="hermes-vm"
export MACHINE_TYPE="e2-custom-6-20480"
export BOOT_DISK_GB="60"

# Linux user that owns ~/.hermes on the VM
export VM_USER="hermes"

# Network
export NETWORK_NAME="hermes-net"

# Service account the VM and the waker run as
export SA_NAME="hermes-vm-sa"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Telegram chat the waker replies to (the bot token lives in Secret Manager)
export TG_CHAT_ID="000000000"

# Cloud Scheduler job, rewritten by vm/sync-next-wake.sh from jobs.json
export SCHEDULER_JOB_NAME="hermes-next-wake"

# Cloud Run waker service
export WAKER_SERVICE_NAME="hermes-waker"

# Minutes before a due cron job that the scheduler wakes the VM
export WAKE_LEAD_MIN="8"
