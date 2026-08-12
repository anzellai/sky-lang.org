---
title: What comes next — the data layer, and the platform around it
slug: the-data-layer-and-the-platform
date: 2026-08-12
author: Anzel Lai
summary: This post is about two things that do not exist yet. BlueDB, a data layer built for the way Sky apps actually hold state, and a deployment platform meant to give the whole stack one honest end-to-end story. Neither has a date. Here is what they are, why the language needs them, and the parts of Sky that are still maturing in the meantime.
---

# What comes next — the data layer, and the platform around it

Almost everything I have written on this blog so far has been about work that shipped. The compiler rewrite, the "if it compiles, it works" contract, the release gates. That is the honest order to do it in — talk about the thing after it is real.

This post breaks that rule on purpose, and I want to be straight about it up front. It is about two things that do not exist yet. One is being built right now and is nowhere near done. The other is a direction I am fairly convinced of but have not started in earnest. Neither has a date, and I am not going to give either one a fake one.

I am writing it anyway because people are starting to build real things in Sky, and if you are choosing a language for something you intend to keep, you deserve to know where its author thinks the gaps are and what he intends to do about them. A roadmap that only lists finished work is a press release.

So: here is what I think Sky is still missing, and what I am doing about it.

## The gap Sky still has

Sky's whole pitch is one language for the whole stack. That claim holds up better than I expected in most places. You write one `Std.Ui` view and it renders on the web, in a terminal, in a CLI loop, and in a desktop window. The type checker follows your data from an HTTP handler into your database call and back into the DOM. When it compiles, it usually does work.

Then you get to the data, and the seam shows.

Today, storing something in Sky means reaching for `Std.Db` and, underneath it, SQLite or Postgres. That is a good default and I do not regret it. SQL databases are among the most thoroughly debugged pieces of software on the planet, and "your app is a single Go binary next to a single SQLite file" solves a startling number of problems.

But it means the most interesting property of a Sky app stops at the database wall. Everything above that wall is typed, exhaustively matched, and checked end to end. At the wall, your typed record becomes a row, your query becomes a string, and the guarantees the language spent so much effort establishing are handed to a system that has never heard of your types. `Std.Codec` and `Std.Db.Store` narrow that gap — one codec definition drives both JSON and dialect-safe SQL — and `Std.Persist` narrowed it further by putting key-value and relational storage behind one front door with the capability to use each checked at compile time. Those were real improvements. They were also, both of them, better translations across a boundary I would rather not have.

There is a second gap, and it is the one that actually bothers me. A Sky.Live app is a state machine. There is a model, messages transform it, and the view is a function of it. That is a clean way to think, and it is why the framework feels the way it does. But the model lives in memory in a session, and the database lives somewhere else, and keeping those two in agreement is code you write by hand, every single time. Load from the database into the model on init. Write back on update. Remember to invalidate. Remember that another user's write should show up in this user's view, so add a subscription, and a pub/sub topic, and a way to re-query, and now be careful you did not just re-render the world on every keystroke.

Every real app I have built in Sky has that layer in it. It is always slightly different, always slightly wrong, and it is always the part where the "if it compiles, it works" property quietly stops applying, because none of it is a type error. It compiles perfectly and shows a stale number.

## BlueDB

BlueDB is my attempt at closing that. The one-line version is that the model *is* the database — that reading and writing persistent state should look like reading and writing your model, and that when someone else's transaction changes data your view depends on, your view finds out, without you having written the plumbing that makes it find out.

The design goals I am building against, in the order I care about them:

**Session-bounded state that survives.** A Sky.Live session's model should be able to outlive the process holding it, spill to disk when memory is tight, come back correct, and never show a transition that was acknowledged and then lost.

**One store, with real isolation.** Not "isolation" as a word in the docs. Serializable, verified by a conformance suite that actually discriminates between isolation levels, running against every backend, including a crash corpus that injects filesystem faults and checks what survived.

**Tenancy that is structural.** Cross-tenant reads should be impossible because of how keys are laid out, not because every query remembered to include a `WHERE tenant_id = ?`. A security property enforced by a convention is a security property waiting to be forgotten once.

**Change notification as a first-class thing.** When a transaction commits, the subscribers whose queries actually overlap that change get the delta — the delta itself, applied, not a nudge that says "something happened, go re-query everything". And subscribers outside the predicate get nothing at all.

