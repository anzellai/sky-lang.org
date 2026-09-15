# Audit pack — sky-lang-org

_Generated 2026-09-15 by `sky doc --diagram audit`. Every artefact is derived statically from the app's source — the pure, total TEA `update` makes the behaviour completely enumerable._

| File | Artefact | Maps to |
|---|---|---|
| `journey.svg / journey.md` | Behaviour & data-flow diagram (trust-boundary swimlanes; confidential flows marked) | SOC2 CC3, CC6 · ISO A.8, A.13 |
| `components.svg / components.md` | System architecture (C4 containers, trust zones, protocols) | SOC2 system description · ISO A.14 |
| `wire.md` | API & authentication call-paths (endpoints, CSRF, request/response shapes) | SOC2 CC6, CC7 · ISO A.9, A.14 |
| `telemetry.md` | Audit-logging & monitoring surface | SOC2 CC7 · ISO A.12.4 |
| `data-inventory.md` | Data inventory & classification (Secret / auth / PII at rest) | ISO A.8 |
| `sub-processors.md` | Sub-processors & external systems register | SOC2 supplier controls · ISO A.15 |

> These diagrams reflect the code as of generation. Regenerate on each release so the evidence tracks the system.
