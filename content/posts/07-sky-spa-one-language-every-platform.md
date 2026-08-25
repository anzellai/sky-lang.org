---
title: One language, every platform
slug: sky-spa-one-language-every-platform
date: 2026-08-24
author: Anzel Lai
summary: Sky.Live put the whole web app on the server — one language, no separate frontend. But some apps want the loop on the client: offline, native, low-latency. So the same Model / update / view you write for Sky.Live now compiles to wasm and runs on the client, and ships from one source to web, desktop, iOS and Android. This is the story of Sky.Spa — the auto-split that shares types without symlinks, the native APIs you can extend yourself, and the honest line about what wasm is not.
---

# One language, every platform

Elm gave me one language for the frontend. It never pretended to give me the backend — that was always someone else's problem, in someone else's language, with a hand-maintained protocol module symlinked across the fence.

[Sky.Live](/blog/if-it-compiles-it-works) took the other road: put the **whole** app on the server. The `Model`, the `update`, the `view` — all of it runs server-side, and the browser holds a thin SSE wire that streams DOM diffs down and events up. One language, one binary, no separate frontend, no protocol to keep in sync because there are no two sides. For most web apps that is exactly right, and it is still the default I reach for.

But *most* is not *all*. Some apps want the loop on the client. An editor that has to feel instant. A tool that keeps working on a plane. A thing that lives on a phone and wants the camera. For those, a round-trip per keystroke is the wrong shape — you want the `update` to run **where the user is**.

The trouble is that the moment you split the loop, you are back to two sides and one protocol. That is the tax Sky.Live existed to abolish, and I was not going to re-introduce it by hand.

## The same loop, compiled twice

Here is the thing I kept circling back to: a Sky `Model / Msg / update / view` is not web-specific. It is a pure state machine. Sky.Live happens to run it on a server; nothing about the *program* says it has to.

So **Sky.Spa** runs it on the client. You write the same four functions, and the whole TEA loop compiles to `GOOS=js GOARCH=wasm` and executes in the browser. A pure `update` branch — toggle a filter, open a menu, edit a draft — resolves entirely client-side, zero round-trip. The view is the same `Std.Ui` tree you would render anywhere else.

```elm
import Std.Spa as Spa

main =
    Spa.app (Spa.config
        { init = init, update = update
        , view = view, subscriptions = subs
        , routes = [ Spa.route "/" () ]
        , notFound = ()
        })
```

That is the whole entry point. If you have written a Sky.Live app, you have already written a Sky.Spa app.

## The split I did not want to write by hand

A client loop still needs a server for the effectful parts — the database read, the authenticated mutation, the thing that must not run in a browser. And the client and the server have to agree, exactly, on the shape of every message that crosses between them. This is the symlinked-protocol-module problem, and it is where hand-rolled full-stack setups quietly rot.

The compiler does it for you. Point it at one project and it derives three artefacts:

- a **wasm frontend** — the pure branches of your loop,
- a **stateless backend** — the effectful branches, lifted out,
- and a **shared codec contract** that both sides are checked against.

The effectful branches become typed RPCs; the pure ones stay client-local. You never write the serialization, and you never maintain a shared module, because there is exactly one source of truth and the compiler generates the plumbing from it. If the client and server ever disagreed about a type, it would not compile — which is the only guarantee I actually trust.

And you don't run the split by hand. `sky run src/Main.sky` *is* the command — it sees the `Spa.app` entry, derives + builds the frontend and backend, and starts the server, which serves the frontend and the RPC endpoints same-origin from one binary. `sky build` produces the same two artefacts without running them, and the flags compose — `sky build --embed --target ios` bundles PostgreSQL into the backend and builds the frontend as an iOS shell. (`sky spa-split` is still there as the explicit form when you want the generated trees kept at a path you choose.)

## A phone is not a browser tab

Once the loop runs on the client, "the client" stops meaning "a browser." The same wasm app wraps into a desktop window, an iOS app, an Android app — **one source, four shipping targets**. And a real app on a real device wants real device capabilities.

**`Std.Native`** exposes them as ordinary typed effects — the same `Task Error a` shape as every other effect in Sky, so there is no new mental model:

```elm
copy : String -> Task Error ()
paste : () -> Task Error String
```

Clipboard, local storage, geolocation, share sheet, vibrate, battery, online status, language, dark-mode, open-URL, and file / photo / camera pickers — each a typed effect, each backed by a real platform API on iOS and Android and a sensible web fallback.

The part I care about most is the part I *didn't* hard-code. I am never going to ship every native capability every app will ever want — Apple Pay, a specific BLE peripheral, some vendor SDK. So **`Native.bridge`** is a user-extensible primitive: a Sky library can ship its own `native/ios/*.swift` and `native/android/*.java` alongside entitlement and manifest fragments, register its own capability, and another project pulls it in with `sky add` + `import` — no compiler change, no fork. Extending the platform is a library, not a patch.

## The honest line

Two things I want to be precise about, because precision is the whole point of this language.

**Sky.Spa compiles to wasm, not to server-rendered HTML.** That is a real difference. For the open web — SEO, first-paint on a cold connection, a page that must work with scripting disabled — **Sky.Live is still the primary target**, and I expect it to stay that way. Reach for Sky.Spa when you specifically want a client-side loop: offline behaviour, native-feeling latency, or a native shell that shares its types with a backend.

**And it is experimental.** The examples run on web, iOS and Android; the auto-split is checked end-to-end; the native bridge is real. But this is the first release of it, `Native.bridge`'s extensibility surface will move, and I would rather tell you that than have you find it out on a deadline.

What is not experimental is the shape of the promise: one language, one model, and — when an app genuinely needs to leave the server — every platform, from the same source.

Examples `60-spa-todos` through `64-spa-native` are in the repo, screenshots and all. Go break them, and tell me what you find.
