#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-hermes-native.sh: runs ON the VM as the agent's user (VM_USER).
# Builds Hermes natively and installs it as two systemd services.
#
# Native, not Docker, on purpose: in a container the agent only sees its mounted
# state dir. As a host service its file/terminal tools act as the VM user on the
# whole machine, which is the point of giving it a dedicated VM.
# See handoffs/example-native-runtime.md for the handoff that specified this.
#
# Idempotent: safe to re-run. Pass --start to enable + start the services.
#
# Replicates the upstream Dockerfile's install recipe natively:
#   - uv venv --python 3.13 + uv pip install -e ".[all]"
#   - npm install + build web/dashboard + TUI assets
#   - Playwright chromium browser
#   - systemd units hermes-gateway + hermes-dashboard
# ============================================================================

REPO="$HOME/.hermes/hermes-agent"
VENV="$REPO/venv"
LOG="$HOME/install-hermes-native.log"
exec > >(tee -a "$LOG") 2>&1

echo "==========================================================================="
echo "install-hermes-native at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  repo:  $REPO"
echo "  venv:  $VENV"
echo "  user:  $(whoami) (uid=$(id -u))"
echo "==========================================================================="

if [ ! -d "$REPO" ]; then
    mkdir -p "$HOME/.hermes"
    git clone https://github.com/NousResearch/hermes-agent.git "$REPO"
fi

# Cloud-init can leave ~/.local and ~/.cache root-owned. Fix before uv/npm use them.
sudo chown -R "$(id -u):$(id -g)" "$HOME/.local" "$HOME/.cache" 2>/dev/null || true

# -----------------------------------------------------[1/7] apt system deps -
echo ">>> [1/7] System packages (ripgrep, ffmpeg, build toolchain, dev headers)"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    ripgrep ffmpeg build-essential python3-dev libffi-dev \
    git curl procps openssh-client ca-certificates \
    pkg-config

# ----------------------------------------------------------------[2/7] uv ---
echo ">>> [2/7] Install uv (Astral)"
if ! command -v uv >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/uv" ]; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
echo "    uv: $($UV --version)"

# ----------------------------------------[3/7] Python venv (3.13) + install -
echo ">>> [3/7] Build Python 3.13 venv + install hermes-agent[all]"
cd "$REPO"
# A venv built elsewhere (different OS/Python) is useless here: rebuild clean.
if [ -d "$VENV" ] && ! "$VENV/bin/python" -c "import sys; exit(0 if sys.version_info[:2]==(3,13) else 1)" 2>/dev/null; then
    echo "    Existing venv is not Python 3.13 — rebuilding."
    rm -rf "$VENV"
fi
if [ ! -d "$VENV" ]; then
    "$UV" venv "$VENV" --python 3.13
fi
"$UV" pip install --python "$VENV/bin/python" -e ".[all]"
echo "    Installed. hermes launcher: $VENV/bin/hermes"

# --------------------------------------------------[4/7] Node dashboard/TUI -
echo ">>> [4/7] Build web dashboard + TUI assets (npm)"
export npm_config_install_links=false
if [ -f package.json ]; then
    npm install --prefer-offline --no-audit
    (cd web && npm install --prefer-offline --no-audit && npm run build) || \
        echo "    WARN: web build failed (dashboard may be degraded)"
    (cd ui-tui && npm install --prefer-offline --no-audit && npm run build) || \
        echo "    WARN: ui-tui build failed (TUI may be degraded)"
fi

# -------------------------------------------------[5/7] Playwright chromium -
echo ">>> [5/7] Playwright chromium browser"
export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright"
if ! "$VENV/bin/python" -m playwright install chromium 2>/dev/null; then
    { "$UV" pip install --python "$VENV/bin/python" playwright &&
      "$VENV/bin/python" -m playwright install chromium; } ||
        echo "    WARN: playwright install failed (CDP via host Chrome still works)"
fi

# -------------------------------------------[6/7] Verify /opt/data + launch -
echo ">>> [6/7] Verify data dir + hermes launcher"
if grep -rq "/opt/data" "$HOME/.hermes/config.yaml" "$HOME/.hermes/.env" 2>/dev/null; then
    echo "    WARN: /opt/data found in config.yaml/.env — repointing to $HOME/.hermes"
    sed -i.bak "s#/opt/data#$HOME/.hermes#g" "$HOME/.hermes/config.yaml" "$HOME/.hermes/.env" 2>/dev/null || true
fi
echo "    HERMES_HOME will be $HOME/.hermes (explicit in systemd env)"
"$VENV/bin/hermes" --help >/dev/null 2>&1 && echo "    hermes --help: OK" || echo "    WARN: hermes --help failed"

# ----------------------------------------------------[7/7] systemd units ---
echo ">>> [7/7] Create systemd units"
export HERMES_HOME="$HOME/.hermes"
export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/ms-playwright"

sudo tee /etc/systemd/system/hermes-gateway.service >/dev/null <<EOF
[Unit]
Description=Hermes gateway (Telegram + cron scheduler)
After=network-online.target chrome-cdp.service
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$REPO
Environment=HERMES_HOME=$HERMES_HOME
Environment=PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH
Environment=HERMES_WEB_DIST=$REPO/hermes_cli/web_dist
Environment=PATH=$VENV/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin
ExecStart=$VENV/bin/hermes gateway run
Restart=always
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/hermes-dashboard.service >/dev/null <<EOF
[Unit]
Description=Hermes dashboard (127.0.0.1:9119, reach it over an SSH tunnel)
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$REPO
Environment=HERMES_HOME=$HERMES_HOME
Environment=PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH
Environment=HERMES_WEB_DIST=$REPO/hermes_cli/web_dist
Environment=PATH=$VENV/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:/snap/bin
ExecStart=$VENV/bin/hermes dashboard --host 127.0.0.1 --no-open
Restart=always
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload

if [ "${1:-}" = "--start" ]; then
    sudo systemctl enable --now hermes-gateway hermes-dashboard
fi

echo "==========================================================================="
echo "install-hermes-native DONE at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Start: sudo systemctl enable --now hermes-gateway hermes-dashboard"
echo "  Never run a second gateway on the same bot token: both would long-poll"
echo "  Telegram (409 conflicts) and double-fire cron jobs (duplicate posts)."
echo "==========================================================================="
