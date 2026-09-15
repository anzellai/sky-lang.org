# Wire — API & call-paths — sky-lang-org

The Sky.Spa auto-split turns every SERVER `update` branch into a `POST /_rpc/<Msg>` endpoint. The REQUEST is the Model fields the branch reads plus the Msg args; the RESPONSE is the Model fields it writes. **Access** is the endpoint's auth requirement; **Call-path** is the effect families it reaches and their targets.

## RPC endpoints (/_rpc)

| Endpoint | Access | Request (reads + args) | Response (writes) | Call-path |
|---|---|---|---|---|
| POST /_rpc/ConfirmDelete | CSRF | {editorSlug} | {editorBody, editorSlug, editorSummary, editorTitle, flash, page, posts} | Db → database · Log · System · Time |
| POST /_rpc/EditorPublish | CSRF | {editorBody, editorMode, editorSlug, editorSummary, editorTitle, session} | {editorBody, editorSlug, editorSummary, editorTitle, flash, page, posts} | Db → database · Log · System · Time |
| POST /_rpc/EditorSaveDraft | CSRF | {editorBody, editorMode, editorSlug, editorSummary, editorTitle, session} | {editorBody, editorSlug, editorSummary, editorTitle, flash, page, posts} | Db → database · Log · System · Time |
| POST /_rpc/LoadEditPost | CSRF | {editorSlug} | {currentPost, editorBody, editorMode, editorSlug, editorSummary, editorTitle, flash, page} | Db → database · Log · System |
| POST /_rpc/LoadPosts | CSRF | whole model | {posts} | Db → database · Log · System |

## HTTP endpoints (raw `App.api`, beside /_rpc)

> ⚠ These are CSRF-exempt — reached by a third party (webhook / API client), outside the session contract. Verify each authenticates its caller.

| Method | Path | Handler / page | Kind |
|---|---|---|---|
| GET | /admin/auth/callback | Auth.Github.handleCallback | raw api · CSRF-exempt |
| GET | /admin/console-link | Auth.Console.handleConsoleLink | raw api · CSRF-exempt |
| GET | /admin/dev-login | Auth.DevLogin.handleDevLogin | raw api · CSRF-exempt |
| GET | /admin/login | Auth.Github.handleLogin | raw api · CSRF-exempt |
| GET | /admin/logout | Auth.Github.handleLogout | raw api · CSRF-exempt |
| GET | /healthz | Main.handleHealthz | raw api · CSRF-exempt |
| GET | /robots.txt | Main.handleRobots | raw api · CSRF-exempt |
| GET | /sitemap.xml | Main.handleSitemap | raw api · CSRF-exempt |

> The `HTTP endpoints` are raw `App.api` routes: reached by a third party (a webhook sender, an API client), OUTSIDE the session/CSRF contract, and CSRF-exempt.
