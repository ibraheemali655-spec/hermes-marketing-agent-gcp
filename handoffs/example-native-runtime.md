# Implementation Handoff — Run Hermes NATIVELY (drop Docker) for full-machine access

**Author:** boss (Claude Opus) · **Implementer:** GLM · **Status:** approved by owner, ready to build

> A real handoff from building this repo, sanitized (user and paths generalized). It produced
> `infra/vm/install-hermes-native.sh` and is kept as the worked example for `TEMPLATE.md`.

> GLM — execute on `hermes-vm` (SSH: `gcloud compute ssh hermes-vm --tunnel-through-iap`).
> Go phase by phase; stop at the **GATE** and verify before cutting over. Commit + push at the end.
> Don't print secrets (`~/.hermes/.env`). The owner is reachable on Telegram for the live test.

## 1. Why

The Hermes gateway runs in Docker with **only `~/.hermes` mounted** (`/opt/data`), so the agent
can't see the rest of the VM (e.g. `~/Desktop/<project>`, installed apps, the wider filesystem). The
owner wants the agent to **own the whole machine**. Fix: run Hermes **natively on the host** as
systemd services instead of in a container. Native, the agent's `file`/`terminal` tools act as the VM
user on the real filesystem — full access.

## 2. Ground truth (verified — don't re-derive)

- **Today's deploy:** `~/.hermes/hermes-agent/docker-compose.yml` → `gateway` (`command: ["gateway","run"]`,
  container `hermes`) + `dashboard` (`["dashboard","--host","127.0.0.1","--no-open"]`), both
  `network_mode: host`, mount `~/.hermes:/opt/data`, `restart: unless-stopped`.
- **Deps the Dockerfile installs** (translate to the Ubuntu 24.04 host): `uv` (Astral) + **Python 3.13**,
  `nodejs`/`npm`, `ripgrep`, `ffmpeg`, `gcc`, `python3-dev`, `libffi-dev`, `procps`, `git`,
  `openssh-client`, `build-essential`, `curl`, plus **Playwright** browsers
  (`PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright` in the image).
- **State dir:** `~/.hermes` (`config.yaml`, `.env`, `state.db`, `skills/`, `cron/`, `sessions/`). In
  Docker this was `/opt/data` purely because of the mount; natively Hermes should use `~/.hermes`.
- **Browser:** the host `chrome-cdp.service` serves CDP on `127.0.0.1:9222`; `config.yaml` already has
  `browser.cdp_url: http://127.0.0.1:9222`. Native gateway reaches it directly — **no change**.
- **Host:** user `$VM_USER` (passwordless sudo), `gcloud` at `/snap/bin/gcloud`, node already installed.

## 3. Gotchas (read before starting)

- **Don't reuse `~/.hermes/hermes-agent/venv`** — it was built inside the old desktop VM (different
  OS/Python). Rebuild from scratch with `uv`.
- **Python 3.13:** the host has 3.12; let `uv` provide 3.13 (uv installs standalone Pythons).
- **Playwright:** `playwright install chromium` + `playwright install-deps` (sudo) — or keep using the
  host Chrome via CDP and confirm whether Hermes still needs its own Playwright browser.
- **Never run the Docker gateway and the native gateway at the same time** — both long-poll Telegram
  → 409 conflict + **double-fired crons** (duplicate LinkedIn posts). Stop+disable Docker before
  starting native.
- **Confirm the data-dir resolution:** `grep -n /opt/data ~/.hermes/config.yaml ~/.hermes/.env` — if
  anything hardcodes `/opt/data`, repoint to `$HOME/.hermes`. Find how Hermes locates its home
  (env `HERMES_HOME`? default `~/.hermes`?) from the repo's docs and set it in the service env.
- **Exact launch command:** confirm from the repo how the compose `gateway`/`dashboard` commands map
  natively — almost certainly `uv run hermes gateway run` and `uv run hermes dashboard --host
  127.0.0.1 --no-open` (the repo has a `hermes` launcher + `hermes_cli`). Verify with `uv run hermes --help`.

## 4. Phases

