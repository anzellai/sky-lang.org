---
title: Diagrams that cannot drift
slug: diagrams-that-cannot-drift
date: 2026-09-13
author: Anzel Lai
summary: Every architecture diagram I have ever drawn was out of date the week after I drew it, because it lived in a different file from the code and nothing kept them honest. So Sky generates them from the compiler's own view of the program. Four diagrams — a C4 container map, a data-flow diagram with a real trust boundary, a state machine of the user journey, and a data-egress inventory — read straight from the typed IR, as PlantUML or a self-drawn SVG, so they cannot say something the code does not. Good enough for an architecture deep-dive, and for a SOC2 or ISO review.
---

# Diagrams that cannot drift

I have drawn a lot of architecture diagrams. Every one of them was a lie within a week.

Not a deliberate lie. The diagram was true when I drew it. Then the code moved — a module grew a database call, an endpoint started reading a field it did not read before, a "we do not log that" quietly became "we log that" — and the diagram did not move, because it lived in a different file, in a different tool, and nothing connected the two. A diagram maintained by hand is a comment maintained by hand: correct at birth, wrong by adolescence, and trusted the whole time.

The compiler does not have this problem. It already holds a complete, current, typed model of the program — every module, every effect, every message, every route, every table. If a diagram is *read from that model*, it cannot drift, because there is nothing to keep in sync. It is a view of the code, generated on demand, the same way [`sky doc`](/blog/if-it-compiles-it-works) generates the API reference from the source instead of from a hand-written table.

So that is what `sky doc --diagram` is. And I have spent the last while making the output good enough to actually use — not a sketch you glance at, but the diagram you put in an architecture deep-dive, and the one that stands up in a SOC2 or ISO review. Four diagrams, each answering exactly one question, each read straight from the resolved program. None of them can tell you something the code does not.

They render as **PlantUML** by default, which any free tool or online renderer turns into SVG or PNG; as a **table** with `--format md`; or as a **self-contained SVG** we draw ourselves, with no external tool. `--out` writes to a file. And they adapt to what the app *is* — a Sky.Spa client, a Sky.Live server, a terminal app, or a headless HTTP service — so the picture is honest for each shape.

## What the app is made of

```bash
sky doc --diagram components
```

This is a **C4 container diagram**. It draws the trust boundaries as they actually are: an untrusted browser zone holding the client, a trusted server zone holding the backend, and an external zone for the third parties you call. Inside the server it shows the data stores — with the **real table names**, read from your `Std.Db` schema, not a generic "database" box — the audit-and-logs egress sink, and an auth marker on the `/_rpc` crossing. It makes the client/server split concrete: the pure UI actions that stay in the browser, and the count of effectful actions that cross the wire to the backend.

It is derived from the *same effect analysis* the [auto-split](/blog/sky-spa-one-language-every-platform) uses to decide what runs where, so the diagram and the split can never disagree. For a Sky.Live app it drops the browser zone and shows a single trusted server; for a terminal app, a single local process. The shape changes; the honesty does not.

## What crosses the wire

```bash
sky doc --diagram wire
```

This is a **data-flow diagram**, and it is the one I built first, because I had just been burned by the thing it makes visible. In [the last post](/blog/the-tests-i-did-not-write) I described a bug where a split app's generated RPC request silently dropped a field, and the shipping cost came back zero. The request was invisible — I never wrote it, the compiler derived it — so the dropped field was invisible too.

`wire` makes the invisible request visible. It draws the client and the server either side of a dashed trust boundary, and an **Endpoints** section that tables every `/_rpc` endpoint: the request (the model fields that branch reads, plus its message arguments), the response (the fields it writes), and the effect families it reaches. A missing read is now a thing you can *see*.

It does not stop at `/_rpc`. It also finds the raw HTTP endpoints — a Stripe webhook mounted with `App.api "POST /webhooks/stripe"`, say — and draws the third party as an external entity whose data flows *inbound* across the trust boundary. That is exactly the entry point a security review asks about, and it used to be invisible in this picture. Now it is a labelled arrow crossing the line.

## How a user moves through it

```bash
sky doc --diagram journey
```

This is a real **state machine**. The pages the app declares are states, and the messages that navigate between them are the transitions — recovered from the routes and the `update`, never guessed. Several messages that go to the same page collapse onto one labelled edge, so it stays legible instead of turning into a wall of overlapping labels.

Then it splits the rest of the actions the way [the effect boundary](/blog/if-it-compiles-it-works) already splits them: the **pure** actions that only change client state, and the **effectful** actions that reach the server — each annotated with the effect families it touches. A page whose navigation target is computed at run time is marked dynamic, not invented; a terminal app with no pages shows the pure-and-effectful inventory instead of a bare "no pages." It is the map of the product, not the code, and it is the same source of truth as the other three.

## What it knows about you

```bash
sky doc --diagram telemetry
```

The last one is a **data-egress inventory**, and I think it is the one that will matter most to the most people. It lists every place the app tracks or logs something, and where that something goes — grouped into internal logs, external analytics, and consent state, so an auditor reads it as "what behavioural data leaves this system, and to where." Not "here is our privacy policy" — here is, mechanically, every call site in your own code that emits data, complete and current by construction.

If you have ever had to answer "what personal data does this service record, and where does it end up," you know that grepping and hoping is not an answer. This is the answer, and it updates itself when the code changes.

## The honest line

Each diagram is read-only and conservative by design. It never type-checks beyond the shared load, never lowers, never builds, never writes a file — it looks at the program and reports. Where it cannot be certain, it says so rather than guessing.

That conservatism is the whole point. A diagram you cannot trust is worse than no diagram, because you act on it. These you can trust for exactly one reason: they are not a description of the code kept beside it, they are a view of the code computed from it. When the code changes, they change. They cannot drift, because there is nothing to drift from.

Run them on your own app — `sky doc --diagram components`, `wire`, `journey`, `telemetry` — as PlantUML, a table, or an SVG. Point them at something real and see what your program actually does, as opposed to what you remember it doing.
