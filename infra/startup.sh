#!/usr/bin/env bash
# ============================================================================
# hermes-vm GCE startup script: runs as root on every boot.
# Idempotent: every step is guarded so re-runs are safe.
# Logs to /var/log/hermes-startup.log (and console serially on GCP).
# See docs/architecture.md.
# ============================================================================
set -euo pipefail

LOG=/var/log/hermes-startup.log
mkdir -p "$(dirname "$LOG")"
chmod 644 "$LOG" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

echo "==========================================================================="
echo "VM startup at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "==========================================================================="

export DEBIAN_FRONTEND=noninteractive

# The Ubuntu 24.04 GCP image ships with UFW enabled (default-deny incoming).
# GCP's own firewall handles ingress policy; UFW only blocks IAP→22 here, so
# disable it before anything else (otherwise IAP SSH fails with banner timeout).
echo ">>> [0/8] Disabling host-side UFW (GCP firewall is the source of truth)"
systemctl disable --now ufw 2>/dev/null || true
ufw disable 2>/dev/null || true
iptables -F INPUT 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true

# Linux user that owns ~/.hermes. Passed by provision-vm.sh as instance metadata
# (vm-user). Create it now if missing so later steps can write into its home.
MD=http://metadata.google.internal/computeMetadata/v1/instance/attributes
TARGET_VM_USER="$(curl -fsS -H 'Metadata-Flavor: Google' "$MD/vm-user" 2>/dev/null || echo hermes)"
if ! id "$TARGET_VM_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$TARGET_VM_USER"
    usermod -aG sudo,docker "$TARGET_VM_USER" 2>/dev/null || true
fi
LOGIN_USER="$TARGET_VM_USER"
LOGIN_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
echo ">>> Login user: $LOGIN_USER (home=$LOGIN_HOME)"

run_as_user() { sudo -u "$LOGIN_USER" -- "$@"; }

# ----------------------------------------------------------------[1/8] apt ---
echo ">>> [1/8] apt update + universe + GNOME Flashback / Xvfb / utility packages"
# gnome-session-flashback, xvfb, x11vnc, metacity live in 'universe'; the GCP
# image may not have it enabled by default.
source /etc/lsb-release 2>/dev/null || true
if [ -n "${DISTRIB_CODENAME:-}" ]; then
    if ! grep -rq "^deb .*universe" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        add-apt-repository -y universe
    fi
fi
apt-get update -y
apt-get install -y --no-install-recommends \
    gnome-session-flashback gnome-panel metacity nautilus gnome-terminal \
    xvfb x11vnc \
    libfuse2 \
    curl wget jq git ca-certificates gnupg lsb-release \
    python3 python3-pip \
    software-properties-common

# ----------------------------------------------------------[2/8] Docker -----
echo ">>> [2/8] Docker + compose plugin"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi
apt-get install -y docker-compose-plugin || apt-get install -y docker-compose || true
usermod -aG docker "$LOGIN_USER" || true
systemctl enable --now docker 2>/dev/null || true

# ---------------------------------------------------[3/8] Google Chrome -----
echo ">>> [3/8] Google Chrome stable"
if ! command -v google-chrome >/dev/null 2>&1 \
   && ! command -v google-chrome-stable >/dev/null 2>&1; then
    curl -fsSL -o /tmp/chrome.deb \
        https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y /tmp/chrome.deb || apt-get install -fy
    rm -f /tmp/chrome.deb
fi

# ------------------------------------------[4/8] Chrome Remote Desktop ------
# CRD host registration is interactive (one-time, by the owner): install only here.
echo ">>> [4/8] Chrome Remote Desktop host package"
if ! command -v chrome-remote-desktop >/dev/null 2>&1 \
   && ! dpkg -l chrome-remote-desktop >/dev/null 2>&1; then
    curl -fsSL -o /tmp/crd.deb \
        https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb
    apt-get install -y /tmp/crd.deb || apt-get install -fy
    rm -f /tmp/crd.deb
