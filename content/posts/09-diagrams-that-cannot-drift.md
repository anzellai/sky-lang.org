---
title: Diagrams that cannot drift
slug: diagrams-that-cannot-drift
date: 2026-09-13
author: Anzel Lai
summary: Every architecture diagram I have ever drawn was out of date the week after I drew it, because it lived in a different file from the code and nothing kept them honest. So Sky generates them from the compiler's own view of the program. Four diagrams, each answering one question — what the app is made of, what crosses the RPC wire, what it tracks about you, and how a user moves through it — read straight from the typed IR, so they cannot say something the code does not.
---

# Diagrams that cannot drift

I have drawn a lot of architecture diagrams. Every one of them was a lie within a week.

Not a deliberate lie. The diagram was true when I drew it. Then the code moved — a module grew a database call, an endpoint started reading a field it did not read before, a "we do not log that" quietly became "we log that" — and the diagram did not move, because it lived in a different file, in a different tool, and nothing connected the two. A diagram maintained by hand is a comment maintained by hand: correct at birth, wrong by adolescence, and trusted the whole time.

The compiler does not have this problem. It already holds a complete, current, typed model of the program — every module, every effect, every message, every route. If a diagram is *read from that model*, it cannot drift, because there is nothing to keep in sync. It is a view of the code, generated on demand, the same way [`sky doc`](/blog/if-it-compiles-it-works) generates the API reference from the source instead of from a hand-written table.

So that is what `sky doc --diagram` is. Four diagrams, each answering exactly one question, each read straight from the resolved program. None of them can tell you something the code does not.

## What the app is made of

```bash
sky doc --diagram components
```

The first one is the map you would draw on a whiteboard on someone's first day: every module in `src/`, and the external capabilities each one reaches — database, outbound HTTP, auth, file, config, telemetry, jobs, realtime, and the clock-and-randomness family. It is deliberately not a per-function hairball; it is one node per capability, so it stays readable.

The useful part is that it is derived from the *same effect analysis* the [auto-split](/blog/sky-spa-one-language-every-platform) uses to decide what runs where. For a client app it draws the client lane and the server lane with the RPC boundary between them, and because it reuses the split's own classification, the diagram and the split can never disagree. A module that touches a database shows it, whether or not you remembered that it does.

## What crosses the wire

```bash
sky doc --diagram wire
```

This is the one I built first, because I had just been burned by the thing it makes visible. In [the last post](/blog/the-tests-i-did-not-write) I described a bug where a split app's generated RPC request silently dropped a field, and the shipping cost came back zero. The request was invisible — I never wrote it, the compiler derived it — so the dropped field was invisible too.

`wire` makes the invisible request visible. For every server branch that becomes an RPC endpoint, it shows the request (the model fields that branch reads, plus its message arguments) and the response (the fields it writes). A missing read is now a thing you can *see* — a field you expected in the request column that is not there. The bug that cost me a production afternoon would have been a glance at a table.

The fuzzer from the last post is the net that catches that class automatically. This diagram is the thing that lets a human catch it by eye, and lets a reviewer understand a contract they never wrote.

## What it knows about you

```bash
sky doc --diagram telemetry
```

The third one is a privacy inventory, and I think it is the one that will matter most to the most people. It lists every place the app tracks or logs something, and where that something goes. Not "here is our privacy policy" — here is, mechanically, every call site in your own code that emits data, read from the program, so it is complete and current by construction.

If you have ever had to answer "what personal data does this service record, and where does it end up," you know that answering it by grepping and hoping is not an answer. This is the answer, and it updates itself when the code changes.

## How a user moves through it

```bash
sky doc --diagram journey
```

The last one is the user's-eye view: the pages the app declares, and the actions a user can take, each annotated with whether it round-trips to the server or runs on the client, and which page it navigates to. It is recovered from the routes and the `update` — the constructors a branch assigns to the page field — never guessed. It is the map of the product, not the code, and it is the same source of truth as the other three.

## The honest line

Each diagram is read-only and conservative by design. It never type-checks beyond the shared load, never lowers, never builds, never writes a file — it looks at the program and reports. Where it cannot be certain, it says so rather than guessing: a `journey` action whose navigation target is computed at run time is marked dynamic, not invented. A `wire` diagram of a Sky.Live app tells you plainly that a server-driven app's "wire" is the SSE channel, not an RPC contract, instead of drawing a contract that does not exist.

That conservatism is the whole point. A diagram you cannot trust is worse than no diagram, because you act on it. These you can trust for exactly one reason: they are not a description of the code kept beside it, they are a view of the code computed from it. When the code changes, they change. They cannot drift, because there is nothing to drift from.

Run them on your own app — `sky doc --diagram components`, `wire`, `telemetry`, `journey`. They render as Mermaid, or as a table with `--format md`. Point them at something real and see what your program actually does, as opposed to what you remember it doing.
