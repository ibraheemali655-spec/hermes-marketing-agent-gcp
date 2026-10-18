#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Create Cloud Scheduler job to wake hermes-vm before the next scheduled cron.
# See docs/architecture.md.
#
# The initial schedule is a placeholder (Tue/Thu/Sat 08:52 at UTC+3).
# Once the VM is up, sync-next-wake.sh will overwrite it from jobs.json.
#
# Prerequisites:
#   - App Engine app exists in the project (required by Cloud Scheduler)
#   - hermes-waker Cloud Run service deployed (waker/deploy.sh)
#   - WAKE_TOKEN exported (printed by waker/deploy.sh)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"  # cp config.example.sh config.sh

JOB_NAME="${SCHEDULER_JOB_NAME}"
REGION="${REGION}"
SERVICE_NAME="${WAKER_SERVICE_NAME}"

echo "==========================================================================="
echo "Cloud Scheduler: $JOB_NAME"
echo "  Project: $PROJECT_ID"
echo "  Region:  $REGION"
echo "==========================================================================="

# Get the waker URL.
WAKER_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format='value(status.url)' 2>/dev/null || true)

if [ -z "$WAKER_URL" ]; then
    echo "ERROR: Cloud Run service $SERVICE_NAME not found. Run waker/deploy.sh first."
    exit 1
fi
echo "  Waker URL: $WAKER_URL/wake"

# Ensure App Engine app exists (scheduler requires it).
if ! gcloud app describe --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo ">>> Creating App Engine app (required by Cloud Scheduler)"
    gcloud app create --project="$PROJECT_ID" --region="$REGION" 2>&1 | tail -3
fi

# The waker is public (Telegram must reach it), so /wake is guarded by a shared
# header token rather than OIDC (OIDC would need iam.serviceAccounts.actAs).
: "${WAKE_TOKEN:?export WAKE_TOKEN (printed by waker/deploy.sh)}"
echo ">>> Creating/updating scheduler job"
if gcloud scheduler jobs describe "$JOB_NAME" --location="$REGION" \
       --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "    Job exists — updating schedule."
    gcloud scheduler jobs update http "$JOB_NAME" \
        --location="$REGION" \
        --project="$PROJECT_ID" \
        --schedule="52 5 * * 2,4,6" \
        --time-zone=UTC \
        --uri="${WAKER_URL}/wake" \
        --http-method=POST \
        --update-headers="X-Wake-Token=${WAKE_TOKEN}" \
        --attempt-deadline="60s" \
        --quiet
else
    echo "    Creating new job."
    gcloud scheduler jobs create http "$JOB_NAME" \
        --location="$REGION" \
        --project="$PROJECT_ID" \
        --schedule="52 5 * * 2,4,6" \
        --time-zone=UTC \
        --uri="${WAKER_URL}/wake" \
        --http-method=POST \
        --headers="X-Wake-Token=${WAKE_TOKEN}" \
        --attempt-deadline="60s" \
        --description="Wake hermes-vm before next scheduled Hermes cron job"
fi

echo
echo "==========================================================================="
echo "SUCCESS: scheduler job $JOB_NAME"
echo "  Schedule:  52 5 * * 2,4,6 UTC (Tue/Thu/Sat 08:52 +03:00)"
echo "  Target:    ${WAKER_URL}/wake"
echo "  The VM will overwrite this schedule via sync-next-wake.sh."
echo "==========================================================================="
