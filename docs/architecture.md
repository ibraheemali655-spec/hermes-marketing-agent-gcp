# Architecture

![Architecture](img/architecture.svg)

One GCP VM runs everything the agent needs: the Hermes gateway, a logged-in Chrome,
a remote desktop, and Claude Code. The VM is **off by default**. Two things turn it on,
and one thing turns it off.

## Waking up

**A Telegram message.** While the VM sleeps, the bot's webhook points at `hermes-waker`,
a small Flask service on Cloud Run (`infra/waker/main.py`). The service checks Telegram's
secret header, starts the VM, and replies "Waking Hermes (~60 s), resend your message". On
boot, `hermes-webhook-release.service` deletes the webhook so the gateway can long-poll
Telegram itself, and `hermes-ready-notify.service` pings the owner once the gateway is up.

**A due cron job.** Cloud Scheduler job `hermes-next-wake` calls the waker's `/wake`
endpoint `WAKE_LEAD_MIN` (8) minutes before the next job. Its schedule isn't hardcoded:
`infra/vm/nextwake.py` reads Hermes's own job store (`~/.hermes/cron/jobs.json`) and
`sync-next-wake.sh` writes the result into the Scheduler job.

- `sync-next-wake.path` re-runs it whenever `jobs.json` changes. A job the owner adds from
  Telegram ("post every Monday at 10") is covered with no infrastructure change.
- The idle watchdog re-runs it right before shutdown, so the Scheduler always points at
  the *next* job.
- Disabled, paused and already-past jobs are ignored. With nothing due, the Scheduler is
  parked on 1 January.

## Going to sleep

`idle-watchdog.timer` runs `infra/vm/idle-watchdog.sh` every 5 minutes (first tick 10 minutes
after boot). The VM counts as idle when there are no login sessions, no remote-desktop
client, no cron job holding Hermes's `.tick.lock`, and no Hermes session file written in the
last 30 minutes. After 30 idle minutes the watchdog:

1. runs `sync-next-wake.sh` (Scheduler → next job),
2. points the Telegram webhook back at the waker,
3. runs `shutdown -h now`.

`hermes-webhook-arm.service` re-arms the webhook in its `ExecStop` as well. Whatever stops the
VM (watchdog, `infra/stop.sh`, the console, a reboot), the next Telegram message still wakes it.

## Why the scheduler wake matters

Hermes's scheduler has a 2-hour grace window. A slot that passes while the gateway is down
still fires if the gateway comes back within 2 hours. Otherwise the run is skipped and the
job fast-forwards to its next occurrence. **Missed runs are never caught up.**

On the desktop VM this agent used to live in, that meant a post silently didn't go out
whenever the laptop was off on a posting morning. That happened on 30 May (see
[case-study.md](case-study.md)). On GCP, the VM is started 8 minutes before every slot, so
the scheduler is always up when a job is due. `run_demo.py` replays the 10-week campaign
on both hosts to show the difference.

## Files

| Path | Runs on | Purpose |
|---|---|---|
| `infra/provision-vm.sh` | operator | VPC, IAP-only SSH firewall, the VM with `startup.sh` attached |
| `infra/startup.sh` | VM (root, every boot) | desktop, Chrome + CDP service, VS Code, Claude Code |
| `infra/vm/install-hermes-native.sh` | VM | builds Hermes and installs the gateway/dashboard services |
| `infra/waker/` | Cloud Run | `/telegram`, `/wake`, `/health` |
| `infra/setup-scheduler.sh` | operator | creates `hermes-next-wake` |
| `infra/install-vm-units.sh` | operator | copies `vm/*` and installs `units/*` on the VM |
| `infra/vm/idle-watchdog.sh` | VM | 30 min idle → re-point Scheduler, re-arm webhook, stop |
| `infra/vm/nextwake.py`, `sync-next-wake.sh` | VM | jobs.json → Scheduler expression |
| `infra/start.sh`, `stop.sh` | operator | manual start, or a graceful stop that re-arms both triggers |

## Bring-up order

```bash
cp infra/config.example.sh infra/config.sh      # fill in project, user, chat id
infra/provision-vm.sh                           # VM + network
gcloud compute ssh hermes-vm --tunnel-through-iap -- 'bash -s' < infra/vm/install-hermes-native.sh
# copy your ~/.hermes state (config.yaml, .env, skills, cron) with gcloud compute scp, then
# start the services: sudo systemctl enable --now hermes-gateway hermes-dashboard
infra/waker/deploy.sh <TELEGRAM_BOT_TOKEN>      # prints WEBHOOK_SECRET and WAKE_TOKEN
WAKE_TOKEN=... infra/setup-scheduler.sh
HERMES_WAKER_URL=... HERMES_WEBHOOK_SECRET=... infra/install-vm-units.sh
```

Chrome Remote Desktop registration and the agent's first LinkedIn login are one-time manual
steps on the VM's desktop (`hermes-chrome-relogin`).
