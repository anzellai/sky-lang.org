# Deploy bundle — sky-lang.org

## One-time GCP setup

```bash
# Enable Compute Engine
gcloud services enable compute.googleapis.com \
    --project <project> --account <admin>

# Create the VM (e2-micro Always Free tier)
gcloud compute instances create sky-lang-org \
    --project <project> --account <admin> \
    --zone us-central1-a \
    --machine-type e2-micro \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size 30GB --boot-disk-type pd-standard \
    --tags http-server,https-server \
    --metadata enable-oslogin=TRUE

# Open :80 + :443 on the VM's network (here: default network)
gcloud compute firewall-rules create default-allow-http \
    --project <project> --account <admin> \
    --network default --direction INGRESS --action ALLOW \
    --rules tcp:80,tcp:443 --source-ranges 0.0.0.0/0 \
    --target-tags http-server,https-server
```

## One-time Cloudflare setup

1. Add `sky-lang.org` to Cloudflare; switch nameservers.
2. Add an A record: `sky-lang.org` → VM's external IP (orange-cloud / proxy ON).
3. Generate a CF Origin cert pair — see `deploy/certs/README.md`.
4. Place `origin.crt` + `origin.key` in `deploy/certs/`.
5. After first successful deploy, switch **SSL/TLS → Overview** to **Full (strict)**.

## Deploy

```bash
./deploy/deploy.sh --project <project> --account <admin>
```

Flags: `--instance` (default `sky-lang-org`), `--zone` (default
`us-central1-a`), `--env-file` (default `./.env.production`),
`--skip-build`, `--dry-run`.

## What lands on the VM

| Path | What |
|---|---|
| `/opt/sky-lang-org/app` | Cross-compiled Linux/amd64 Sky.Live binary |
| `/opt/sky-lang-org/.env` | Production env (chmod 600) |
| `/opt/sky-lang-org/sky.toml` | Sky project metadata |
| `/opt/sky-lang-org/brand/` | Logo + favicon + OG assets (Caddy serves directly) |
| `/opt/sky-lang-org/content/` | Markdown post seeds |
| `/opt/sky-lang-org/static-fallback/` | Served when app is down (5xx) |
| `/var/lib/sky-lang-org/` | SQLite DB + Litestream WAL |
| `/etc/caddy/Caddyfile` | Reverse proxy config (HTTPS :443, redirect :80 → :443) |
| `/etc/caddy/certs/sky-lang.org.{crt,key}` | Cloudflare Origin cert pair |
| `/etc/systemd/system/sky-lang-org.service` | systemd unit |

## Architecture

```
Browser ──HTTPS──▶ Cloudflare ──HTTPS──▶ Caddy :443 ──HTTP──▶ Sky.Live :8000
              (CF edge cert)        (CF Origin cert)
```

- Browser → CF: HTTPS, TLS terminated at CF edge with their universal cert.
- CF → Caddy: HTTPS over :443 with the CF Origin cert installed on the VM
  (CF SSL mode: **Full (strict)** — CF validates the cert end-to-end).
- Caddy :80 → 308 redirect → :443 so direct HTTP visitors get HTTPS too.
- Caddy → Sky.Live: plain HTTP loopback on :8000 (no TLS needed within the VM).
- Caddy serves `/brand/*` + 5xx-fallback directly (no app round-trip).

## Notes

- `gcloud compute scp` requires `gcloud` ≥ 463; older versions
  use a different `--tunnel-through-iap` default that breaks
  the upload step.
- The first deploy enrols the VM in OS-Login automatically via
  the `enable-oslogin=TRUE` metadata. Subsequent deploys re-use
  the cached SSH key pair under `~/.ssh/google_compute_engine*`.
- Caddy is installed from the upstream `cloudsmith.io` repo
  (Debian's `caddy` package is older and lacks the
  `handle_response` directive used in the Caddyfile).
- The Caddyfile is **idempotent on reload** — `systemctl reload caddy`
  applies new config without dropping in-flight connections.
