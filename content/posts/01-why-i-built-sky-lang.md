---
title: Why I built Sky Lang
slug: why-i-built-sky-lang
date: 2026-06-02
author: Anzel Lai
summary: Twelve weeks ago I started building a new language. Today it's at v0.15.55 with 1,232 commits, 35 examples, and 485 compiler specs. Here's the bet, the principles that held, and why I believe Sky Lang is the language AI builds production apps in.
---

# Why I built Sky Lang

It's June 1, 2026. Twelve weeks ago, on March 10, I made the first commit to a new git repository. The message read: *"feat: init project skeleton with working compiler."*

Today, that repository holds **1,232 commits**. Sky Lang is at **v0.15.55**. There are **35 example apps**, **485 compiler specs**, three UI runtimes shipping (web, terminal, desktop), and a multi-tenant deploy platform serving real apps in production.

I'm one person. I work with Claude every day.

This is the story of why.

---

## What broke

For the last year I've been building products with AI. Real ones — an LLM streaming chat app, a diagram authoring tool, the AI cost-tracking dashboard at [ringfence.dev](https://ringfence.dev). Useful products. Some with paying customers.

But every product had the same fight. I'd describe what I wanted; Claude would write the TypeScript. It compiled. The tests passed. We'd deploy.

Then production would catch fire.

Not big fires — small ones, the kind that erode trust. A response shape that didn't match the type. A field that came back `null` when the contract said it never would. An async function that quietly swallowed an error. A library upgrade that broke a downstream caller in a way the type checker thought was fine because the contract said `any`.

I'd fix the bug, write a test, push the fix. Three days later, a different version of the same bug. The class of bug was *"the AI generated code that compiles but doesn't actually work in production."* And no amount of better prompting, better linting, better testing made it go away. The language couldn't catch it.

I tried Go. Go's runtime is fine — actually great. But Go's type system can't represent what the AI was reasoning about. Every JSON shape became a `map[string]interface{}`, every error became `if err != nil`, every abstraction leaked. The AI wrote correct Go that I couldn't extend without a half-day of refactoring.

I tried Rust. Rust catches everything. Rust also takes a half-hour to compile, the learning curve is real, and *"ship this prototype tomorrow"* is not what Rust is for.

I went back to Elm. Elm's type system was the closest thing to what I wanted — Hindley-Milner, ADTs, exhaustive pattern matching, no null, no exceptions. With AI generating Elm, I got code that, when it compiled, *actually worked*. The contract held.

But Elm only runs in the browser. I had servers to write, CLIs to write, deploy systems, auth, databases. Elm gave me the wrong half of the stack.

So I started building Sky Lang.

---

## The bet

The bet was simple:

> Take Elm's type system and ergonomics. Target Go for the runtime so we inherit Go's universe of libraries and operational maturity. Build a stdlib that defaults to safe + scalable choices. Ship the whole thing with AI as the co-developer.

If the bet worked, I'd have:

- A language where **"if it compiles, it works"** was a real contract, not a tagline
- A single toolchain for **web, terminal, CLI**, and eventually desktop
- Stdlib defaults that **closed security + scalability holes by default**
- A workflow where AI generated code, the type system caught its mistakes, and what shipped was production-ready

If the bet failed, I'd have a fun side project and a deeper understanding of compilers.

Twelve weeks in, the bet looks like it's working.

---

## What got built

The commit log is the proof. The pace is the surprise:

