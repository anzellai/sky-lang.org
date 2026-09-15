# Behaviour & data flow — sky-lang-org · generated 2026-09-15

App shape: Sky.Spa (wasm client + server over /_rpc)

The interaction graph: each page is a state the user sees; each action is an edge out of the page whose view can trigger it, labelled with its lane (`/_rpc` vs client), effect families, the page it navigates to (**bold**), its async continuation (⇢ _Msg_), and a 🔒 marker when the flow carries confidential data (a `Secret`, a `Std.Auth` session, or PII).

**Data store:** App database

## External systems (data sub-processors)

_Third parties the app sends or receives application data to/from (ISO 27001 A.15 / SOC2 supplier evidence)._

| Host | Role | Purpose |
|---|---|---|
| `github.com` | OAuth / IdP | OAuth / API (GitHub) |

## Embedded third-party content

_Static / embedded content (CDN, fonts, video). NOT a data sub-processor — no application data flows to it._

| Host | Purpose |
|---|---|
| `anzellai.github.io` | External service (anzellai.github.io) |

_Excluded as the app's own domain (not a sub-processor): `sky-lang.org`._

## HomePage · `/` (initial)

_No page-specific actions (see Global above)._

## AdminEditPost · `/admin/posts/:slug/edit`

- `EditorBody` client
- `EditorPublish` `POST /_rpc` · Db, Log, System, Time
- `EditorSaveDraft` `POST /_rpc` · Db, Log, System, Time
- `EditorSlug` client
- `EditorSummary` client
- `EditorTitle` client

## AdminHome · `/admin`

- `EditorDelete` client
- `Navigate` client

## AdminLoginPage · `/admin/login`

_No page-specific actions (see Global above)._

## AdminNewPost · `/admin/posts/new`

- `EditorBody` client
- `EditorPublish` `POST /_rpc` · Db, Log, System, Time
- `EditorSaveDraft` `POST /_rpc` · Db, Log, System, Time
- `EditorSlug` client
- `EditorSummary` client
- `EditorTitle` client

## BlogIndex · `/blog`

- `Navigate` client

## BlogPost · `/blog/:slug`

- `Navigate` client

## NotFoundPage

- `Navigate` client

> `server` actions round-trip as `POST /_rpc/<Msg>`; `client` actions run in the browser (wasm). Classification reuses the Sky.Spa auto-split (see `--diagram wire`).
> Server API endpoints (routed, not user pages): GET /admin/auth/callback, GET /admin/console-link, GET /admin/dev-login, GET /admin/login, GET /admin/logout, GET /healthz, GET /robots.txt, GET /sitemap.xml.
