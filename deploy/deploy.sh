#!/usr/bin/env bash
#
# sky-lang.org — deploy/update the app on a GCE VM.
#
# Two deploy modes, selected by --spa / DEPLOY_MODE (default: live):
#
#   live (default) — the Sky.Live `--embed` app. Builds `sky build
#                    src/Main.sky`, cross-compiles the single Go binary,
#                    lands it at /opt/sky-lang-org/app. UNCHANGED behaviour.
#
#   spa            — the Sky.Spa split (SSR backend + wasm frontend served
#                    same-origin). Builds `sky build --target web:app
#                    src/Main.sky`, cross-compiles the split backend, and
#                    lands backend + frontend/dist under /opt/sky-lang-org-spa
#                    (service `sky-lang-org-spa`). See deploy/SPA-SSR-RUNBOOK.md.
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
#   --service   <name>      systemd unit name    (default: sky-lang-org, or
#                           sky-lang-org-spa in --spa mode)
#   --spa                   deploy the Sky.Spa split instead of the Sky.Live
#                           app (or env: DEPLOY_MODE=spa)
#   --skip-build            skip the local sky build (use existing artifacts)
#   --dry-run               print the gcloud commands without executing them
#
# Examples:
#   ./deploy/deploy.sh --project my-gcp-project
#   ./deploy/deploy.sh --project my-gcp-project --account me@example.com \
#                      --instance sky-prod --zone europe-west1-b
#   DEPLOY_MODE=spa ./deploy/deploy.sh --project my-gcp-project
#   ./deploy/deploy.sh --spa --project my-gcp-project
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
SERVICE=""            # defaulted below once the mode is known
MODE="${DEPLOY_MODE:-live}"
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
        --spa)        MODE="spa";      shift ;;
        --live)       MODE="live";     shift ;;
        --skip-build) SKIP_BUILD=1;    shift ;;
        --dry-run)    DRY_RUN=1;       shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown flag: $1" >&2; usage 1 ;;
    esac
done

case "$MODE" in
    live|spa) ;;
    *) echo "ERROR: DEPLOY_MODE must be 'live' or 'spa' (got '$MODE')" >&2; usage 1 ;;
esac

# Default the systemd unit / VM install root from the mode, unless the
# operator pinned one with --service.
if [ -z "$SERVICE" ]; then
    if [ "$MODE" = "spa" ]; then SERVICE="sky-lang-org-spa"; else SERVICE="sky-lang-org"; fi
fi

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
# Std.App web builds emit the Go source + native binary under
# .skyapp/web/sky-out/ (bare `sky build` on a Std.App entry auto-derives the web
# target); the old Sky.Live layout put them directly in sky-out/.
#
# The Sky.Spa split (`sky build --target web:app`) instead emits under
# .skyapp/web-app/.split/{backend/sky-out (Go source + native binary),
# frontend/dist (index.html + main.<hash>.wasm + wasm_exec.js + brand/)}.
if [ "$MODE" = "spa" ]; then
    GO_SRC="$REPO_ROOT/.skyapp/web-app/.split/backend/sky-out"
    DIST_DIR="$REPO_ROOT/.skyapp/web-app/.split/frontend/dist"
    SPLIT_ROOT="$REPO_ROOT/.skyapp/web-app/.split"
    BACKEND_TOML="$REPO_ROOT/.skyapp/web-app/.split/backend/sky.toml"
    DIST_TGZ="/tmp/sky-lang-org-dist.tgz"
else
    GO_SRC="$REPO_ROOT/.skyapp/web/sky-out"
fi
BIN_NATIVE="$GO_SRC/app"
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
    # v0.16.10 #500 — invalidate sky build cache on SKY version bump.
    # Without this, a Sky compiler hot-fix ships the toolchain bump
    # but `sky build` sees "source unchanged" and reuses the cached
    # binary with the OLD embedded runtime.
    CACHE_VERSION_FILE=".skycache/sky-version"
    CURRENT_SKY_VER=$(sky --version 2>/dev/null | sed -E 's/^sky[[:space:]]*v?//')
    [ -z "$CURRENT_SKY_VER" ] && CURRENT_SKY_VER="unknown"
    CACHED_SKY_VER=""
    [ -f "$CACHE_VERSION_FILE" ] && CACHED_SKY_VER=$(cat "$CACHE_VERSION_FILE")
    if [ "$CURRENT_SKY_VER" != "$CACHED_SKY_VER" ]; then
        echo "    sky version changed ($CACHED_SKY_VER → $CURRENT_SKY_VER) — wiping cache"
        rm -rf sky-out .skyapp .skycache .skydeps
    fi
    # The cache wipe above also removes .skydeps (fetched Sky source deps, e.g.
    # sky-github). `sky build` does not auto-fetch missing deps, so re-install
    # before building — idempotent + cheap when deps are already present.
    # Without this, a SKY_VERSION bump wedges the deploy: the build fails
    # "dependency … not fetched", the version marker never gets written, and the
    # next run wipes again.
    sky install
    # `sky build` emits the native binary for the local platform. In spa
    # mode `--target web:app` auto-splits into the wasm frontend + the
    # stateless SSR backend under .skyapp/web-app/.split/.
    if [ "$MODE" = "spa" ]; then
        sky build --target web:app src/Main.sky
    else
        sky build src/Main.sky
    fi
    mkdir -p .skycache
    echo "$CURRENT_SKY_VER" > "$CACHE_VERSION_FILE"

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

    ( cd "$GO_SRC"
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
          go build -ldflags "-X sky-app/rt.skyVersion=$SKY_VER" \
          -o "$BIN_LINUX" .
    )