fi
# Session file CRD will exec on connection (GNOME Flashback, no GPU check).
cat > "$LOGIN_HOME/.chrome-remote-desktop-session" <<'EOF'
exec /usr/bin/gnome-session --session=gnome-flashback-metacity --disable-acceleration-check
EOF
chown "$LOGIN_USER:$LOGIN_USER" "$LOGIN_HOME/.chrome-remote-desktop-session" || true

# The CRD host's virtual X session can collapse in a startup race after a wake
# and the service exits without retrying → CRD shows the VM "offline" though it's
# up. Make it self-heal. (Drop-in applies once the @USER instance is registered.)
install -d -m 0755 "/etc/systemd/system/chrome-remote-desktop@${LOGIN_USER}.service.d"
cat > "/etc/systemd/system/chrome-remote-desktop@${LOGIN_USER}.service.d/restart.conf" <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=10
[Service]
Restart=on-failure
RestartSec=15
EOF
systemctl daemon-reload 2>/dev/null || true

# GNOME Flashback's gnome-panel (the top menu bar) sometimes loses a startup race
# in the CRD virtual session and never appears, leaving a desktop with no menu.
# Relaunch it a few seconds into the session if it isn't already up.
install -d -m 0755 -o "$LOGIN_USER" -g "$LOGIN_USER" "$LOGIN_HOME/.config/autostart"
cat > "$LOGIN_HOME/.config/autostart/gnome-panel-fallback.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=GNOME Panel (fallback)
Exec=sh -c "sleep 6; pgrep -x gnome-panel >/dev/null || gnome-panel"
X-GNOME-Autostart-enabled=true
EOF
chown "$LOGIN_USER:$LOGIN_USER" "$LOGIN_HOME/.config/autostart/gnome-panel-fallback.desktop" || true

# --------------------------------------------[5/8] Node LTS + Claude Code ---
echo ">>> [5/8] Node LTS + Claude Code CLI"
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
fi
run_as_user bash -c 'npm config set prefix ~/.npm-global' || true
PATH="$LOGIN_HOME/.npm-global/bin:$PATH"
run_as_user bash -c 'PATH=$HOME/.npm-global/bin:$PATH npm i -g @anthropic-ai/claude-code' || \
    echo "    (claude-code install deferred — owner can run after auth)"
# Put ~/.npm-global/bin on PATH for the user's interactive + login shells so
# `claude` (and any other global npm bin) resolves without a full path.
run_as_user bash -c 'grep -q ".npm-global/bin" ~/.bashrc 2>/dev/null || echo "export PATH=\$HOME/.npm-global/bin:\$PATH" >> ~/.bashrc'
run_as_user bash -c 'grep -q ".npm-global/bin" ~/.profile 2>/dev/null || echo "export PATH=\$HOME/.npm-global/bin:\$PATH" >> ~/.profile'

# ----------------------------------[6/8] VS Code + extension list from §2 --
echo ">>> [6/8] VS Code + extensions"
if ! command -v code >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
    chmod a+r /etc/apt/keyrings/microsoft.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        > /etc/apt/sources.list.d/vscode.list
    apt-get update -y
    apt-get install -y code
fi
for ext in \
    anthropic.claude-code \
    sst-dev.opencode \
    github.copilot-chat \
    ms-azuretools.vscode-containers \
    ms-python.python \
    ms-python.vscode-pylance \
    ms-python.debugpy \
    ms-python.vscode-python-envs; do
    run_as_user bash -c "code --install-extension $ext" || \
        echo "    (extension $ext install failed — non-fatal)"
done

# ----------------------------------[7/8] Claude Desktop AppImage launcher --
# The AppImage itself is copied in when state is restored.
echo ">>> [7/8] Claude Desktop .desktop launcher (AppImage copied in with the restored state)"
install -d -m 0755 "$LOGIN_HOME/.local/share/applications"
cat > "$LOGIN_HOME/.local/share/applications/claude-desktop.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude Desktop
Exec=$LOGIN_HOME/claude-desktop.AppImage
Terminal=false
Categories=Office;
Icon=applications-science
EOF
chown -R "$LOGIN_USER:$LOGIN_USER" "$LOGIN_HOME/.local/share/applications" || true

