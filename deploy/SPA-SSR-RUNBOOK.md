# sky-lang.org → Sky.Spa + SSR deploy runbook

Status as of the SPA-SSR compiler work (Sky main `03d339da`): sky-lang.org
**builds `--target web:app` end-to-end** and SSR-serves real, crawlable per-route
content (verified locally: `/` and `/blog` return HTTP 200 with real post
titles/bodies in the HTML and a `#sky-model` blob populated with all published
posts). The client wasm tree is DB-free (the server resolves the GET-safe `init`
read and embeds the model; the client decodes it and hydrates — no re-fetch).

What the compiler now does for this app:
- `App.app { … } |> App.withRoutes (pageRoutes ++ apiRoutes) |> App.withHead …`
  auto-splits into a wasm frontend + a stateless backend + shared codecs.
- **Page routes** (`App.route`/`routeParam`) render client-side AND server-render
  (SSR) per route; **`App.api` routes** are mounted backend-only.
- `App.withHead` per-route `<head>` is carried into the SSR HTML (SEO).
- A GET-safe `init` read (e.g. `Db.query`) runs on the backend at request time,
  its result is embedded in `#sky-model`, and the client boots from it.

## Build

```
cd sky-lang.org
sky build --target web:app src/Main.sky
# → .skyapp/web-app/.split/{frontend/dist (main.<hash>.wasm + index.html + wasm_exec.js),
#                            backend/sky-out/app}
```

The site also still builds as Sky.Live (`sky build src/Main.sky`) — keep that as
the fallback until the SPA deploy is validated in a browser.

## Deploy — `deploy.sh --spa` (Option A: backend serves the frontend same-origin)

The deploy script has an opt-in SPA mode. It builds the split, cross-compiles the
backend, and lands `backend/app` + `frontend/dist` under a dedicated VM root so
the backend's `Server.static "/" "../frontend/dist"` resolves. The default Sky.Live
`--embed` path is unchanged.

```
# from the repo root
DEPLOY_MODE=spa ./deploy/deploy.sh --project <gcp-project> --account <admin>
#   equivalently: ./deploy/deploy.sh --spa --project <gcp-project>
```

What it does, mirroring the Live path where possible:

1. **Build** — `sky build --target web:app src/Main.sky` → the split under
   `.skyapp/web-app/.split/`, then cross-compiles the backend Go module
   (`CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, `-ldflags -X sky-app/rt.skyVersion`).
2. **Package** — `frontend/dist/` (index.html + `main.<hash>.wasm` + `wasm_exec.js`
   + `brand/`, which the compiler copied in from the WebConfig `static="brand"`
   declaration) as `sky-lang-org-dist.tgz`; plus `content/` + `static-fallback/` in
   the existing asset bundle (brand is NOT re-tarred separately in SPA mode — it is
   already inside dist).
3. **Upload + install** — reuses the existing scp + `setup-remote.sh` (now
   `DEPLOY_MODE`-aware), the SPA systemd unit (`deploy/sky-lang-org-spa.service`),
   and the SPA reverse-proxy config (`deploy/Caddyfile.spa`).

### Remote layout (VM)

Service `sky-lang-org-spa`, install root `/opt/sky-lang-org-spa` (isolated from the
Live install at `/opt/sky-lang-org`, so both can coexist on one VM — but they share
`:8000`, so only one runs at a time):

```
/opt/sky-lang-org-spa/
  backend/app          <- ExecStart; WorkingDirectory = here
  backend/sky.toml
  frontend/dist/        <- index.html + main.<hash>.wasm + wasm_exec.js + brand/
  static-fallback/      <- Caddyfile.spa 5xx fallback
  content/              <- markdown seeds for the out-of-band seed step
  .env                  <- EnvironmentFile (verbatim from .env.production)
/var/lib/sky-lang-org-spa/pgdata   <- embedded-PostgreSQL cluster (SPA-owned)
```

### Database — embedded PostgreSQL (`--embed`)

The split backend carries the **same embedded-PostgreSQL runtime** as the Live
binary (its emitted `main.go` calls `rt.MaybeStartEmbeddedPostgres` /
`rt.StopEmbeddedPostgres`), so `--embed` composes with the split. The SPA unit runs
`ExecStart=/opt/sky-lang-org-spa/backend/app --embed` and overrides `SKY_DATA_DIR`
to the SPA-owned `pgdata` (systemd `Environment=` after `EnvironmentFile=`, so the
verbatim `.env` is never mutated). `SKY_POSTGRES_BIN` is shared from `.env`.

> **Alternative — external managed DSN.** If you prefer a managed cluster (Cloud SQL
> / RDS), drop `--embed` from the SPA unit's `ExecStart` and set `DATABASE_URL` +
> `SKY_LIVE_STORE=postgres` in the env file. (Staging validated this shape; embedded
> was chosen for prod to keep the DB story identical to the Live unit and reuse
> `setup-remote.sh`'s PostgreSQL provisioning unchanged.) Do NOT set both `--embed`
> and an explicit DSN — the runtime treats that as an error.

### The pieces the auto-split does NOT carry (do these by hand at cutover)

1. **Session store** was `App.withConfig … SharedWithDatabase`. With `--embed` the
   backend uses the embedded PostgreSQL cluster for sessions + blog data. If you go
   the external-DSN route, set `SKY_LIVE_STORE=postgres` explicitly, or the split
   backend falls back to an in-memory store (single-instance, lost on restart).

2. **`?sso=<token>` session pickup** was `App.withRequest Model.Request.applyRequest`,
   dropped by the App→Spa synthesis. Re-express it as an `App.api` route on the split
   backend that consumes the one-time `sso_logins` token and mints the session cookie
   before the SSR settle. (Unblocked: the split backend mounts `App.api` routes.)

3. **Schema migrate + seed — MANDATORY on a fresh SPA cluster.** The split
   **replaces `main`**, so the app's `bootstrap` (`Schema.migrate` +
   `Seed.syncFromDisk`) does NOT run on the split backend. The SPA install starts
   with an EMPTY `pgdata`, so before/at first cutover run migrate + seed out-of-band
   against `/var/lib/sky-lang-org-spa/pgdata` (e.g. `sky db migrate` + a seed step,
   or run the Live binary once against that data dir). `content/` is shipped to
   `/opt/sky-lang-org-spa/content` for the seed step.

### BROWSER hydration validation (before switching prod DNS/cutover)

Serve the split backend with `.split/frontend/dist` same-origin, load `/` and `/blog`
in a real browser, and confirm: first paint shows real content (`data-sky-ssr` on
`#app`); the wasm client hydrates with **no flash / no content flip**; the Network
tab shows **no `/_rpc` (or DB) re-fetch** after boot (client used `#sky-model`, not a
re-run of `init`); `sky-nav` client routing + forms + admin `/_rpc/*` round-trip.

### Deploy + verify live

`curl https://sky-lang.org/` and `/blog` show SSR content + `#sky-model`;
`/healthz`, `/robots.txt`, `/sitemap.xml` OK (api routes); admin sign-in + a post
write via `/_rpc/*`; clean hydration in a browser. The prod env gate is preserved
(`ENV=production`, `SKY_CONSOLE_AUTH`/token, `SKY_ADMIN_TOKEN`,
`SKYLANG_SESSION_SECRET`) exactly as the Live path sets it — the same `.env.production`
is uploaded.

## Manual steps at first-time SPA cutover

- **First-time embedded PostgreSQL provision + migrate + seed** against
  `/var/lib/sky-lang-org-spa/pgdata` (see DB note above). The systemd unit install +
  service (re)start are automated by `setup-remote.sh`; the schema/seed are not.
- **Confirm `/healthz` is an `App.api` route on the split** — `deploy.sh`'s verify
  step and `setup-remote.sh`'s readiness probe both poll `:8000/healthz`. If it is
  not wired as an api route, both will report the service as not-ready even though
  it is up.

## Rollback

The Sky.Live build is unchanged and green (`sky check src/Main.sky`), and its install
root (`/opt/sky-lang-org`, service `sky-lang-org`) is untouched by an SPA deploy. If
anything in the SPA path misbehaves, a bare `./deploy/deploy.sh` (Live `--embed`)
restores the current production behaviour immediately. To fully switch back, stop
`sky-lang-org-spa` and start `sky-lang-org` (they contend for `:8000`).