else
    echo "==> 1/5  build skipped (--skip-build)"
    [ -x "$BIN_NATIVE" ] || { echo "ERROR: $BIN_NATIVE not found; rebuild first" >&2; exit 1; }
    # When skipping build, still cross-compile from the existing
    # sky-out/ Go source (sky build leaves it in place).
    ( cd "$GO_SRC"
      CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$BIN_LINUX" .
    )
fi


# ─── stage env + assets ──────────────────────────────────────────────
echo "==> 2/5  stage env + asset bundle"

# The env file goes to the VM as-is. Do NOT mutate (the source of
# truth is the local .env.production).
cp "$ENV_FILE" "$ENV_REMOTE"

# Tar the static folders. In live mode this carries brand/ (Caddy serves
# it directly) + content/ (seeded at bootstrap) + static-fallback/. In spa
# mode brand/ already lives inside frontend/dist (the compiler copied it in),
# so the asset bundle carries only content/ (used by the OUT-OF-BAND seed
# step — the split backend does not run the app's Seed.syncFromDisk) and
# static-fallback/ (served by Caddyfile.spa on 5xx).
TAR_INPUTS=()
if [ "$MODE" != "spa" ]; then
    [ -d "$REPO_ROOT/brand" ] && TAR_INPUTS+=( brand )
fi
[ -d "$REPO_ROOT/content" ] && TAR_INPUTS+=( content )
[ -d "$REPO_ROOT/static-fallback" ] && TAR_INPUTS+=( static-fallback )
if [ ${#TAR_INPUTS[@]} -gt 0 ]; then
    tar -czf "$ASSETS_TGZ" -C "$REPO_ROOT" "${TAR_INPUTS[@]}"
    echo "    asset bundle: ${TAR_INPUTS[*]}"
else
    rm -f "$ASSETS_TGZ"
fi

# spa mode: package the whole frontend/dist tree (index.html + hashed wasm +
# wasm_exec.js + brand/). It extracts on the VM as frontend/dist next to the
# backend binary, so the backend's `Server.static "/" "../frontend/dist"`
# and Caddyfile.spa's /brand root both resolve.
if [ "$MODE" = "spa" ]; then
    [ -d "$DIST_DIR" ] || { echo "ERROR: split frontend dist not found: $DIST_DIR (build first?)" >&2; exit 1; }
    tar -czf "$DIST_TGZ" -C "$SPLIT_ROOT" frontend/dist
    echo "    frontend bundle: frontend/dist"
fi


# ─── upload ──────────────────────────────────────────────────────────
echo "==> 3/5  upload to ${INSTANCE}.${ZONE}"

# Mode-specific sources. In spa mode we upload the SPLIT backend's sky.toml
# and the SPA Caddyfile (staged as /tmp/Caddyfile so setup-remote.sh's
# generic `/tmp/Caddyfile` move applies unchanged).
if [ "$MODE" = "spa" ]; then
    SKY_TOML_SRC="$BACKEND_TOML"
    cp "$DEPLOY_DIR/Caddyfile.spa" /tmp/Caddyfile
    CADDYFILE_SRC="/tmp/Caddyfile"
else
    SKY_TOML_SRC="$REPO_ROOT/sky.toml"
    CADDYFILE_SRC="$DEPLOY_DIR/Caddyfile"
fi

SCP_FILES=(
    "$BIN_LINUX"
    "$ENV_REMOTE"
    "$SKY_TOML_SRC"
    "$CADDYFILE_SRC"
    "$DEPLOY_DIR/${SERVICE}.service"
    "$DEPLOY_DIR/setup-remote.sh"
)
[ -f "$ASSETS_TGZ" ] && SCP_FILES+=( "$ASSETS_TGZ" )
[ "$MODE" = "spa" ] && SCP_FILES+=( "$DIST_TGZ" )

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
    sudo SERVICE='$SERVICE' DEPLOY_MODE='$MODE' bash /tmp/setup-remote.sh
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

echo "==> done — sky-lang.org deployed to $INSTANCE ($ZONE / $PROJECT) [mode=$MODE service=$SERVICE]"
