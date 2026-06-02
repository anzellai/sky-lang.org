---
title: If it compiles, it works
slug: if-it-compiles-it-works
date: 2026-06-03
author: Anzel Lai
summary: "If it compiles, it works" is a slogan a dozen languages have used. In Sky Lang it's a contract — defined precisely, enforced by three release gates, and load-bearing for every decision the language makes. Here's what the contract says, how it's enforced, and the bug class that proved removing a single line of CSS can close five filed bugs.
---

# If it compiles, it works

Every typed language has used some version of *"if it compiles, it works"* as a slogan. Most of them quietly include a footnote: *"works for some definition of works."* The escape hatches accumulate. `any` types creep in. Errors become `string`. JSON parses into `interface{}`. The promise that drew you to the language eight months ago has, in production, become indistinguishable from the promise of TypeScript.

Sky Lang treats *"if it compiles, it works"* as a contract. The contract has three load-bearing parts, each enforced by a release gate, each one a hard "no ship" if it goes red. The whole language is designed downstream of those three gates.

This post walks through the contract, the gates, and a case study from this week that demonstrates why the contract matters more than any single feature in the language.

---

## What the contract says

Three claims, in order of increasing demand:

### 1. If the type checker accepts your program, every value has a precise type at every point — no `any` injected behind your back

Sky Lang's type system is Hindley-Milner with full inference. Every binding, every record field, every list element, every lambda argument, every call site has a real type by the time codegen runs. The compiler propagates types *through* lambda bodies, *into* record-field initialisers, *across* call boundaries, including the FFI to Go. If a value enters Sky Lang as `Int` from Stripe's `Charge.Amount` field, it's still `Int` when it lands in your `view` function — the type doesn't degrade to `any` because something upstream got fancy.

The non-negotiable: **the compiler never silently widens.** When Sky Lang's type-directed lowering hits a slot where it doesn't have enough information, it errors. It doesn't decide *"I'll just call this `any` and hope downstream handles it."* That decision is what makes typed TypeScript indistinguishable from untyped TypeScript at runtime; Sky Lang refuses to make it.

### 2. If it compiles AND your program runs without crashing in the test suite, it does not crash in production from the same input class

Every runtime panic class has a regression test in `runtime-go/rt/*_test.go` or `test/Sky/**Spec.hs`. Division-by-zero, type-coercion failure in heterogeneous slices, index-out-of-range from cons-pattern walking, nil-deref from optional FFI returns, ComparisonMismatch between sum-type constructors — every one of these has a named spec that fails if the class re-opens. The Go runtime has a top-level `defer rt.LogPanicAndExit()` in `func main()` that classifies any panic that reaches it, emits a structured Error log line with a 4-byte correlation ID, and exits 1 — so the panic class becomes telemetry, not a black-screen crash.

The non-negotiable: **a new release that re-introduces a closed panic class fails CI.** It's not enough to fix a panic — the regression spec is the discovery artefact and stays in the test suite forever.

### 3. If the type system AND runtime regression specs both pass, your application built from a wiped slate produces the same result as the build in CI

Every release rebuilds every example from `rm -rf sky-out .skycache .skydeps && sky build`. That step lives in `scripts/example-sweep.sh`, runs in CI on every push, and is one of the three release gates (the others being `cabal test` and `scripts/verify-ui-showcase.sh`). If a build is reproducible only from a warm cache, that's a bug — files might be stale, embedded markers might be wrong, the binary you shipped to production might disagree with the source you tagged. The sweep closes the gap.

The non-negotiable: **no release tag is cut while the sweep is red.** Not for a "nice to have" feature, not for a hotfix, not for a follower's pull request. The example sweep is the contract's third leg.

That's the whole contract. Three claims, three gates. Everything else in Sky Lang's design — the typed FFI, the `Result Error a` everywhere convention, the typed crypto and auth primitives, the `Task Error a` effect boundary, the input-authority protocol in Sky.Live — exists to keep one of those three claims true under one or another class of attack.

---

## How the contract gets attacked

In production, the contract gets attacked in three flavours:

1. **Type system holes.** Something the AI generates or a contributor adds gets through the type checker even though it shouldn't have. (Counter: type soundness regressions go in `test/Sky/Type/`.)
2. **Runtime panic classes.** A new code path hits a Go primitive that panics without going through the typed wrappers. (Counter: regression spec in `runtime-go/rt/*_test.go`.)
3. **Build-environment dependencies.** A change works on the developer's warm cache but breaks from a clean slate. (Counter: example sweep + clean-slate enforcement.)

The interesting case is when a bug looks like one class but is actually another. *That's* what happened with GitHub issue #63.

