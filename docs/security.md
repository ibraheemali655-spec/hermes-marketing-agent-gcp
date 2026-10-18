# Security: a full browser, without exposing it

The agent needs a real, logged-in Chrome. LinkedIn's API can post to a company page, but only
once LinkedIn approves the app for organization posting (`w_organization_social`); until then,
and for page settings, which no API covers, the browser is the only way in. Most partner
marketing portals have no API at all. A logged-in browser is a powerful credential, so
the design keeps it reachable by the agent and by nobody else.

## The browser

- **A dedicated Chrome profile** (`~/chrome-cdp`), separate from anything the owner browses
  with. Chrome 136+ ignores `--remote-debugging-port` on the default profile anyway; a
  dedicated profile is both the requirement and the boundary.
- **CDP on loopback only.** `--remote-debugging-address=127.0.0.1`. No firewall rule exposes
  9222, and the VM has no inbound ports besides IAP SSH.
- **Headless systemd service** (`chrome-cdp.service`, in `infra/startup.sh`) with
  `Restart=always`. Scheduled jobs don't depend on anyone being connected to the desktop.
- **Re-login is a human step.** When a session expires, the agent doesn't type passwords. It
  reports, and the owner runs `hermes-chrome-relogin` from the remote desktop: the service
  stops, Chrome opens headful on the same profile, the owner logs in, and the service resumes.
- **The agent can't be pointed at internal endpoints** (`browser.allow_private_urls: false`).

## The network

- **No public SSH.** The only inbound rule allows TCP 22 from Google's IAP range
  (`35.235.240.0/20`). Operators connect with `gcloud compute ssh --tunnel-through-iap`, which
  is authenticated by their Google identity and IAM.
- **The dashboard (9119) and CDP (9222) are localhost-only.** Reach them with
  `ssh -L 9119:localhost:9119 -L 9222:localhost:9222`.
- **Chrome Remote Desktop is outbound-only**: no inbound port for the desktop either.
- Host UFW is disabled at boot because the GCP firewall is the single source of truth. A
  second, divergent firewall only ever blocked IAP.

## Secrets

- The Telegram bot token for the waker lives in **Secret Manager** and is mounted into Cloud
  Run at runtime. It isn't in the image, the repo or the deploy command history.
- `/telegram` rejects requests without Telegram's `X-Telegram-Bot-Api-Secret-Token`. `/wake`
  rejects requests without the scheduler's `X-Wake-Token`. The waker logs Telegram update IDs,
  never message text.
- On the VM, model and bot credentials stay in `~/.hermes/.env` (mode 600) and move between
  machines only inside tarballs over `gcloud compute scp`.
- This repo ships `*.example` files only. `.gitignore` blocks `.env`, `config.sh`, key JSON
  and Hermes state, and CI runs a secret scanner on every push.

## What the agent *can* do

It runs as a normal user on its own VM, with full access to that user's files and the logged-in
browser, deliberately. That's what makes it useful. The blast radius is one disposable VM with
one service account. Give that account only the roles the scripts use:
`compute.instanceAdmin.v1` (start/stop itself), `cloudscheduler.admin` (re-point its wake job)
and `secretmanager.secretAccessor`.