# ------------------------[8/8] Chrome CDP systemd service (127.0.0.1:9222) --
echo ">>> [8/8] Chrome CDP headless systemd service"
# Two hard constraints learned on this VM:
#   1. Chrome 136+ SILENTLY ignores --remote-debugging-port on the DEFAULT
#      profile (~/.config/google-chrome). CDP only binds on a DEDICATED dir,
#      so we use $CDP_PROFILE (seeded once with the agent's logged-in browser session).
#   2. A headful Chrome launched from the CRD GNOME-session autostart is racy
#      (singleton hand-off → no CDP listener). A dedicated HEADLESS Chrome run
#      as a systemd service binds CDP reliably and is independent of whether
#      anyone is connected to the desktop — which is what scheduled jobs need.
CDP_PROFILE="$LOGIN_HOME/chrome-cdp"
install -d -m 0700 -o "$LOGIN_USER" -g "$LOGIN_USER" "$CDP_PROFILE"

cat > /etc/systemd/system/chrome-cdp.service <<EOF
[Unit]
Description=Headless Chrome (CDP 127.0.0.1:9222) for Hermes
After=network-online.target
Wants=network-online.target

[Service]
User=$LOGIN_USER
# A seeded profile carries cross-host Singleton* locks that make Chrome refuse
# the profile ("in use by another computer"); clear them before each start.
ExecStartPre=/bin/bash -c 'rm -f $CDP_PROFILE/Singleton* $CDP_PROFILE/lockfile || true'
ExecStart=/usr/bin/google-chrome --headless=new --user-data-dir=$CDP_PROFILE \\
    --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \\
    --no-first-run --no-default-browser-check --disable-gpu --disable-dev-shm-usage
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now chrome-cdp.service || true

# Allow $LOGIN_USER to stop/start the service without a password (for re-login).
cat > /etc/sudoers.d/hermes-chrome-cdp <<EOF
$LOGIN_USER ALL=(root) NOPASSWD: /usr/bin/systemctl start chrome-cdp.service, /usr/bin/systemctl stop chrome-cdp.service, /usr/bin/systemctl restart chrome-cdp.service
EOF
chmod 440 /etc/sudoers.d/hermes-chrome-cdp

# LinkedIn re-login helper: stop the headless CDP, open Chrome HEADFUL on the
# SAME profile (run this from the CRD desktop), log in, close it, service resumes.
install -d -m 0755 -o "$LOGIN_USER" -g "$LOGIN_USER" "$LOGIN_HOME/.local/bin"
cat > "$LOGIN_HOME/.local/bin/hermes-chrome-relogin" <<EOF
#!/usr/bin/env bash
set -e
sudo systemctl stop chrome-cdp.service
echo "Headless CDP stopped. Log into LinkedIn in the window that opens, then close it."
/usr/bin/google-chrome --user-data-dir="$CDP_PROFILE" --no-first-run --no-default-browser-check || true
sudo systemctl start chrome-cdp.service
echo "CDP service restarted; the new session cookies are now live for the agent."
EOF
chmod +x "$LOGIN_HOME/.local/bin/hermes-chrome-relogin"
chown "$LOGIN_USER:$LOGIN_USER" "$LOGIN_HOME/.local/bin/hermes-chrome-relogin"

# Remove stale entries from the pre-service design: the headful CRD-autostart
# and the desktop Chrome icon that pointed at the agent's ~/chrome-cdp profile
# (clicking it now collides with chrome-cdp.service). The menu keeps the stock
# Google Chrome (default profile) for the operator's own browsing.
rm -f "$LOGIN_HOME/.config/autostart/chrome-cdp.desktop" 2>/dev/null || true
rm -f "$LOGIN_HOME/.local/share/applications/google-chrome.desktop" 2>/dev/null || true

# Power management (sync-next-wake, idle-watchdog, webhook units) is installed
# separately by infra/install-vm-units.sh.

echo "==========================================================================="
echo "VM startup DONE at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "==========================================================================="
