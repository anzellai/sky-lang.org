# Cloudflare Origin certificate

Drop the cert + private key here as:

- `origin.crt` — the public cert (PEM-encoded, contains `-----BEGIN CERTIFICATE-----`)
- `origin.key` — the private key (PEM-encoded, contains `-----BEGIN PRIVATE KEY-----`)

Both files are git-ignored — they never enter version control.

## How to get them

1. Sign in to your Cloudflare dashboard.
2. Pick the `sky-lang.org` zone.
3. **SSL/TLS → Origin Server → Create Certificate**.
4. Defaults are fine (RSA 2048, 15-year validity, hostnames
   `*.sky-lang.org` + `sky-lang.org`).
5. Copy the `Certificate` block into `origin.crt` and the
   `Private Key` block into `origin.key` (the dashboard only
   shows the private key ONCE — save it before closing).
6. Re-run `./deploy/deploy.sh --project <project> --account <admin>` —
   the script uploads both files to the VM and Caddy picks them up.

After the first successful deploy, switch the Cloudflare SSL/TLS mode
to **Full (strict)** so CF verifies the origin cert end-to-end.
