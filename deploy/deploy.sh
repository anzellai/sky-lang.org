#!/usr/bin/env bash
#
# sky-lang.org — deploy/update the Sky.Live app on a GCE VM.
#
# All hosting parameters come from CLI flags or env vars — no
# project / account / zone / instance is hardcoded, so this script
# is safe to run from any fork.
#
# Required:
#   --project   <id>        gcloud project ID (or env: SKYLANG_GCP_PROJECT)
#
# Optional (with sensible defaults):
#   --account   <email>     gcloud account to use (default: gcloud's default)
#                           (or env: SKYLANG_GCP_ACCOUNT)
#   --instance  <name>      VM name              (default: sky-lang-org)
#   --zone      <zone>      GCE zone             (default: us-central1-a)
#   --user      <user>      SSH user on the VM   (default: gcloud OS-Login default)
#   --env-file  <path>      local env file to upload as the VM's /opt/.../env
#                           (default: ./.env.production)
#   --service   <name>      systemd unit name    (default: sky-lang-org)
#   --skip-build            skip the local sky build (use existing sky-out/app)
#   --dry-run               print the gcloud commands without executing them
#
# Examples:
#   ./deploy/deploy.sh --project my-gcp-project
#   ./deploy/deploy.sh --project my-gcp-project --account me@example.com \
#                      --instance sky-prod --zone europe-west1-b
#
set -euo pipefail


usage() {
    sed -n '/^# /,/^$/p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}


# ─── argument parsing ────────────────────────────────────────────────
PROJECT="${SKYLANG_GCP_PROJECT:-}"
ACCOUNT="${SKYLANG_GCP_ACCOUNT:-}"
INSTANCE="sky-lang-org"
ZONE="us-central1-a"
SSH_USER=""
ENV_FILE="./.env.production"
SERVICE="sky-lang-org"
SKIP_BUILD=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --project)    PROJECT="$2";    shift 2 ;;
        --account)    ACCOUNT="$2";    shift 2 ;;
        --instance)   INSTANCE="$2";   shift 2 ;;
        --zone)       ZONE="$2";       shift 2 ;;
        --user)       SSH_USER="$2";   shift 2 ;;
        --env-file)   ENV_FILE="$2";   shift 2 ;;
        --service)    SERVICE="$2";    shift 2 ;;
        --skip-build) SKIP_BUILD=1;    shift ;;
        --dry-run)    DRY_RUN=1;       shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

[ -n "$PROJECT" ] || { echo "ERROR: --project is required (or set SKYLANG_GCP_PROJECT)" >&2; usage 1; }
[ -f "$ENV_FILE" ] || { echo "ERROR: env file not found: $ENV_FILE" >&2; exit 1; }


# nix-shell sometimes leaks a stale TMPDIR pointing at a folder that
# vanishes when the parent shell exits — defaulting to /tmp keeps
# sky build + go build happy.
if [ -z "${TMPDIR:-}" ] || [ ! -d "$TMPDIR" ]; then
    export TMPDIR=/tmp
fi


# ─── derived paths ───────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy"
BIN_NATIVE="$REPO_ROOT/sky-out/app"
BIN_LINUX="/tmp/sky-lang-org-linux"
ENV_REMOTE="/tmp/sky-lang-org.env"
ASSETS_TGZ="/tmp/sky-lang-org-assets.tgz"

cd "$REPO_ROOT"


# ─── helper wrappers ─────────────────────────────────────────────────
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "+ $*"
    else
        echo "+ $*"
        "$@"
    fi
}

GCLOUD_FLAGS=( --project "$PROJECT" )
[ -n "$ACCOUNT" ] && GCLOUD_FLAGS+=( --account "$ACCOUNT" )


# ─── build ───────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "==> 1/5  build + cross-compile (linux/amd64)"
    # `sky build` emits the native binary for the local platform.
    sky build src/Main.sky

    # Cross-compile the Go output for the VM. Preserve the sky version
    # via -ldflags so /_sky/buildinfo reports the real tag instead of
    # 'dev' on the VM. Fallback: pin to the SKY_VERSION default that
    # setup-remote.sh uses.
    SKY_VER=$(sky --version 2>/dev/null | sed -E 's/^sky[[:space:]]*v?//')
    if [ -z "$SKY_VER" ] || [ "$SKY_VER" = "dev" ]; then
        SKY_VER=$(grep -oE 'SKY_VERSION=\$\{SKY_VERSION:-([0-9.]+)\}' \
            "$DEPLOY_DIR/setup-remote.sh" \
            | head -1 | sed -E 's/.*:-([0-9.]+)\}/\1/' || echo "")
        [ -n "$SKY_VER" ] && echo "    (local sky reports 'dev'; pinning to v$SKY_VER from setup-remote.sh)"
    fi
    [ -n "$SKY_VER" ] || SKY_VER="dev"

    ( cd sky-out
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
          go build -ldflags "-X sky-app/rt.skyVersion=$SKY_VER" \
          -o "$BIN_LINUX" .
    )
