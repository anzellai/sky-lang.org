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

## Remaining steps to a live SPA-SSR deploy

These are the pieces the auto-split does NOT carry from the Live app — do them on
the **split backend**:

1. **Session store (was `App.withConfig … SharedWithDatabase`)** — set on the
   backend env (same as the current Live deploy):
   `SKY_LIVE_STORE=postgres` + the session-store DSN. Without it the split backend
   defaults to an in-memory store (single-instance, lost on restart).

2. **`?sso=<token>` session pickup (was `App.withRequest Model.Request.applyRequest`)**
   — `App.withRequest` is dropped by the App→Spa synthesis. Re-express it as an
   `App.api` route on the split backend that consumes the one-time `sso_logins`
   token and mints the session cookie before the SSR settle. (Now unblocked: the
   split backend mounts `App.api` routes as of the api-route partition fix.)

3. **Schema migrate + seed** — the split **replaces `main`**, so the app's
   `bootstrap` (`Schema.migrate` + `Seed.syncFromDisk`) does NOT run on the split
   backend. Run migrate + seed out-of-band before/at deploy (e.g. a one-shot
   `sky db migrate` + a seed step against the same DSN).

4. **DSN** — the split `backend/sky.toml` drops `[database] embedded = true`; the
   backend reads `DATABASE_URL`/the DSN from env. Provide embedded PG on the VM
   (as today) or a managed DSN.

5. **BROWSER hydration validation (do this before switching prod)** — serve the
   split backend with `.split/frontend/dist` same-origin, load `/` and `/blog` in
   a real browser, and confirm:
   - first paint shows real content (`data-sky-ssr` on `#app`),
   - the wasm client hydrates with **no flash / no content flip**,
   - the **Network tab shows no `/_rpc` (or DB) re-fetch** after boot (i.e. the
     client used `#sky-model`, not a re-run of `init`),
   - `sky-nav` client routing + forms + admin `/_rpc/*` round-trip.

6. **Switch `deploy.sh`** — point the deploy at the split artifacts:
   server binary = `.skyapp/web-app/.split/backend/sky-out/app`; static root =
   `.split/frontend/dist` (served same-origin by the backend). Keep the prod env
   (`ENV=production`, `SKYLANG_SESSION_SECRET`, `SKY_CONSOLE_AUTH`/token,
   `SKY_ADMIN_TOKEN`) + steps 1–4 above.

7. **Deploy + verify live** — `curl https://sky-lang.org/` and `/blog` show SSR
   content + `#sky-model`; `/healthz`,`/robots.txt`,`/sitemap.xml` OK (api routes);
   admin sign-in + a post write via `/_rpc/*`; clean hydration in a browser.

## Rollback

The Sky.Live build is unchanged and green (`sky check src/Main.sky`). If anything
in the SPA path misbehaves, `deploy.sh` on the Live binary restores the current
production behaviour immediately.
