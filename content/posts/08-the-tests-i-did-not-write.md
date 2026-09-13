---
title: The tests I did not write
slug: the-tests-i-did-not-write
date: 2026-09-13
author: Anzel Lai
summary: "If it compiles, it works" was always half a promise. The compiler catches the errors it can see in the types. It cannot see a dropped field in an RPC that still type-checks, or a handler that panics on an input a user can actually send. Those you find in production, or you find them with tests you have to write by hand. This is the story of the tests Sky now writes for you — a differential fuzzer with a free oracle, a model fuzzer that folds random messages through your update, mocks derived from your own effect boundary, and a command that scaffolds the fixtures from the types.
---

# The tests I did not write

The promise of this language is "if it compiles, it works." I believe it, and I have spent two years making it more true. But it was always half a promise, and I want to be honest about the other half.

The compiler catches the errors it can *see in the types*. A wrong shape, a missing case, a `Result String` where an `Error` belongs. What it cannot see is a value that is the right *type* and the wrong *answer*. An RPC request that type-checks but drops a field the server needed. A handler that is perfectly well-typed and still panics on an input a user can actually send. Those are not compile errors. You find them in production, or you find them with tests you write by hand.

I found one of them in production.

## The bug that passed everything

An app I run has a shop. Change your delivery region, and the shipping cost recalculates. It shipped. It type-checked, it built, it deployed, every existing test was green — and switching region did nothing. The recalculation ran against an empty basket every time, so the cost came back zero.

The cause was invisible by design. This app is a [Sky.Spa](/blog/sky-spa-one-language-every-platform) app: I write one `Model` / `update` / `view`, and the compiler splits it into a pure wasm client and a stateless backend, deriving the RPC contract between them from which fields each branch reads and writes. That derivation is the feature. It was also the bug: the analysis under-approximated the read-set for that one branch, so the generated request left the basket behind. Nothing was mistyped. The request was a valid request. It was just missing a field, and a missing field is a silent wrong answer, which is the exact class of failure this language exists to prevent.

No test caught it because writing that test means writing an oracle — a second, independent statement of what the right answer is — and nobody writes an oracle for "the shipping cost after you change region." It is too specific and too boring, so it does not get written, and that is precisely where the bug lives.

So I stopped thinking about how to write that test, and started thinking about why the machine could not write it for me.

## A free oracle

It could. For a split app there are already **two** implementations of `update`: the reference one you wrote, and the one that runs across the client/server split. If the split is correct, they must agree for every input. That is an oracle that costs nothing, because I did not have to write it — the two sides already exist, and "they must be equal" is the whole specification.

`sky spa-diff-fuzz` is that check. It generates random reachable `(Model, Msg)` pairs, runs `update` directly and again through the split plumbing — build the request from the read-set, reconstruct the server model, apply the write-set delta back — and asserts the resulting models are identical. A dropped read diverges the two paths on the first input that touches the missing field. No hand-written oracle. No real credentials, because the effects are stubbed to the same deterministic value on both sides, so any divergence comes from the plumbing, not the world.

I wired it as a gate with a deliberately nasty test: a mutation that reintroduces the region bug. The gate goes red on it. The class of failure that reached production now cannot reach a commit.

## For the apps that have no other side

The differential fuzzer needs two implementations to compare, so it only works on split apps. Most of my apps are [Sky.Live](/blog/if-it-compiles-it-works) — the whole loop on the server, no split, nothing to diff against. They needed a different net.

Here it is, and it is almost embarrassingly simple. Any Sky app is a `Model`, a `Msg` type, and an `update`. A client can send *any* `Msg`, in any order — that is what a client is. So `sky fuzz` derives a value generator from your own `Msg` union, folds random `Msg` sequences from `init ()` through the real `update`, and asserts one thing: no unclassified panic. Every sequence is a valid input by construction, so there is nothing to hand-write and nothing to seed.

It does not prove your app is *correct*. It proves the reducer is *total* — that no reachable sequence of messages, however hostile or out of order, can crash it. That is a smaller claim than correctness and a much larger one than most apps can make, and it is free.