### Phase A — Build the native env (non-disruptive; the Docker gateway keeps running)
1. Host deps: `sudo apt-get update && sudo apt-get install -y ripgrep ffmpeg build-essential python3-dev libffi-dev git curl`.
2. Install uv: `curl -LsSf https://astral.sh/uv/install.sh | sh` (adds `~/.local/bin`).
3. `cd ~/.hermes/hermes-agent && rm -rf venv && uv sync` (or the repo's documented install; check
   `README*`/`AGENTS.md`/`pyproject.toml`). Confirm: `uv run hermes --help` works.
4. Browser deps: `uv run playwright install chromium && sudo $(command -v uv) run playwright install-deps`
   (set/keep `PLAYWRIGHT_BROWSERS_PATH` to a host path, e.g. `~/.cache/ms-playwright`).
5. `grep -n /opt/data ~/.hermes/config.yaml ~/.hermes/.env` → fix any to `$HOME/.hermes`.

### Phase B — systemd units (create, don't start)
6. `infra/units/hermes-gateway.service` and `hermes-dashboard.service`:
   `User=$VM_USER`, `WorkingDirectory=/home/$VM_USER/.hermes/hermes-agent`,
   `Environment=PATH=/home/$VM_USER/.local/bin:/home/$VM_USER/.npm-global/bin:/usr/bin:/bin:/snap/bin`,
   `Environment=PLAYWRIGHT_BROWSERS_PATH=/home/$VM_USER/.cache/ms-playwright` (+ `HERMES_HOME` if needed),
   `ExecStart=/home/$VM_USER/.local/bin/uv run hermes gateway run` (dashboard: `… dashboard --host
   127.0.0.1 --no-open`), `Restart=always`, `RestartSec=10`. Install to `/etc/systemd/system/`,
   `daemon-reload`.

### Phase C — Cut over (brief Telegram gap)
7. `cd ~/.hermes/hermes-agent && docker compose down` then `docker update --restart=no hermes hermes-dashboard 2>/dev/null` (ensure Docker won't auto-restart them on boot).
8. `sudo systemctl enable --now hermes-gateway.service hermes-dashboard.service`.

### GATE — verify before declaring done
- `systemctl status hermes-gateway hermes-dashboard` → active.
- Telegram: send a message → Hermes replies (carried-over memory intact).
- **The whole point:** via Telegram, ask the agent to **list `~/Desktop/<project>`** (or read a file
  under `$HOME`) — it must now SEE it (proves full-filesystem access).
- CDP browser task still works (`curl localhost:9222/json/version` + an agent browser action).
- Dashboard via `ssh -L 9119:localhost:9119`.
- `sudo reboot` → both services auto-start, Telegram works, CDP up.

### Phase D — Update repo scripts (Docker → native) + reproducibility
9. Edit:
   - `start.sh`: `docker compose up -d` → `sudo systemctl start hermes-gateway hermes-dashboard`.
   - `hermes-ready-notify.sh`: replace the `docker inspect hermes` readiness check with
     `systemctl is-active hermes-gateway`.
   - `restore-state.sh`: replace the `docker compose build/up` step (step 7) with the native build
     (`uv sync`) + `systemctl enable --now …`.
   - `startup.sh`: Docker is no longer required for Hermes (chrome-cdp uses host Chrome) — keep
     the package (harmless) but note it's optional; reference the new native installer.
   - `RUNBOOK.md`: change "Hermes = Docker compose" to the native systemd services.
10. New deliverable `infra/install-hermes-native.sh` (operator-run, idempotent): Phase A + B,
    so a rebuilt VM can go native in one command.
11. **Commit + push** , conventional commit, Co-Authored-By trailer. Secrets gate
    (`git status` + `git diff --cached`) before committing.

## 5. Definition of done
Native `hermes-gateway`/`hermes-dashboard` services active and reboot-persistent; Telegram round-trip
works; the agent can read/write across `$HOME` (confirmed on `~/Desktop/<project>`); CDP browser
works; wake/sleep lifecycle intact (`hermes-ready-notify` now checks the service, not Docker); Docker
Hermes containers stopped + set to not auto-start (no double Telegram consumer). Repo scripts updated.

## 6. Escalate to owner
- If `uv sync` / Playwright pulls a very different toolchain than the image (version drift), confirm
  before proceeding.
- Whether the agent should also get **root** (sudo) powers, or stay as `$VM_USER` (default here).