else
    echo "==> 1/5  build skipped (--skip-build)"
    [ -x "$BIN_NATIVE" ] || { echo "ERROR: $BIN_NATIVE not found; rebuild first" >&2; exit 1; }
    # When skipping build, still cross-compile from the existing
    # sky-out/ Go source (sky build leaves it in place).
    ( cd sky-out
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$BIN_LINUX" .
    )
fi


# ─── stage env + assets ──────────────────────────────────────────────
echo "==> 2/5  stage env + asset bundle"

# The env file goes to the VM as-is. Do NOT mutate (the source of
# truth is the local .env.production).
cp "$ENV_FILE" "$ENV_REMOTE"

# Tar the static folders (brand assets + seed content markdown).
# Skip if neither exists.
TAR_INPUTS=()
[ -d "$REPO_ROOT/brand" ] && TAR_INPUTS+=( brand )
[ -d "$REPO_ROOT/content" ] && TAR_INPUTS+=( content )
[ -d "$REPO_ROOT/static-fallback" ] && TAR_INPUTS+=( static-fallback )
if [ ${#TAR_INPUTS[@]} -gt 0 ]; then
    tar -czf "$ASSETS_TGZ" -C "$REPO_ROOT" "${TAR_INPUTS[@]}"
    echo "    asset bundle: ${TAR_INPUTS[*]}"
else
    rm -f "$ASSETS_TGZ"
fi


# ─── upload ──────────────────────────────────────────────────────────
echo "==> 3/5  upload to ${INSTANCE}.${ZONE}"

SCP_FILES=(
    "$BIN_LINUX"
    "$ENV_REMOTE"
    "$REPO_ROOT/sky.toml"
    "$DEPLOY_DIR/Caddyfile"
    "$DEPLOY_DIR/${SERVICE}.service"
    "$DEPLOY_DIR/setup-remote.sh"
)
[ -f "$ASSETS_TGZ" ] && SCP_FILES+=( "$ASSETS_TGZ" )

# Cloudflare Origin cert pair (optional first run; required once
# Caddy is configured for end-to-end HTTPS). Uploads as /tmp/origin.*
# so setup-remote.sh can install them to /etc/caddy/certs/.
CERT_LOCAL="$DEPLOY_DIR/certs/origin.crt"
KEY_LOCAL="$DEPLOY_DIR/certs/origin.key"
if [ -f "$CERT_LOCAL" ] && [ -f "$KEY_LOCAL" ]; then
    # Stage as /tmp uploads with the right basename
    cp "$CERT_LOCAL" /tmp/origin.crt
    cp "$KEY_LOCAL"  /tmp/origin.key
    chmod 600 /tmp/origin.key
    SCP_FILES+=( /tmp/origin.crt /tmp/origin.key )
    echo "    bundling Cloudflare Origin cert + key"
elif [ -f "$CERT_LOCAL" ] || [ -f "$KEY_LOCAL" ]; then
    echo "ERROR: only one of deploy/certs/origin.{crt,key} found" >&2
    echo "       both must be present together" >&2
    exit 1
else
    echo "    no deploy/certs/origin.{crt,key} — assuming already installed on VM"
fi

SCP_TARGET="$INSTANCE:/tmp/"
[ -n "$SSH_USER" ] && SCP_TARGET="${SSH_USER}@${SCP_TARGET}"

run gcloud compute scp "${SCP_FILES[@]}" "$SCP_TARGET" \
    --zone "$ZONE" "${GCLOUD_FLAGS[@]}"


# ─── install + restart on the VM ─────────────────────────────────────
echo "==> 4/5  install + (re)start on ${INSTANCE}"

SSH_TARGET="$INSTANCE"
[ -n "$SSH_USER" ] && SSH_TARGET="${SSH_USER}@${SSH_TARGET}"

run gcloud compute ssh "$SSH_TARGET" --zone "$ZONE" "${GCLOUD_FLAGS[@]}" --command "
    set -e
    cd /tmp
    sudo SERVICE='$SERVICE' bash /tmp/setup-remote.sh
"


# ─── verify ──────────────────────────────────────────────────────────
echo "==> 5/5  verify"
run gcloud compute ssh "$SSH_TARGET" --zone "$ZONE" "${GCLOUD_FLAGS[@]}" --command "
    set +e
    curl -sf --max-time 5 http://localhost:8000/healthz || { echo 'app   healthz FAILED'; exit 1; }
    echo 'app   healthz OK (localhost:8000)'
    # Caddy on :80 redirects → :443; verify HTTPS healthz with -k (Caddy
    # serves the CF Origin cert which is not in the OS trust store).
    curl -skf --max-time 5 https://localhost/healthz || { echo 'caddy healthz FAILED'; exit 1; }
    echo 'caddy healthz OK (localhost:443)'
    sudo systemctl status '$SERVICE' --no-pager --lines=5
"

echo "==> done — sky-lang.org deployed to $INSTANCE ($ZONE / $PROJECT)"