---

## The case study — issue #63

Issue #63 was filed in May. A contributor reported that placing an `Input.multiline` inside a `Ui.row` with `Ui.fill` didn't fill — the textarea collapsed to ~22 px tall instead of filling the row's vertical space.

The first fix attempt (v0.14.7) added a `flex-grow: 1` propagation pass to the renderer. It closed the reported case but a new variant surfaced two days later. We added more CSS. Then more. Five releases between v0.14.7 and v0.14.16 each added CSS to compensate for the prior fix's incompleteness. The class wouldn't close.

In v0.15.36 (early May) I tried again — this time with a deeper propagation rewrite. The reported case from #63 worked, the regression Playwright assertion landed, the issue closed.

Two weeks later the contributor came back. *"In a `Ui.row` it still doesn't work."*

That second report was the moment to stop patching.

I spent three days building a 108-cell behavioral matrix — every Std.Ui primitive against every length spec against every parent-direction against every cross-cutting attribute. For each cell I built an isolated Sky Lang example, lowered it, opened it in headless Chromium, measured the computed style, and classified PASS / FAIL / PARTIAL. The matrix surfaced five distinct failure families. Family F1 was the contributor's report.

The root cause of F1 was a single line in `sky-stdlib/Std/Ui.sky`'s `heightFillFor` function. The line emitted `height: 100%` alongside `align-self: stretch` for cross-axis fill. Under standard CSS Flexbox the `height: 100%` is redundant — `align-self: stretch` already does the cross-axis work. But §9.8 of the Flexbox spec ("indefinite-size resolution") says: if a flex item's parent has a flex-grow-derived height and the item declares `height: 100%`, the parent re-enters indefinite-size resolution and collapses to its content height.

So: the explicit `height: 100%` told the browser "ignore that my parent grew via flex; size me to 100% of an indefinite height," which collapsed everything upstream. The previous five fixes had all *added* CSS to work around the symptom — propagation passes, conditional flex-grow injections. The actual fix was to *remove* the line.

I removed it. The whole F1 family closed. Five filed bugs, gone with one delete. v0.15.55 shipped that fix, plus the architectural follow-up (F2, the `Input.*` `wrapWithLabel` attrs split). The contributor's exact repro now measures 768 × 1248 px on a 800 × 1280 viewport.

---

## What the case study proves

The contract isn't *"we don't have bugs."* Sky Lang has plenty. The contract is *"when a bug surfaces, we find the class, not the instance."*

The instance is what gets filed. The class is what causes the next four instances. If you patch only what was filed, you guarantee the next four arrivals; if you find the class, you close all five (and the five that haven't been filed yet) at once.

In an AI-co-development workflow, this matters more, not less. The AI will generate variations on every shape it sees. If your fix only closes the one variation, the AI's *next* prompt produces the next variation. If your fix closes the class, the AI generates the variations and they all work because the class is closed underneath. The contract scales linearly with reports; the class-fix scales sub-linearly.

This is the principle I refuse to break, and it's the principle the contract enforces. Every release gate makes "patch the symptom" harder than "find the class." The cabal regression specs fail if the class re-opens, even if the original instance is "fixed." The runtime panic class log won't let you silence a panic without classifying it. The clean-slate sweep won't let you ship a fix that only worked because of a warm cache.

---

## What this means if you're considering Sky Lang

The contract is the thing I want you to bet on. Not the syntax, not the stdlib breadth, not the deploy platform. Those are downstream of the contract.

If you ship a product on Sky Lang, you're betting that:

- The AI you're co-developing with can't accidentally hand you `any`-typed surprises that survive `sky build`
- The bugs you find in the wild get tracked, classified, and class-closed — not whacked-a-moled
- The release you tag today produces the same binary tomorrow, on a fresh CI runner, from a clean checkout

You're also betting on one person who's done this for twelve weeks straight, and who treats the principle of *"find the class, not the instance"* as load-bearing infrastructure, not a value statement.

I won't pretend Sky Lang is the most mature language you could pick. It isn't. But it's the most disciplined language I know how to build, and the discipline is in service of the contract that this post is named after.

If you're shipping with AI, "if it compiles, it works" is the only contract that scales. Languages that *aspire* to it but don't *enforce* it leave you with the same problem you had with TypeScript, dressed up in better syntax. The enforcement is the entire point.

Sky Lang enforces it. Build with me, or build with someone else — but please don't pick a language that promises the contract and then quietly hands you `any`.

---

*Anzel · [sky-lang.org](https://sky-lang.org) · [github.com/anzellai/sky](https://github.com/anzellai/sky) · v0.15.56 shipped 2026-06-02*
