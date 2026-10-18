#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Deploy hermes-waker Cloud Run service + set Telegram webhook.
# See docs/architecture.md.
#
# Prerequisites:
#   - APIs enabled: run, secretmanager, artifactregistry, cloudscheduler
#   - TELEGRAM_BOT_TOKEN secret created in Secret Manager
#   - The bot token value (from ~/.hermes/.env)
#
# Usage:
#   infra/waker/deploy.sh [TELEGRAM_BOT_TOKEN_VALUE]
#
# If arg is provided and the secret doesn't exist yet, it will be created.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "${HERMES_DIR}/config.sh"  # cp config.example.sh config.sh

WAKER_DIR="$SCRIPT_DIR"
SERVICE_NAME="${WAKER_SERVICE_NAME}"
REGION="${REGION}"
RUNTIME_SA="${SA_EMAIL}"
SECRET_NAME="TELEGRAM_BOT_TOKEN"

echo "==========================================================================="
echo "hermes-waker Cloud Run deployment"
echo "  Project:   $PROJECT_ID"
echo "  Region:    $REGION"
echo "  Service:   $SERVICE_NAME"
echo "  SA:        $RUNTIME_SA"
echo "  Secret:    $SECRET_NAME"
echo "==========================================================================="

# --------------------------------------------------[1/5] Ensure SA has roles -
echo ">>> [1/5] Granting IAM roles to $SA_EMAIL"
for role in roles/compute.instanceAdmin.v1 roles/secretmanager.secretAccessor roles/cloudscheduler.admin; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member="serviceAccount:$RUNTIME_SA" \
        --role="$role" --quiet 2>&1 | tail -1
done

# ------------------------------------------[2/5] Secret Manager: bot token ---
echo ">>> [2/5] Ensure Secret Manager secret exists"
if ! gcloud secrets describe "$SECRET_NAME" --project="$PROJECT_ID" >/dev/null 2>&1; then
    if [ $# -gt 0 ]; then
        echo "$1" | gcloud secrets create "$SECRET_NAME" \
            --data-file=- --replication-policy=automatic --project="$PROJECT_ID"
        echo "    Secret created."
    else
        echo "ERROR: Secret $SECRET_NAME doesn't exist and no token value provided."
        echo "  Usage: $0 <TELEGRAM_BOT_TOKEN_VALUE>"
        exit 1
    fi
else
    if [ $# -gt 0 ]; then
        echo "$1" | gcloud secrets versions add "$SECRET_NAME" \
            --data-file=- --project="$PROJECT_ID"
        echo "    Secret updated with new version."
    else
        echo "    Secret already exists (pass token arg to update)."
    fi
fi

# ------------------------------------------[3/5] Generate webhook secret ---
# Reuse secrets across redeploys if exported, otherwise generate fresh ones.
WEBHOOK_SECRET="${WEBHOOK_SECRET:-hw-$(openssl rand -hex 16)}"
WAKE_TOKEN="${WAKE_TOKEN:-wk-$(openssl rand -hex 16)}"
echo ">>> [3/5] Webhook secret: ${WEBHOOK_SECRET:0:6}…  wake token: ${WAKE_TOKEN:0:6}…"

# ------------------------------------------[4/5] Deploy Cloud Run service ---
echo ">>> [4/5] Deploying Cloud Run service"
gcloud run deploy "$SERVICE_NAME" \
    --source="$WAKER_DIR" \
    --region="$REGION" \
    --platform=managed \
    --allow-unauthenticated \
    --service-account="$RUNTIME_SA" \
    --set-env-vars="PROJECT_ID=$PROJECT_ID,ZONE=$ZONE,VM_NAME=$VM_NAME,TG_CHAT_ID=$TG_CHAT_ID,WEBHOOK_SECRET=$WEBHOOK_SECRET,WAKE_TOKEN=$WAKE_TOKEN" \
    --set-secrets="TELEGRAM_BOT_TOKEN=$SECRET_NAME:latest" \
    --min-instances=0 \
    --max-instances=1 \
    --memory=256Mi \
    --project="$PROJECT_ID" \
    --quiet

# Get the service URL.
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region="$REGION" --project="$PROJECT_ID" \
    --format='value(status.url)')
echo "    Service URL: $SERVICE_URL"

# -------------------------------------------[5/5] Set Telegram webhook ---
# CUTOVER STEP: setWebhook disables getUpdates for the bot, cutting Telegram
# away from any other consumer (a second Hermes instance still long-polling). Default = SKIP.
# Export HERMES_SET_WEBHOOK=1 only when you're ready to cut over.
if [ "${HERMES_SET_WEBHOOK:-0}" = "1" ]; then
    echo ">>> [5/5] Setting Telegram webhook → ${SERVICE_URL}/telegram"
    BOT_TOKEN=$(gcloud secrets versions access latest --secret="$SECRET_NAME" --project="$PROJECT_ID")
    curl -s "https://api.telegram.org/bot${BOT_TOKEN}/setWebhook" \
        -d "url=${SERVICE_URL}/telegram" \
        -d "secret_token=${WEBHOOK_SECRET}" \
        | python3 -m json.tool
else
    echo ">>> [5/5] SKIPPED setWebhook (HOLD mode — another gateway keeps Telegram)."
    echo "    To cut over later: HERMES_SET_WEBHOOK=1 re-run, or set the webhook to:"
    echo "      ${SERVICE_URL}/telegram   (secret_token=${WEBHOOK_SECRET})"
fi

echo
echo "==========================================================================="
echo "SUCCESS: hermes-waker deployed"
echo "  Webhook URL:    ${SERVICE_URL}/telegram"
echo "  Wake URL:       ${SERVICE_URL}/wake"
echo "  Health URL:     ${SERVICE_URL}/health"
echo "  Webhook secret: $WEBHOOK_SECRET  (save for redeploy + install-vm-units.sh)"
echo "  Wake token:     $WAKE_TOKEN  (save for redeploy + setup-scheduler.sh)"
echo "==========================================================================="
echo ""
echo "Next: WAKE_TOKEN=$WAKE_TOKEN infra/setup-scheduler.sh"
