#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# sync-next-wake.sh: runs ON the VM.
# Points the Cloud Scheduler job at WAKE_LEAD_MIN minutes before the next due
# Hermes cron job, computed from ~/.hermes/cron/jobs.json by nextwake.py.
#
# Triggered by sync-next-wake.path whenever jobs.json changes, and by
# idle-watchdog.sh right before shutdown.
#
# Requires: gcloud (the VM's service account has roles/cloudscheduler.admin)
# and ~/.hermes-gcp.env, written by infra/install-vm-units.sh.
# ============================================================================

# gcloud lives in /snap/bin; systemd services start with a minimal PATH.
export PATH="/snap/bin:/usr/bin:/bin:$PATH"

# shellcheck disable=SC1091
source "$HOME/.hermes-gcp.env"   # PROJECT_ID, REGION, SCHEDULER_JOB_NAME, WAKE_LEAD_MIN

SCHEDULE=$(python3 "$HOME/nextwake.py" "$HOME/.hermes/cron/jobs.json" --lead-min "${WAKE_LEAD_MIN:-8}")

echo ">>> sync-next-wake: scheduler -> '$SCHEDULE' (UTC)"

gcloud scheduler jobs update http "$SCHEDULER_JOB_NAME" \
    --schedule="$SCHEDULE" \
    --time-zone=UTC \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null || {
    echo "    WARN: scheduler update failed"
    exit 0
}

echo ">>> sync-next-wake: done"
