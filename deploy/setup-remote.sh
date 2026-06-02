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
SKY_VERSION="${SKY_VERSION:-0.15.55}"

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