**Zero config that graduates.** The default app should persist across a restart with no setup whatsoever, and the identical application source should move to SQLite and then to Postgres when it needs to, without a rewrite.

Underneath, it is ordered storage with MVCC and transactions expressed in portable Sky, so the transaction logic is the same wherever it runs.

Now the honest part. BlueDB is a clean-slate rebuild, currently in the phase where I have written the architecture and the verification harness, and most of the gates that would tell me any of the above is true have not been run yet. The status board is mostly "NOT RUN", with a few reds I am working through. There is a deliberately vacuous canary gate in the suite whose entire job is to fail if my verification harness ever starts reporting success without checking anything, because the failure mode I fear most on a project like this is a green dashboard that means nothing.

I have shipped a version of this before, as an experiment, and I learned enough from it to know the experiment's architecture would not hold up under the guarantees above. So it is being rebuilt rather than extended. That is the right call and it is also the slow one.

It will ship when the gates are green. I do not know when that is.

## The platform

The second thing is further out and I want to be even more careful describing it, because it is the kind of thing that is easy to announce and hard to build.

Sky compiles to a single binary. That makes deployment genuinely simple in the "scp it to a box" sense. It does not make it *good*. You still need somewhere to run it, a database that survives, secrets that are not in your shell history, migrations that ran in the right order, logs you can search, and a way to know the deploy you just shipped is the code you just wrote. Every team rebuilds that, and building it is not what any of them set out to do.

What I want to build is the deploy story for Sky where all of that is one coherent thing rather than nine glued ones. And the reason I think it is worth doing specifically for Sky, rather than telling everyone to use the existing platforms, is the same reason the language exists.

Sky was designed for a world where a lot of code is written by AI. Not as a marketing line — as an engineering constraint that shaped the type system, the error messages, and the release gates. The bet is that if the language refuses to compile the categories of mistake that a fast, tireless, occasionally-overconfident collaborator makes, then you can go quickly without the usual consequences.

That bet currently stops at your laptop. `sky check` will tell an agent that its code type-checks, that the effects are handled, that the pattern match is exhaustive. Nothing tells it whether the thing it just deployed is actually serving traffic correctly, and nothing gives it a safe way to find out and act on the answer. A deployment platform designed around that — where build, check, deploy, observe, and roll back are all things a program can drive and verify, with the same "make correctness checkable, then check it" discipline the compiler gets — is what I mean by an AI-native platform. Not a chatbot in a dashboard. A production loop with a machine-readable answer at every step, so the whole path from an idea to a running production app has the property the language has.

I run apps on an early version of this today. It is not a product, and it is not open for signups, and I am not going to pretend otherwise. It is on the roadmap. If it becomes something you can use, I will write that post when it is true.

## What is still maturing

It would be dishonest to write about the roadmap without being clear that plenty of the existing surface is still settling.

Sky is at v0.20 and pre-1.0 for real reasons. Type inference is Hindley-Milner and stays there — no higher-kinded types, no custom operators, no `where` clauses. Sky.Webview runs on macOS and builds, untested, on Windows and Linux. The `Std.Ui` layout DSL is expressive but I still find rendering bugs in it; I fixed one the same week I wrote this, where an inline highlight inside a paragraph emitted markup the browser was entitled to reinterpret, breaking the line. It compiled. It type-checked. It rendered wrong, which is exactly the class of bug this project exists to eliminate and exactly why the fix shipped with a test that asserts on the emitted bytes.

The APIs move. The builder-config change in v0.19 altered how every app's entry point is written. I try hard to make those migrations mechanical and to have the compiler tell you what to do, but if you build on Sky before 1.0, you are going to hit some.

I would rather you know that than find out. The reason I keep the release gates as strict as I do — full example sweep from a wiped slate, behavioural conformance suites, a differential oracle, a rule that every bug becomes a regression test before the fix lands — is that they are what make a fast-moving pre-1.0 language safe to actually use. Not the version number.

## Why say any of this now

Because a language is a bet on its future, and you cannot evaluate the bet if the author only ever shows you the finished parts.

The data layer is the biggest hole in "one language for the whole stack", and I am building it. The deployment story is the next one after that, and I intend to build it. Both will ship when their gates are green and not before, which is the only promise I have found worth making.

If it compiles, it works. The work I have described here is about extending where that sentence still applies — through your data, and out into production.

---

*Anzel · [sky-lang.org](https://sky-lang.org) · [github.com/anzellai/sky](https://github.com/anzellai/sky) · written at v0.20.0*
