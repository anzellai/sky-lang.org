# Phase 2 — GCP provisioning lands here.

This directory will hold:

- `Caddyfile` — reverse proxy with auto-SSL (Let's Encrypt) +
  the static fallback at `/var/www/sky-lang-fallback/`.
- `sky-lang.service` — systemd unit for the Sky.Live app
  (`WorkingDirectory=/var/lib/sky-lang/`, env from
  `/etc/sky-lang/env`).
- `deploy.sh` — `gcloud compute scp` binary + `systemctl
  restart`. Pattern extracted from
  `skydeploy/control-plane/deploy/setup-remote.sh`.
- `litestream.yml` — SQLite → `gs://sky-lang-org-litestream`
  replication.

See `strategy/site-migration.md` §"Phase 2 — GCP provisioning"
for the architecture target.

Anzel handles Phase 2 personally (GCP infra is operational, not
language-development, work).
