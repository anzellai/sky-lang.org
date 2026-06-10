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
SKY_VERSION="${SKY_VERSION:-0.16.20}"
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


echo "[1b/5] sky toolchain (only when SKY_CONSOLE_EMBED=on)"
# Skip when the .env has SKY_CONSOLE_EMBED=off — the e2-micro tier
# can't run the sky console subapp without OOMing (it Go-builds
# itself on first launch, peaking ~1 GB RAM). GCP-native Cloud
# Logging / Monitoring / Trace below replaces it.
if grep -qE '^SKY_CONSOLE_EMBED=on' "$APP_DIR/.env"; then
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
else
    echo "  SKY_CONSOLE_EMBED=off — skipping sky+Go install (Ops Agent handles observability below)"
fi


echo "[1c/5] Google Cloud Ops Agent (Cloud Logging / Monitoring / Trace)"
# Production observability for sky-lang.org runs entirely through
# GCP-native services — no in-process console UI is needed and the
# e2-micro tier can't host one anyway.
#
# What the agent does on this VM:
#   * Logs:    tails `journalctl -u sky-lang-org` → Cloud Logging.
#              Sky emits structured JSON (SKY_LOG_FORMAT=json) so
#              every level/message/req-id/span-id field is indexable.
#   * Metrics: scrapes localhost:8000/_sky/metrics every 30s with
#              the SKY_ADMIN_TOKEN bearer → Cloud Monitoring's
#              prometheus.googleapis.com namespace.
#   * Traces:  receives OTLP/gRPC on localhost:4317 → Cloud Trace.
#              The app exports via OTEL_EXPORTER_OTLP_ENDPOINT.
#
# Cost: free tier (50 GB/mo logs, std VM metrics free, 150 MB/mo
# custom metrics free, 2.5M spans/mo). The default Compute Engine
# service account already has logging.logWriter + monitoring.metric
# Writer + cloudtrace.agent roles; no IAM changes needed.
if ! systemctl is-enabled google-cloud-ops-agent >/dev/null 2>&1; then
    echo "  installing Google Cloud Ops Agent"
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    sudo bash add-google-cloud-ops-agent-repo.sh --also-install --remove-repo >/dev/null
    rm -f add-google-cloud-ops-agent-repo.sh
fi


echo "[1d/5] Ops Agent config (logs + Prometheus scrape + OTLP)"
# Extract SKY_ADMIN_TOKEN from the .env and stash it as a sidecar
# file the agent reads at scrape time. Keeping it OUT of the YAML
# config means rotation = restart-agent + rewrite-this-file; no
# editor needs to touch the secret inline.
ADMIN_TOKEN="$(grep -E '^SKY_ADMIN_TOKEN=' "$APP_DIR/.env" | head -1 | cut -d= -f2-)"
if [ -z "$ADMIN_TOKEN" ]; then
    echo "  WARN: SKY_ADMIN_TOKEN not in .env — Ops Agent metrics scrape will fail in production mode"
fi
sudo install -m 0640 -o root -g root /dev/null /etc/google-cloud-ops-agent/sky-metrics-token >/dev/null 2>&1 || true
sudo mkdir -p /etc/google-cloud-ops-agent
printf '%s' "$ADMIN_TOKEN" | sudo tee /etc/google-cloud-ops-agent/sky-metrics-token >/dev/null
sudo chmod 0640 /etc/google-cloud-ops-agent/sky-metrics-token

# Read the bearer token inline so the prometheus receiver can pick it
# up. (Ops Agent's prometheus receiver doesn't support credentials_file
# in current schema — the token has to be inline. The token file kept
# above remains the source of truth for rotation.)
TOKEN_INLINE="$(cat /etc/google-cloud-ops-agent/sky-metrics-token)"

sudo tee /etc/google-cloud-ops-agent/config.yaml >/dev/null <<EOF
# Generated by sky-lang.org/deploy/setup-remote.sh — edits will be
# overwritten on next deploy. Customise via the source script.
#
# The OTLP receiver lives under the \`combined:\` section (Ops Agent
# 2.37.0+) because a single OTLP socket multiplexes BOTH metrics and
# traces — both downstream pipelines reference the same receiver:
#   https://docs.cloud.google.com/monitoring/agent/ops-agent/otlp
#
# Cloud destinations:
#   * sky_journal  → Cloud Logging
#   * sky_prom     → Cloud Monitoring (prometheus.googleapis.com/*)
#   * otlp metrics → Cloud Monitoring (managed Prometheus mode)
#   * otlp traces  → Cloud Trace
combined:
  receivers:
    otlp:
      type: otlp
      grpc_endpoint: 0.0.0.0:4317
logging:
  receivers:
    sky_journal:
      type: systemd_journald
  service:
    pipelines:
      sky:
        receivers: [sky_journal]
metrics:
  receivers:
    sky_prom:
      type: prometheus
      config:
        scrape_configs:
          - job_name: sky-lang-org
            scrape_interval: 30s
            metrics_path: /_sky/metrics
            authorization:
              type: Bearer
              credentials: "${TOKEN_INLINE}"
            static_configs:
              - targets: ['localhost:8000']
  service:
    pipelines:
      sky:
        receivers: [sky_prom]
      otlp:
        receivers: [otlp]
traces:
  service:
    pipelines:
      otlp:
        receivers: [otlp]
EOF
# Lock the config (contains the inline bearer token).
sudo chmod 0640 /etc/google-cloud-ops-agent/config.yaml
sudo systemctl restart google-cloud-ops-agent
# Filter to sky-lang-org.service happens at query time in Logs
# Explorer / `gcloud logging read`:
#     resource.labels.instance_name="sky-lang-org"
#     AND jsonPayload._SYSTEMD_UNIT="sky-lang-org.service"
# (The agent indexes _SYSTEMD_UNIT automatically — no agent-side
# filter needed.)


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
