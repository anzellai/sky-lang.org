---
title: The API spec I did not write
slug: the-api-spec-i-did-not-write
date: 2026-09-16
author: Anzel Lai
summary: An OpenAPI spec is a second copy of your API, written by hand or scraped from decorators, and it drifts from the code the moment either one moves. But a Sky app's endpoints and their request and response shapes are already known to the compiler, statically and completely. So Sky derives the whole OpenAPI 3.1 document from the typed source — no annotations, no drift — with real JSON Schema for every payload and the CSRF scheme on the endpoints that need it. It validates clean and imports straight into Swagger UI or a gateway. One command, `sky doc --api openapi`.
---

# The API spec I did not write

Every OpenAPI spec I have ever maintained was a second copy of the truth.

The API lives in the code — the routes, the request bodies, the response shapes. The spec lives in a YAML file, or in a scatter of decorators the framework scrapes into one. Either way it is a *restatement*: a hand-kept description of an API that is defined somewhere else. And a restatement drifts, for the same reason a hand-drawn [architecture diagram](/blog/diagrams-that-cannot-drift) drifts — the code moves, the copy does not, and nobody notices until a client integrates against a field that no longer exists. FastAPI's decorators and springdoc's annotations make the copy easier to keep, but they do not make it stop being a copy. You still write, next to a handler, a second statement of what that handler accepts and returns, and you still have to keep the two honest by hand.

I did not want to keep a copy. The compiler already knows the API.

## Why Sky can just read it off

A Sky app does not hide its API from the compiler. The routes are declared — an `App.api "POST /webhooks/stripe"`, a `Server.listen` handler, a page route. And for a split app, every server-side `update` branch *is* an endpoint: the compiler already derives, from the branch, which model fields it reads (that is the request) and which it writes (that is the response), because it needs exactly that to build the [client/server split](/blog/sky-spa-one-language-every-platform). The endpoints and their shapes are not documented; they are *computed*, statically and totally, from the typed program.

So the OpenAPI document is not authored. It is read off:

```bash
sky doc --api openapi
```

That prints a valid **OpenAPI 3.1** spec of the app's HTTP API, generated from the typed source with not one line of annotation in the code. `--format yaml` (the default) or `--format json`; `--out` writes it to a file. I run it against the real validators — `@redocly/cli` lints it clean, zero errors — and it imports straight into Swagger UI or an API gateway, because it is a spec like any other, only nobody typed it.

## What it puts in the spec

The **paths** are your declared HTTP routes — the primary, intentional API. Beside them it includes the `/_rpc/<Msg>` operations that a Sky.Spa client calls, each **tagged `rpc`** and described for what it is: the framework's internal client-to-server transport, not a public REST endpoint you designed. That distinction matters to whoever reads the spec, so the spec is honest about it — and if you want only the public surface, `--no-rpc` drops the transport and leaves the declared routes. For a headless [`Sky.Http.Server`](/blog/if-it-compiles-it-works) app there is no `/_rpc` at all, and the output is simply the real public API spec, which is the case this is most useful for.

The **schemas** are the real thing, not `object` placeholders. The request schema for an endpoint is the model fields it reads plus the message arguments; the response schema is the fields it writes; and the Sky types map to JSON Schema the obvious way — a record becomes an object with typed properties, a `Maybe a` becomes a nullable `anyOf`, a `List a` an array, a `Uuid` a string with `format: uuid`, a `Secret` a string with `format: password`. Shared shapes are lifted into `components/schemas` and referenced, the way a hand-written spec would do it if you had the patience.

And the **security** is derived too: a `csrfToken` API-key scheme, applied to the session-scoped endpoints that require the double-submit token, so the spec tells an integrator which calls need it. Where auth is enforced inside the app in a way the static read cannot recover, the description says so rather than asserting a scheme that is not there — the same conservatism the diagrams keep.

## The shape of the flag

I wrote it as `sky doc --api <format>`, and the `<format>` is deliberate. OpenAPI is the first contract Sky can read off itself; it is not the only one it could. A `/_rpc` surface, where every message is a typed request/response method, is a gRPC service in all but syntax — `--api proto` is a natural next output, and the flag shape holds the seat for it, alongside `grpc` and `asyncapi` for the streaming and pub/sub surfaces. None of those exist yet. I am not going to pretend they do; the point of this language is that I do not ship the description ahead of the thing. Today `openapi` is real and the rest is a reserved name.

## The honest line

An OpenAPI spec has always been documentation that *wants* to be code and never quite is — a machine-readable contract, kept by hand, trusted by clients, and wrong exactly when it matters. Deriving it removes the "by hand," and with it the whole class of failure where the spec and the server disagree. It cannot happen here, because there is only one artefact: the code, and a view of the code.

It does not spec what the compiler cannot see — a hand-rolled response body assembled outside the typed effect boundary is described as far as the types reach and no further, and it tells you where that edge is. That is the same trade as everywhere else in this language: it will not claim more than it can prove, and everything it does claim, it read from your program a moment ago.

`sky doc --api openapi`. Point it at your app and hand the output to whoever has been asking for a spec.
