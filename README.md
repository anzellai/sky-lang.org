# sky-lang.org

The reference site for [Sky Lang](https://github.com/anzellai/sky)
— a typed functional language designed for AI-era development —
running on a Sky.Live app that ships from this repo.

This branch (`feat/sky-live-app`) is the Phase 1 implementation of
the [site migration](https://github.com/anzellai/sky-strategy/blob/main/strategy/site-migration.md)
from static GitHub Pages to a self-hosted Sky.Live app. The static
site continues to serve from `main` until the DNS cutover.

## Layout

```
sky-lang.org/
├── sky.toml                # Sky Lang project + deps
├── .env.example            # SKYLANG_* env-var template
├── content/posts/*.md      # Blog post sources (seeded on first boot)
├── src/
│   ├── Main.sky            # Live.app entry + bootstrap
│   ├── State.sky           # Model + Msg + Page
│   ├── Routes.sky          # URL → Page table
│   ├── Update.sky          # TEA dispatch
│   ├── Model.sky           # init (per-request)
│   ├── Subs.sky            # subscriptions
│   ├── Markdown.sky        # Pure-Sky Markdown → HTML
│   ├── Seed.sky            # content/posts/*.md → DB
│   ├── Db/                 # Schema, Posts, Sessions, Roadmap, Conn
│   ├── Auth/               # Github OAuth, Csrf, Session, Allowlist
│   └── View/               # Common, Home, Blog, Admin, AdminPost,
│                           # NotFound, Response (Response builders)
├── deploy/                 # Phase 2 — systemd + Caddyfile lands here
├── static-fallback/        # Caddy fallback page if the app is down
├── brand/                  # SVG + PNG brand assets
└── tests/                  # Sky.Test cases (TBD)
```

## Quick start (dev)

Prerequisites: a Sky Lang compiler at v0.15.56+ on `$PATH`.

```bash
git clone git@github.com:anzellai/sky-lang.org.git
cd sky-lang.org
git checkout feat/sky-live-app

cp .env.example .env
# Edit .env — fill in SKYLANG_GITHUB_CLIENT_ID +
# SKYLANG_GITHUB_CLIENT_SECRET (create an OAuth App at
# https://github.com/settings/developers, callback
# http://localhost:8000/admin/auth/callback), and
# SKYLANG_SESSION_SECRET (e.g. `openssl rand -hex 32`).

sky install            # pull github.com/anzellai/sky-github v0.1.0
sky build src/Main.sky # build a single binary at sky-out/app

set -a && . ./.env && set +a
./sky-out/app          # listens on :8000 by default
```

Boot prints (clean DB):

```
[SCHEMA] applied 0001_posts, 0002_posts_published_idx, … (6 migrations)
[SEED] found 2 markdown files in content/posts
[SEED] inserted + published why-i-built-sky-lang
[SEED] inserted + published if-it-compiles-it-works
[BOOT] sky-lang.org ready
[sky.live] session store: memory (ttl=30m0s)
Sky.Live listening on :8000
```

Then:

- `http://localhost:8000/` — homepage
- `http://localhost:8000/blog/` — post list
- `http://localhost:8000/blog/why-i-built-sky-lang/` — post detail
- `http://localhost:8000/admin/login` — kicks off GitHub OAuth

## Environment variables

See `.env.example` for the canonical list. The `SKYLANG_*`
namespace is app-owned; the `SKY_*` namespace is framework-owned
(`SKY_LIVE_PORT`, `SKY_LOG_LEVEL`, etc).

| Var | Required | Purpose |
|---|---|---|
| `SKYLANG_GITHUB_CLIENT_ID` | yes | OAuth App client ID |
| `SKYLANG_GITHUB_CLIENT_SECRET` | yes | OAuth App secret |
| `SKYLANG_ADMIN_GITHUB_LOGINS` | yes | Comma-separated allowlist |
| `SKYLANG_SESSION_SECRET` | yes | ≥ 32 bytes random (used to sign sky_sid + sky_csrf cookies) |
| `SKYLANG_BASE_URL` | yes | OAuth `redirect_uri` base |
| `SKYLANG_DEV_MODE` | no | `1` skips `; Secure` on cookies for plain-HTTP localhost |
| `SKY_LIVE_PORT` | no | Default 8000 |
| `SKY_LOG_LEVEL` | no | `debug` / `info` / `warn` / `error` |

The bootstrap aliases `SKYLANG_SESSION_SECRET` → `SKY_AUTH_TOKEN_SECRET`
on startup so `Std.Auth.signTokenWithClaims` finds the secret via
its framework reader (Option A from
`sky-strategy/foundation/decisions.md`).

## Schema

Three tables, all created on first boot via `Std.Db.migrate`
(forward-only, checksum-guarded):

- `posts` — id, slug, title, summary, body_md, body_html,
  author_github_login, published_at (NULL = draft), created_at,
  updated_at, deleted_at (NULL = live).
- `admin_sessions` — token_id (PK = JWT `jti`), github_login,
  github_id, created_at, expires_at. Deleting a row is the
  revocation lever.
- `roadmap_items` — schema in place for v2 (no UI yet).

Indexes on `posts.published_at` (DESC, partial), `admin_sessions.expires_at`,
`roadmap_items.(status, ordinal)`.

## Deploy (Phase 2 — Anzel-handled)

`deploy/` holds the systemd unit + Caddyfile + deploy script.
Phase 2 spins up a GCP `e2-micro` under `settleby`'s production
project. See `strategy/site-migration.md`.

## License

Apache 2.0, same as Sky Lang.