I ran it at the account screen of a forum example — eleven message constructors, upvotes and sign-ins and comment submissions, two hundred random sequences — and it drove every one without a panic, classifying each bad sign-in as a permission error rather than falling over. I ran it at a voting app backed by SQLite, offline, against a throwaway database the runner spun up and threw away. And I ran it at a signup-and-email-verification state machine, five hundred sequences, deliberately feeding it the cruel cases: entering a code before signing up, submitting a code while still anonymous, resending when there is nothing to resend. It stayed total. To prove the net is not vacuous, I gave one app an `update` branch that divides by zero — the fuzzer caught it and failed, naming the classified panic. A net that only ever passes is not a net.

## Mocks you do not write, from a boundary you did not draw twice

A fuzzer proves the loop is safe. A *scenario* — a customer pays, the webhook arrives, the order is finalised — is a different kind of test, and it needs the app's effects to run without a live world. No real network, no shared database, a fixed clock.

Sky owns its effect boundary. Every effect is a typed kernel — `Db`, `Http`, `Time`, `Random`, `Auth` — so the toolchain can supply a test world for its *own* effects automatically. Turn on test mode and outbound HTTP is intercepted at the transport: a request that matches a fixture gets the fixture's canned response, and a request that matches nothing **fails closed**. That last part is the good part. The default in a test is not "the call succeeds"; it is "the call errors," so your failure path runs for free, on every call you have not explicitly decided should succeed. A `[database]` app gets a throwaway database provisioned for the run. A seed makes `Random` and `Uuid` reproducible, so a generated code or token is predictable. A fixed clock stops time.

With that in place, the happy path of a real payment flow runs entirely offline: a synthetic signed webhook, verified against the same secret the app checks, turning a pending cart into exactly one order, idempotent on redelivery — the whole thing green in a test, no payment provider, no account, no network. I have that test. It runs in under a second and it never pages me.

## The part the compiler can write, that I kept writing by hand

The one thing you still supply is the mock fixture: which URL, which method, and a response body. And I noticed I was writing those by reading my own code to find the outbound calls — which is exactly the kind of thing the compiler already knows, because it can see every typed `Http` call in the program.

So it writes them now. `sky test --scaffold-mocks` walks the app's outbound HTTP boundary and drops a fixture skeleton for each call under `tests/mocks/`, with the method and a host-independent URL match already filled in. It handles the shapes real code actually uses — a direct `Http.get`, a piped request builder, a URL built as `base ++ "/path"` where it takes the literal path as the match. On the shop app I mentioned, one command produced fixtures for all three of its payment-provider endpoints, methods and paths correct, and left me exactly one blank to fill: the response body, where I paste a captured payload.

## The honest line

Two things, because precision is the whole point.

**Automatic and authored are different tiers, and I am not going to blur them.** The fuzzers are automatic: split-correctness and reducer-totality are proven with no test code, on any app. The *scenario* — the specific claim that a paid checkout becomes one finalised order — is a test you write. The substrate makes it run offline and deterministically, but only you know what the right outcome is. That one is worth writing, and now it is cheap to.

**A mock tests your model of a service, not the service.** A fixture proves your app handles the shape you believe the provider sends. It cannot prove the provider still sends that shape. For an external API you do not control, a captured *real* payload in the fixture is the most faithful body you can use, and a periodic check against the real sandbox is the thing that catches the provider drifting. Auto-derivation shines where you own both sides — an internal service, your own API — and there it is a clean win.

What is not experimental is the shape of the promise, extended by one clause. It used to be: if it compiles, it works. It is now: if it compiles, it works — and the machine will fuzz the parts the types cannot see, and write the scaffolding for the parts you test by hand.

The commands are `sky fuzz`, `sky spa-diff-fuzz`, and `sky test --scaffold-mocks`, and they are documented in [testing a Sky project](https://github.com/anzellai/sky/blob/main/docs/tooling/testing.md). Point them at your app and tell me what they find.
