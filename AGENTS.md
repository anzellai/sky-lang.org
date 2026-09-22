# AGENTS.md — sky-lang.org

This is a Sky project. Sky is an Elm-family, purely functional language that
compiles to Go. The full stdlib API is `sky doc <Module>` (generated from
source, so it never drifts) — prefer it over any signature written here. Run
`sky fmt` after editing any `.sky` file. Run `sky check src/Main.sky` before
shipping; it type-checks the shared source and runs `go build` on the emitted
Go, so a shape mismatch surfaces at check time. This app ships as a Sky.Spa
client (`--target web:app`), so `sky check` on the entry is the gate.

## Effect and control-flow style — flat and named, not nested

`Task` code chains with `andThen` / `map`. There is **no do-notation and no
`let!` bind**, so `let x = someTask in …` binds the TASK value, not its result —
you cannot replace an `andThen (\x -> …)` with a `let`. `let … in` still helps,
but only for the PURE sub-expressions inside a lambda (name a key, a record, a
string once). Keep an effect chain readable by keeping the pipeline FLAT and
NAMING its steps. Right-drift — each `andThen (\x -> …)` holding the next
`andThen` in its body — is the smell to remove.

The levers, in order of reach:

1. **Flat pipeline over nesting.** One value per step, top to bottom:
   `t |> Task.andThen step1 |> Task.andThen step2 |> Task.map finish`. Nest ONLY
   when a later step needs a value an earlier step bound.
2. **Name the continuation.** Replace a long `Task.andThen (\x -> <many lines>)`
   with `Task.andThen handleX` and a top-level `handleX x = …`. A named step
   reads as a sentence and unit-tests on its own. Lift a lambda out once it
   passes ~8 lines or holds another `andThen`.
3. **`map` for the terminal pure transform** — `|> Task.map (\x -> f x)`, never
   `|> Task.andThen (\x -> Task.succeed (f x))`.
4. **`map2` / `map3` / `andMap` for INDEPENDENT tasks** whose order does not
   matter and whose results you combine — `Task.map2 mkPair loadA loadB` beats a
   sequential `andThen` when `loadB` does not need `loadA`.
5. **`sequence` / `parallel` for a LIST of tasks.** A fixed run of effects that
   only needs "all done" is `Task.sequence [ t1, t2, t3 ] |> Task.map (\_ -> ())`,
   not three nested `andThen (\_ -> …)`.
6. **A tiny local combinator for a repeated shape.** Two recur constantly and the
   stdlib does not name them, so define them once per module:
   - `bestEffort t = t |> Task.onError (\_ -> Task.succeed ())` (there is no
     `Task.ignore`), so a best-effort write reads as `bestEffort (writeX …)`.
   - `unless cond t = if cond then Task.succeed () else t` (there is no
     `Task.when`), so a guarded effect reads as `unless liteMemory (embed note)`
     instead of an inline `if liteMemory then Task.succeed () else …`.

Before and after — a boot sequence that ran five migrations by nesting:

```elm
-- Right-drifting: each step is buried in the previous lambda.
Store.migrate db a
    |> Task.andThen (\_ -> Store.migrate db b)
    |> Task.andThen (\_ -> Store.migrate db c |> Task.onError (\_ -> Task.succeed []))
    |> Task.andThen (\_ -> …)

-- Flat: the run of effects is a list; the best-effort ones are named.
Task.sequence
    [ Store.migrate db a
    , Store.migrate db b
    , bestEffort (Store.migrate db c)
    ]
    |> Task.map (\_ -> ())
```

`if … else` in value position is clear inline. A branch that returns a `Task`
reads better as `unless` / `when`, or as a named `chooseStep : Bool -> Task Error
()`, than as an inline `if … then Task.succeed () else <long task>`.

**Persistence follows the same "highest layer that fits" rule (see Database).**
Model a record table with `Std.Db.Store` + `Std.Codec` by DEFAULT — one codec
drives the schema, the writes, and the TYPED reads (no untyped row access, so a
column change is a compile error). Drop to raw `Std.Db` (`query`/`exec`) ONLY for
what a `Store` cannot express: joins, aggregates, CTEs, or a query a typed `Cond`
cannot state. Keep the two in clearly separated sections of a persistence module.

The four combinators above live in `src/Effect.sky`
(`module Effect exposing (bestEffort, recover, unless, when)`). Import them where
a chain repeats the `onError` / `if … then Task.succeed ()` shape.

## Non-negotiables

- **Every side effect returns `Task Error a`.** Errors are `Result Error a` /
  `Task Error a`, never `String`. Pure code stays bare; fallible-pure returns
  `Result e a` / `Maybe a`.
- **DB defaults to `Std.Db.Store` + `Std.Codec`** — one codec per record table
  drives the schema, the writes, and the TYPED reads. Drop to raw `Std.Db`
  (`query`/`exec`) ONLY for what a `Store` cannot express (joins, aggregates,
  CTEs, a query no typed `Cond` states); keep those in a clearly separated
  section. Never hand-write a row mapper for a plain record table.
- **Effect chains stay flat + named** — top-to-bottom `andThen`/`map` pipelines,
  named step functions over long inline lambdas, `sequence`/`map2` over nested
  `andThen`, a local `bestEffort`/`unless` over a repeated `onError`/`if`.
  `let … in` names PURE sub-expressions only (it does not bind a `Task` result).
  See **Effect and control-flow style**.
