---
title: Durable agents, and the firewall in front of the model
slug: durable-agents-and-the-action-firewall
date: 2026-09-14
author: Anzel Lai
summary: An LLM agent is a loop that spends money and takes real actions across minutes or hours, on infrastructure that restarts. Sky's new Std.Ai layer treats that honestly. The agent runs as a durable workflow, so a crash mid-run resumes from the last step and never pays for the same model call twice. And the model never authorises an action — it proposes a typed one, a pure policy decides, and only an allowed decision runs the effect. The whole thing is testable offline with no key and no network. The capstone is a Slack bot in one file.
---

# Durable agents, and the firewall in front of the model

I have built a few agents now, and the thing nobody tells you is that the model is the easy part. You call an API, you get text back. The hard part is everything around it: the call costs money and is not idempotent, the loop runs for minutes or hours across many steps, the process it runs on gets redeployed halfway through, and at the end of it the agent wants to *do something* — refund a customer, send an email, run a command — and you have to decide whether to let it.

None of that is an AI problem. It is a systems problem, and it is the same systems problem Sky has been solving for everything else: make the effects explicit, make the failures survivable, make the whole thing testable. So `Std.Ai`, which ships in v0.25, is not a wrapper around a model. It is the harness. The model is a component you swap out.

Two ideas do most of the work.

## The agent is a durable workflow

An expensive, non-idempotent call in a loop that can crash is exactly the thing you do not want to run twice. So an agent in Sky is a **durable workflow**: it marks its steps, and each step's result is journalled to the database. If the process dies after the model answered but before the loop finished, the run resumes — and the recorded answer is replayed instead of the model being called, and paid for, again.

```elm
agent = Agent.toolLoop "assistant" provider "You are terse." [ lookupTool ] 6

Durable.start db agent "chat-42" { messages = [ Provider.user "..." ] }
Durable.poll db [ Durable.erase agent ]
```

`Durable.step` is the boundary. Every model turn and every tool call is one, so a resume never repeats a turn it already took. The message history between turns is rebuilt deterministically from the journal, so the replay is exact, not approximate. A run can `sleep` for a day or wait for a human's approval and hold no process while it waits — it is a row in a table, and a worker picks it back up when it is due.

This is not AI-specific, which is the point. [`Std.Durable`](/blog/if-it-compiles-it-works) is a general primitive — checkout sagas, order fulfilment, onboarding, approval flows, anything multi-step that has to survive a restart. It is pure Sky over `Std.Db`, so it runs the same on SQLite for a prototype and on PostgreSQL in production. An agent is just one shape of durable workflow, built on top.

## The model is never the authorisation boundary

Here is the rule I will not bend: **a language model does not get to authorise a real-world action.** Not because it is stupid — because "the model decided to" is not an audit trail, and a prompt is not a permission system. A prompt can be argued with. A type cannot.

So in Sky the model does not call an effect. It *proposes* a typed `Action` — a stable capability name, its arguments, a risk tag. A `Policy` is an ordinary, pure Sky function from that action to a decision. Only `Allow` unlocks the effect.

```elm
firewall act = Policy.requireApprovalAbove Policy.Low act

Policy.gate firewall (Policy.action "refund" orderId Policy.High) (Payments.refund orderId)
    -- => Pending "..."  — a High-risk action; the refund did NOT run
```

The firewall is code you review in a pull request, diff, and test — not a paragraph of English you hope the model respects. A `NeedsApproval` decision is a suspension point: pair it with the durable layer's `awaitSignal` and the workflow pauses exactly there until a human approves, then resumes. The model can suggest a refund all day long; whether one happens is decided by a function you wrote, outside the model, that the compiler checked.

## It counts the money, and it tells the truth

Every model call records what it cost — the token counts and the price, in `Std.Money` as an exact decimal, never a float, because a float quietly loses cents and a cost report that loses cents is worse than no report. The costs roll up per run, so "what did this job cost me" is a real number you can put in front of a finance person. And because the model returns its usage on every call, the number is measured, not estimated.

For memory, there is `Std.Ai.Memory.Pg` — long-term recall on PostgreSQL and pgvector, which already ships inside Sky's [embedded database bundle](/blog/embedded-postgres-in-production). Store a passage with its embedding; get back the nearest ones by vector distance, or a hybrid of vector distance and a keyword match so an exact term is not lost to a merely-close embedding. One database does the facts, the vectors, and the durable journal. No second datastore to run.

## You can test all of it with no key and no network

This is the part I am most pleased with, and it falls straight out of [work Sky already had](/blog/the-tests-i-did-not-write). Every model call and every integration goes through the same HTTP boundary, and Sky's mock-by-default test mode answers that boundary from a file. So an agent's whole trajectory — the model turn, the tool call, the outbound message — runs offline, deterministically, with no API key and no network, in a normal test. You assert on what the agent *did*, not on what a live model happened to say that afternoon. The firewall's decisions, the exactly-once resume, the cost total: all of it is a fast, repeatable test.

## The whole thing, as a Slack bot

The example that ties it together is a 24/7 Slack bot, and it is one file. Mention it in a channel; it starts a durable workflow and acknowledges within Slack's three-second window; a background worker drains the run. The run is three journalled steps — the model call (exactly-once), the reply posted to Slack **behind the firewall**, and the cost recorded against the run. Redeploy the bot mid-reply and it resumes from the last step instead of double-posting or double-paying.

It ships on SQLite, so it boots anywhere with no setup, and it runs on embedded PostgreSQL in production without a line of code changing — the same property every Sky app has. The bot is proven end-to-end in the test suite with both the model and Slack mocked, so it is not a screenshot in a README; it is a thing that runs green in CI with no credentials.

That is `Std.Ai` in v0.25. Not a model in a box — a harness that makes an agent something you can operate: durable enough to trust with a long job, honest enough to trust with a budget, and locked down enough to trust with an action. The model stays a component. If a better one comes out next month, you change one line, and everything around it — the durability, the firewall, the cost ledger, the tests — is untouched, because none of it was ever the model's job.
