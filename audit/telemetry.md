# Telemetry — sky-lang-org

Everything this app tracks or logs, and where it goes — one row per telemetry / analytics / logging call site.

| Module | Call | Event | Sink |
|---|---|---|---|
| Auth.Console | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Auth.DevLogin | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Auth.Github | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Auth.Github | Log.println | [AUTH] CSRF state mismatch on /admin/auth/callback | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Db.Conn | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Db.Schema | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Main | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Main | Log.println | [BOOT] sky-lang.org ready | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Main | Log.println | [FATAL] SKYLANG_SESSION_SECRET is empty — refusing to start | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Seed | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |
| Server.Actions | Log.println | <dynamic> | structured logs (console; OTel when OTEL_EXPORTER_OTLP_ENDPOINT set) |

> Log and Analytics are effect kernels: under a Sky.Spa split they run on the server, reached from the wasm client over /_rpc.
> Detection covers direct `Std.Log` / `Std.Analytics` call sites in the project's own modules; a call routed through a user helper is listed at that helper.
