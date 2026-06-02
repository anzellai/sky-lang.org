#!/usr/bin/env bash
#
# setup-remote.sh — runs ON the GCE VM (uploaded + invoked by
# deploy.sh). Idempotent: installs Caddy + creates systemd unit on
# first run, places artifacts, (re)starts the service.
#
# Inputs (via env from deploy.sh):
#   SERVICE     systemd unit name (default: sky-lang-org)
#   SKY_VERSION pinned Sky compiler version for the editor toolchain
#               (currently unused by sky-lang.org itself; reserved
#               for future `sky fmt` / `sky check` integration)
#
# Inputs (via /tmp uploads):
#   /tmp/sky-lang-org-linux         the cross-compiled app binary
#   /tmp/sky-lang-org.env           the production .env file
#   /tmp/sky.toml                   project metadata
#   /tmp/Caddyfile                  reverse proxy config
#   /tmp/${SERVICE}.service         systemd unit
#   /tmp/sky-lang-org-assets.tgz    brand/ + content/ + static-fallback/
#   /tmp/origin.crt + /tmp/origin.key (optional) — CF Origin cert pair
#                                   for end-to-end HTTPS. Installed at
#                                   /etc/caddy/certs/. Caddyfile
#                                   references them as
#                                   /etc/caddy/certs/sky-lang.org.{crt,key}.
#
set -e

SERVICE="${SERVICE:-sky-lang-org}"
SKY_VERSION="${SKY_VERSION:-0.15.59}"
GO_VERSION="${GO_VERSION:-1.23.4}"

APP_DIR="/opt/${SERVICE}"
DATA_DIR="/var/lib/${SERVICE}"


echo "[1/5] ${APP_DIR} layout"
sudo mkdir -p "$APP_DIR" "$DATA_DIR"
sudo mv /tmp/sky-lang-org-linux "$APP_DIR/app"
sudo mv /tmp/sky.toml           "$APP_DIR/sky.toml"
sudo mv /tmp/sky-lang-org.env   "$APP_DIR/.env"
sudo chmod +x "$APP_DIR/app"
sudo chmod 600 "$APP_DIR/.env"

if [ -f /tmp/sky-lang-org-assets.tgz ]; then
    echo "  unpacking brand + content assets"
    sudo tar -xzf /tmp/sky-lang-org-assets.tgz -C "$APP_DIR"
    sudo rm /tmp/sky-lang-org-assets.tgz
fi


echo "[1b/5] sky toolchain (for /_sky/console subapp)"
# The Sky.Live framework's /_sky/console route reverse-proxies to a
# `sky console` subprocess. That subprocess builds itself on first
# launch via `go build` against TH-embedded source, so the VM needs
# BOTH the `sky` binary AND a recent Go toolchain present. Without
# them the framework logs:
#     [sky.console-auth] mount skipped: sky binary not found
#     OR
#     [sky.console-auth] mount skipped: sky console on :NNNNN did not
#                                       become ready within 30000ms
# and /admin/console-link's redirect lands on a 404. Install both
# idempotently.
if ! command -v sky >/dev/null || [ "$(sky --version 2>/dev/null | awk '{print $2}' | sed 's/^v//')" != "$SKY_VERSION" ]; then
    echo "  installing sky v${SKY_VERSION}"
    curl -fsSL "https://github.com/anzellai/sky/releases/download/v${SKY_VERSION}/sky-linux-x64.tar.gz" -o /tmp/sky.tar.gz
    sudo tar -xzf /tmp/sky.tar.gz -C /tmp sky-linux-x64 sky-ffi-inspect-sky-linux-x64
    sudo install -m 0755 /tmp/sky-linux-x64 /usr/local/bin/sky
    sudo install -m 0755 /tmp/sky-ffi-inspect-sky-linux-x64 /usr/local/bin/sky-ffi-inspect
    sudo rm -f /tmp/sky.tar.gz /tmp/sky-linux-x64 /tmp/sky-ffi-inspect-sky-linux-x64
fi

if ! command -v go >/dev/null || [ "$(go version 2>/dev/null | grep -oE 'go1\.[0-9]+' | cut -d. -f2)" -lt 21 ]; then
    echo "  installing Go ${GO_VERSION}"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
    sudo rm -rf /usr/local/go
    sudo tar -xzf /tmp/go.tgz -C /usr/local/
    sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
    sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    sudo rm /tmp/go.tgz
fi


echo "[2/5] Caddy"
if ! command -v caddy >/dev/null; then
    echo "  installing Caddy..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        debian-keyring debian-archive-keyring apt-transport-https curl gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq caddy
fi

# Install Cloudflare Origin cert pair if uploaded. Both files must be
# present together; partial uploads abort the deploy.
sudo mkdir -p /etc/caddy/certs
if [ -f /tmp/origin.crt ] || [ -f /tmp/origin.key ]; then
    if [ ! -f /tmp/origin.crt ] || [ ! -f /tmp/origin.key ]; then
        echo "  ERROR: only one of origin.crt / origin.key uploaded — refusing partial install" >&2
        exit 1
    fi
    echo "  installing Cloudflare Origin certificate"
    sudo mv /tmp/origin.crt /etc/caddy/certs/sky-lang.org.crt
    sudo mv /tmp/origin.key /etc/caddy/certs/sky-lang.org.key
    # Caddy runs as user `caddy` (not root) on Debian's caddy.service —
    # owner the cert + key to `caddy:caddy` so it can read them, with
    # the private key locked to 640 (group read for caddy only).
    sudo chown caddy:caddy /etc/caddy/certs/sky-lang.org.crt /etc/caddy/certs/sky-lang.org.key
    sudo chmod 644 /etc/caddy/certs/sky-lang.org.crt
    sudo chmod 640 /etc/caddy/certs/sky-lang.org.key
fi

# Caddyfile references /etc/caddy/certs/sky-lang.org.{crt,key} — if
# they're missing, Caddy will fail at reload. Tell the operator up
# front instead of leaving a cryptic systemctl error.
if [ ! -f /etc/caddy/certs/sky-lang.org.crt ] || [ ! -f /etc/caddy/certs/sky-lang.org.key ]; then
    echo "  ERROR: /etc/caddy/certs/sky-lang.org.{crt,key} missing" >&2
    echo "  Generate a Cloudflare Origin cert (CF dashboard → SSL/TLS →" >&2
    echo "  Origin Server → Create Certificate), save the cert as" >&2
    echo "  deploy/certs/origin.crt and the key as deploy/certs/origin.key," >&2
    echo "  then re-run ./deploy/deploy.sh." >&2
    exit 1
fi

sudo mv /tmp/Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy || sudo systemctl restart caddy


echo "[3/5] systemd unit"
sudo mv "/tmp/${SERVICE}.service" "/etc/systemd/system/${SERVICE}.service"
sudo systemctl daemon-reload


echo "[4/5] restart ${SERVICE}"
sudo systemctl enable "$SERVICE"
sudo systemctl restart "$SERVICE"


echo "[5/5] wait for ready"
# Give the binary a few seconds to bind :8000 before the deploy
# script runs its smoke probe. systemd's startup notifications are
# the cleaner pattern but require systemd.notify shim — for v1 we
# just sleep.
for i in $(seq 1 10); do
    if curl -sf --max-time 1 http://localhost:8000/healthz >/dev/null; then
        echo "  ${SERVICE}: ready"
        exit 0
    fi
    sleep 1
done

echo "  ${SERVICE}: did NOT come up within 10s — dumping last logs"
sudo journalctl -u "$SERVICE" --no-pager --lines=30
exit 1
