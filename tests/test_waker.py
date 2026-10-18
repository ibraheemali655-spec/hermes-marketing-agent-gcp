import importlib

import pytest


@pytest.fixture
def waker(monkeypatch):
    env = {"PROJECT_ID": "p", "ZONE": "z", "VM_NAME": "vm", "TG_CHAT_ID": "1",
           "TELEGRAM_BOT_TOKEN": "t", "WEBHOOK_SECRET": "hook", "WAKE_TOKEN": "wake"}
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    import main
    main = importlib.reload(main)
    sent = []
    monkeypatch.setattr(main, "send_telegram", sent.append)
    main.sent = sent
    return main


def test_telegram_wakes_a_stopped_vm_and_tells_the_owner(waker):
    r = waker.app.test_client().post("/telegram", json={"update_id": 1},
                                     headers={"X-Telegram-Bot-Api-Secret-Token": "hook"})
    assert r.status_code == 200
    assert waker.instances_client.starts == 1
    assert len(waker.sent) == 1 and "Waking" in waker.sent[0]


def test_telegram_while_running_does_nothing(waker):
    waker.instances_client.status = "RUNNING"
    waker.app.test_client().post("/telegram", json={}, headers={"X-Telegram-Bot-Api-Secret-Token": "hook"})
    assert waker.instances_client.starts == 0 and waker.sent == []


def test_telegram_rejects_a_bad_secret(waker):
    r = waker.app.test_client().post("/telegram", json={}, headers={"X-Telegram-Bot-Api-Secret-Token": "x"})
    assert r.status_code == 403 and waker.instances_client.starts == 0


def test_wake_requires_the_scheduler_token(waker):
    c = waker.app.test_client()
    assert c.post("/wake").status_code == 403
    assert waker.instances_client.starts == 0
    assert c.post("/wake", headers={"X-Wake-Token": "wake"}).status_code == 200
    assert waker.instances_client.starts == 1


def test_health_reports_vm_state(waker):
    assert waker.app.test_client().get("/health").get_json() == {"status": "ok", "vm": "TERMINATED"}