- **Day 1 (Mar 10)** — skeleton compiler, parser, ADTs. First `.sky` file compiled to Go and ran.
- **Day 2 (Mar 11)** — FFI to npm. A Sky Lang program calling a JavaScript library. Type-safe bindings auto-generated.
- **Day 4 (Mar 13)** — pivot. Whole backend rewritten from a JavaScript runtime to Go. *Same day*, LSP shipped. The risk-reward of moving fast with an AI co-developer means you can rewrite a backend in one day instead of one quarter.
- **Weeks 1–2** — stdlib breadth. Strings, lists, dicts, JSON encoder/decoder, HTTP, file I/O, structured logging, crypto, time. Most are Sky Lang source files compiling through the same kernel as user code.
- **Weeks 3–5** — **Sky.Live**, the server-driven web UI runtime. SSE-based diffing, session stores, async commands, input-authority protocol. *TodoMVC on day 21.*
- **Weeks 6–8** — type-directed lowering. The compiler started propagating HM types through to the Go IR — so callbacks kept their typed callee parameter instead of falling back to `func(any) any`. Same period: **Sky.Tui**, the terminal renderer reusing the same `view` function.
- **Weeks 9–11** — production hardening. Six audit-fix-test cycles:
  - Cycle 1 — type soundness gaps
  - Cycle 2 — Sky.Live runtime races
  - Cycle 3 — diff-then-patch SSE architecture
  - Cycle 4 — six user-reported compiler bugs
  - Cycle 5 — Std.Ui completeness
  - Cycle 6 — *"if it compiles, it works"* credibility close

  Each cycle: matrix audit → root-cause fix → regression gate. Not symptom patches — *class closes*.
- **Week 12 (this week)** — Cycle 7. The Std.Ui correctness sweep that closed a 5-bug class on a **single removed line of CSS**. Five previous fixes had all *added* CSS. The audit showed the actual root cause was redundant CSS the compiler was emitting; remove it, the whole class closes.

The pace is roughly **100 commits per week**. That isn't possible solo without AI. It also isn't possible AI-only — every commit was a decision I made, a tradeoff I sized, a principle I held to. **The principles are why the pace didn't produce slop.**

---

## The principles that held

I wrote them down because I needed something to push back on AI suggestions that *looked* right.

### Root-cause fixes only
Never patch a symptom. The five #63 fixes that all added CSS were the anti-pattern — the proof I needed. When two bugs in the same family land, you have a duty to find the class, not whack-a-mole.

### "If it compiles, it works" is a contract
Every runtime panic class has a regression spec. Every release rebuilds every example from a wiped slate and runs it. Three release gates: cabal specs (485+), example sweep (26 of 26 must pass), visual regression (Playwright + computed-style). Any miss blocks a tag.

### AI-written defaults must be safe
Apps default to `Std.Ui` + `Std.Auth` + `Std.Db`. Secrets are typed — `Auth.signToken : String`, never `any`. `Result Error a` everywhere. The defaults catch the mistakes the AI would make. If a default could leak credentials, sign someone in as someone else, or panic in production — it isn't a default I shipped.

### No deferral
Bugs spotted enter the pipeline immediately. The phrase *"pre-existing flake"* is forbidden as a shipping excuse. Things get fixed in the next appropriate patch — they don't sit waiting for a "v2 cleanup".

These principles are the thing AI can't generate. **AI generates code; principles generate which code gets shipped.**

---

## What's next

Sky Lang isn't done. **v1.0-RC** is the next stake in the ground — when I publicly stand behind the language and say *"build a startup on this."* Cycle 7 closes the Std.Ui story; after that the work is documentation, tutorials, an online playground, and a VS Code extension.

But the meta-bet is now this:

> **Sky Lang is the language AI builds production apps in.**

Not *"the cool functional language to play with on the weekend"* — the working choice for AI-era solo founders and 3-person startups shipping real software.

To prove it, I'm building one more thing in Sky Lang itself: a **public roadmap + changelog + status page** combo, open-source, the thing every SaaS startup stitches together from three other tools today. Sky Lang's own site will run on it from day one. If you visit the changelog and read *"we shipped this"*, you're looking at the showcase running its own job.

Then I'm going to invite startups to try Sky Lang on a real project — and I'll help them, hands-on, the first time.

If you're an AI-native founder shipping something now and Sky Lang's promise interests you, **get in touch**. The repo is on GitHub, the language is Apache 2.0, the deploy platform is in private testing, and the first month of working with me on integration is on the house.

The story isn't finished. But the bet is no longer hypothetical — **twelve weeks of evidence is enough to know the shape of the answer.**

If AI is going to write a meaningful fraction of the software the world runs, the languages we have aren't enough. Sky Lang is one answer. Build with me, or don't — but stop accepting that AI-generated TypeScript crashing in production is just how things work.

It isn't.

---

*Anzel · [sky-lang.org](https://sky-lang.org) · [github.com/anzellai/sky](https://github.com/anzellai/sky) · v0.15.55 shipped 2026-06-01*
