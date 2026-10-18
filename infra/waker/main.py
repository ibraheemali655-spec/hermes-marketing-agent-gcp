import os
import logging
import requests as http_requests
from flask import Flask, request, jsonify
from google.cloud import compute_v1

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("hermes-waker")

PROJECT_ID = os.environ["PROJECT_ID"]
ZONE = os.environ["ZONE"]
VM_NAME = os.environ["VM_NAME"]
TG_CHAT_ID = os.environ["TG_CHAT_ID"]
TG_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
# Optional shared token Cloud Scheduler sends on /wake (the service is publicly reachable).
WAKE_TOKEN = os.environ.get("WAKE_TOKEN", "")

instances_client = compute_v1.InstancesClient()


def vm_status():
    try:
        inst = instances_client.get(project=PROJECT_ID, zone=ZONE, instance=VM_NAME)
        return inst.status
    except Exception:
        return "NOT_FOUND"


def start_vm():
    status = vm_status()
    if status == "TERMINATED" or status == "STOPPED":
        log.info("VM is %s — starting", status)
        op = instances_client.start(project=PROJECT_ID, zone=ZONE, instance=VM_NAME)
        log.info("Start operation: %s", op.name)
        return True
    elif status == "RUNNING":
        log.info("VM already RUNNING")
        return False
    else:
        log.warning("VM in unexpected state %s — attempting start", status)
        try:
            instances_client.start(project=PROJECT_ID, zone=ZONE, instance=VM_NAME)
            return True
        except Exception as e:
            log.error("Failed to start VM: %s", e)
            return False


def send_telegram(text):
    url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
    payload = {"chat_id": TG_CHAT_ID, "text": text}
    try:
        r = http_requests.post(url, json=payload, timeout=10)
        r.raise_for_status()
        log.info("Telegram reply sent: %s", text[:60])
    except Exception as e:
        log.error("Telegram reply failed: %s", e)


@app.route("/telegram", methods=["POST"])
def telegram_webhook():
    if WEBHOOK_SECRET:
        token = request.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
        if token != WEBHOOK_SECRET:
            log.warning("Invalid webhook secret")
            return jsonify({"error": "forbidden"}), 403

    body = request.get_json(silent=True) or {}
    # Log the update id only: message text is the owner's private conversation.
    log.info("Telegram webhook: update_id=%s", body.get("update_id"))

    started = start_vm()
    if started:
        send_telegram(
            "\U0001f7e1 Waking Hermes (~60 s) \u2014 resend your message when it confirms."
        )

    return jsonify({"ok": True}), 200


@app.route("/wake", methods=["POST"])
def wake():
    if WAKE_TOKEN and request.headers.get("X-Wake-Token", "") != WAKE_TOKEN:
        log.warning("Invalid wake token")
        return jsonify({"error": "forbidden"}), 403
    log.info("Wake request received (scheduler)")
    start_vm()
    return jsonify({"ok": True}), 200


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "vm": vm_status()}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
