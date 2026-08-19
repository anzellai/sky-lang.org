---
title: One config, and a database that ships itself
slug: embedded-postgres-in-production
date: 2026-08-19
author: Anzel Lai
summary: Four days ago I wrote that Sky had shipped embedded PostgreSQL instead of a database I would have had to maintain. Today the blog you are reading runs on it — on a 969 MB machine, the whole app plus its own PostgreSQL sitting in about 106 MB. This is the production story: what the migration actually took, the one typed config that now drives the whole app, and the honest numbers on memory, security, and the tradeoff I made.
---

# One config, and a database that ships itself

Four days ago I published [*The database I did not build*](/blog/the-database-i-did-not-build) — the story of deciding **against** a custom engine and shipping embedded PostgreSQL instead: a real PostgreSQL, bundled and supervised by the toolchain, arranged so the app never knows which tier it is in.

That post was about a decision. This one is about production.

Because the blog you are reading right now is served by it. Same PostgreSQL that runs a production cluster, provisioned and managed by the app itself, on a **969 MB e2-micro** — the smallest VM Google will rent me. No managed database. No separate service to page me at 3 a.m. The app starts, brings up its own cluster, runs its migrations, and starts answering requests.

Here is what that took, and what it cost.

---

## The config front door

The first thing that had to change was not the database. It was the *config*.

Before v0.21.0, an app like this one was configured in three places at once. Some of it lived in `sky.toml` (`[live]` port, `[log]` format). Some of it lived in environment variables (`SKY_LOG_LEVEL`, session store, a dozen `SKY_*` names). And some of it lived in the gap between them, where a setting existed in both and you had to remember which one won.

That is exactly the class of bug Sky exists to kill — a contract that lives in two places and drifts. So v0.21.0 gives the whole app **one typed config binding**:

```elm
config : Config.Config
config =
    Config.default
        |> Config.withLog Text Info
        |> Config.withSessions SharedWithDatabase
```

That is the real config for this site. Log format, log level, where sessions are stored — one value, checked by the compiler, impossible to misspell. The old scattered `[live]` and `[log]` sections are gone. `withPort`, `withInput`, the head function — all of it is now one pipeline the type checker reads end to end.

And it does not take the operator's control away. The rule we settled on is precise:

- If you **don't** use a `withX` builder, the setting is read from the environment; if that is empty, a safe default applies.
- If you **do** use `withX`, that is your default — and an operator can still **override it from the environment** in production, without touching your code.

So `withX` is not a wall around a value. It is a *documented default that names the env var an operator can reach for*. The system's own settings all follow this: reading an env var can set any `withX` the framework owns, no exception. The only things env vars cannot reach are the ones you defined yourself. That symmetry is the whole point — the person writing the app and the person deploying it are looking at the same knobs.

---

## The migration, honestly

Moving this site from SQLite to embedded PostgreSQL was four changes, and I want to be honest that one of them was a real bug in *my* app, not in Sky.

**The schema.** This blog's tables were written in raw SQL with `id INTEGER PRIMARY KEY` and `INTEGER` timestamps — which is fine on SQLite, where `INTEGER PRIMARY KEY` auto-increments and integers are 64-bit. On PostgreSQL, `INTEGER` is 32-bit and does not auto-increment, so the first insert with a millisecond timestamp overflowed and the first post had a null id. The fix was `BIGSERIAL` for the keys and `BIGINT` for the timestamps. Sky has a dialect-safe schema builder (`Std.Db.Schema`) precisely so you never hand-write this and never hit it; I had hand-written mine before that existed. Lesson paid.

**The config**, above — one typed binding, `[database] embedded = true` in `sky.toml`.

**The service.** Embedded PostgreSQL will not run as root — `initdb` refuses uid 0, on purpose. So the service now runs as a dedicated non-root user, and its data directory belongs to that user. This is a *better* posture than the root-owned SQLite file it replaced.

**The engine on the host.** The bundle that lets a binary carry its own PostgreSQL is not published yet, so the host has a system PostgreSQL installed and the app provisions its own cluster from those binaries. The app still never sees a DSN it did not create. `--embed` and it manages its own database; hand it a `DATABASE_URL` and it uses yours. Same binary, same code.

That is the property I care about most: **the app never knows which tier it is in.** Development and production run the same engine now. No more "it passed on SQLite and broke on Postgres" — the gap that tax is gone because there is no gap.

---

## The numbers

The reason I could put PostgreSQL on a 969 MB machine at all is that embedded PostgreSQL is a **fixed block, not a per-session tax**. Its memory does not climb with traffic — a Sky.Live session adds essentially nothing to the database's footprint, because the whole app shares a small connection pool rather than opening a backend per user.

On this exact VM, after the migration, I measured the whole service — the Sky app **and** its PostgreSQL cluster, together, in one cgroup:

> **~106 MB.**

Under a 768 MB cap, with a third of the machine still free. The reason it is that small and not the ~400 MB you might expect is that the runtime **derives its memory limit from the machine it lands on**: it reads the cgroup limit, subtracts what PostgreSQL reserves, and sizes the Go garbage collector under what is left. Give it a small box and it configures a small database. No knob to turn; it just fits.

I will be equally honest about the ceiling. An e2-micro is memory-comfortable here but **CPU-bound long before it is memory-bound** — it is a fine home for a blog and a bad home for a busy interactive app. If this site ever needed real concurrency, the answer is a bigger box, and the numbers say to count *physical cores*, not vCPUs, when you pick one. But for what this is — a handful of readers, a few writers, content that changes a few times a week — 106 MB and one machine is the right shape.

---

## Security, by default

Three things I did not have to do, because the defaults did them:

- **Secrets are typed, never `String`.** The session secret and the token signer take a real secret type through the whole stack. There is no `fmt.Sprintf("%v", secret)` waiting to leak one into a log line, because the types will not let you.
- **The cross-tenant boundary is enforced in the database, not hoped for in the app.** When a single host cluster serves several apps, each gets its own role, and an app attempting to read another's data is refused by PostgreSQL itself — a boundary Sky verifies by *observation*, by actually trying the cross-tenant read as the app's own role and checking it fails.
- **Nothing dev-only is exposed in production.** The console and its banner and its metrics lock the moment `ENV` is not a development spelling; the dev server binds loopback; the observability endpoints want a bearer token. The production checklist the app prints on every start is the same list the runtime enforces.

None of that is code I wrote for this site. It is what "production" means to the framework.

---

## Why bother

I could have left this blog on SQLite. It worked. The honest answer for why I moved it is that I want the thing I ship to be the thing I run.

Sky's whole promise is *if it compiles, it works* — and a database dialect gap is a hole in that promise. The moment development runs one engine and production runs another, "it worked on my machine" comes back through a side door. Embedded PostgreSQL closes the door: one engine everywhere, managed by the toolchain, sized to the box, secured by default, configured by one typed value the compiler reads.

The database ships itself now. So does the config. That is one fewer thing between an idea and production — which, still, is the only metric I am really building for.

*This post was written the day the migration went live. If you are reading it, it came out of the database it is about.*
