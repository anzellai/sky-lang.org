# System architecture (C4 containers) — sky-lang-org · generated 2026-09-15

App shape: Sky.Spa (wasm client + server over /_rpc)

## Containers

| Container | Trust zone | Technology | Responsibility |
|---|---|---|---|
| Browser client | Untrusted (client) | wasm (Sky.Spa) | Renders the UI; 10 pure client action(s); reaches the server over `/_rpc`. |
| Application server | Trusted (server) | native Go (Sky.Spa SSR) | Serves `/_rpc`; runs EVERY effect; 5 effectful action(s). |
| External HTTP APIs | Untrusted (third-party) | HTTPS | Payments / OAuth / mail etc. — see `sub-processors.md` for the named register. |

## Appendix — modules

_Source modules and the capability families each reaches (the C4 code level; the containers above are what an auditor reads first)._

| Module | Capabilities |
|---|---|
| Auth.Allowlist | Env/Config |
| Auth.Console | Database, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Auth.Csrf | Env/Config |
| Auth.DevLogin | Database, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Auth.Github | Database, External HTTP, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Auth.Session | Database, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Db.Conn | Database, Env/Config, Telemetry/Logs |
| Db.Posts | Database, Env/Config, Telemetry/Logs |
| Db.Roadmap | Database, Env/Config, Telemetry/Logs |
| Db.Schema | Database, Telemetry/Logs |
| Db.Sessions | Database, Env/Config, Telemetry/Logs |
| Db.SsoLogins | Database, Env/Config, Telemetry/Logs |
| Main | Database, External HTTP, File, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Markdown | — |
| Model.Request | Database, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Msg | — |
| Routes | — |
| Seed | Database, File, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| Server.Actions | Database, Env/Config, Telemetry/Logs, Time/Random/Uuid |
| State | — |
| Subs | — |
| Update | — |
| View.Admin | — |
| View.AdminPost | — |
| View.Blog | — |
| View.Common | — |
| View.Home | — |
| View.NotFound | — |
| View.Response | — |
| View.Seo | — |

> Analytics has no distinct kernel family; it is folded into Telemetry/Logs (Std.Log).
> Sky.Spa: every effect runs on the server; the client (wasm) reaches it over /_rpc.
