---
title: Why I rewrote the Sky compiler in Rust
slug: rewriting-the-compiler-in-rust
date: 2026-07-24
author: Anzel Lai
summary: Sky's compiler was written in Haskell, and Haskell got it a very long way. Then one 24,000-line module, held together with global mutable state I spent a whole release trying to remove, told me the architecture had hit its ceiling. This is the story of the rewrite. Why Rust, why now, and the one decision that made replacing a working compiler feel safe rather than reckless.
---

# Why I rewrote the Sky compiler in Rust

Sky Lang's compiler has been rewritten four times.

The first version was TypeScript, which was the fastest way to get a parser and a tree-walker in front of a real `.sky` file. Then a self-hosted attempt, which taught me exactly which parts of the language were not ready to compile themselves yet. Then Haskell, which is where Sky grew up. Type-directed lowering, Go generics on record aliases, the whole "if it compiles, it works" contract, three UI runtimes, a deploy platform. Most of the story on this blog so far was compiled by the Haskell toolchain.

As of today, with v0.18.0, the compiler is Rust.

I do not take rewrites lightly. A working compiler is an enormous asset, and "let's rewrite it in $LANGUAGE" is the most reliable way a software project has ever found to set eighteen months on fire. So this post is the honest version of why I did it anyway. What Haskell gave me, the specific moment it stopped being enough, why Rust answered that particular problem rather than being the language I felt like using, and the single decision that turned "replace the compiler" from a reckless bet into an ordinary, verifiable engineering task.

## What Haskell got right

I want to be precise here, because posts about migrating off a language usually turn into a list of that language's sins, and that would be dishonest. Haskell was the right choice for years, and most of what makes Sky feel like Sky was designed in it.

A compiler is, structurally, a pipeline of tree transformations. Parse, resolve names, infer types, lower to an intermediate representation, emit code. Haskell is almost unfairly good at that. Algebraic data types model an abstract syntax tree exactly. Exhaustive pattern matching means that adding a new syntax node lights up every place that forgot to handle it. Purity means a transformation pass is a function from one tree to another, so you can reason about it on its own. The Hindley-Milner type checker at the heart of Sky was, in a real sense, written by a Hindley-Milner type checker.

For the first year that leverage was decisive. I could hold the whole pipeline in my head because each pass was a pure function, and the type system caught the mistakes before they compiled. The pace this blog keeps describing, roughly a hundred commits a week, solo, with AI as co-developer, was only possible because the language underneath refused to let most classes of mistake through.

So this is not a story about Haskell being wrong. It is a story about one architecture, written in Haskell, hitting a ceiling that the language could not help me raise.

## The 24,000-line module

The ceiling had a filename. `Compile.hs`, the lowering and codegen stage. By v0.17 it was 24,436 lines in a single module, and, the part that mattered, it was no longer pure.

Type-directed lowering needs context that the tidy "tree in, tree out" shape does not give you. When you are emitting Go for a sub-expression, you often need to know something the type checker worked out three passes ago and forty nodes away. The resolved type of a region, the Go signature of a sibling binding, the enclosing function's type parameters. In a pure pipeline you thread that context through every function as an argument. When the context grows large enough and is needed deep enough, threading it becomes its own full-time job, and the tempting shortcut is a piece of global mutable state. A reference you write once and read from wherever you happen to need it.

I took that shortcut. More than once. `globalCgEnv`, `globalGoSigMap`, `scopeStateRef`, a small family of environment values, each one a pocket of global mutable state that let a value computed early in lowering reach a consumer late in lowering without threading it through the twenty functions in between.

Each one worked. Each one was also a lie about the architecture. The whole promise of the pure-pipeline design is that a pass is a function of its inputs. A global mutable reference is an input you cannot see in the type signature and a dependency you cannot follow in the code. Two of them interacting is a bug you can only find at runtime, in generated Go, on a program you did not think to test.

I spent most of v0.17 trying to remove them. There is a whole saga in the internal roadmap, filed under "criterion 3", about draining those bridges. More than 136 distinct read-through points, a machine-verified single-writer contract for every reference that had to survive, a test gate that builds a multi-module fixture and fails the build if any write ever overwrites or any read ever sees a stale value. I got it done. The contract held. It was also the clearest possible signal that I was fighting the architecture rather than using it.

Here is what I finally admitted. The mutable state was not a failure of discipline. It was the design asking for a boundary the language could not give me. Haskell modules do not enforce architectural layers. Nothing stops one function in a 24,000-line module from reaching into a global that another function set up, because they are in the same module and the global is in scope. The purity I relied on was a convention I was hand-enforcing with test gates, not an invariant the toolchain guaranteed. When a convention needs 136 verified points and a bespoke audit test to stay true, the convention has become the job.

## Why Rust, specifically

Once the problem was named, that I needed architectural boundaries the compiler enforces rather than ones I promise to respect, the choice of Rust stopped being a matter of taste.

Crates are walls. A Rust workspace is a set of crates with an explicit dependency graph, and a crate cannot reach another crate's private internals. When I split the pipeline into `syntax`, `hir`, `ty`, `lower`, `codegen`, fifteen crates in all, the layering I used to promise became something the compiler checks. `lower` can depend on `ty`. `ty` physically cannot reach into `lower`. The global-state-across-the-pipeline move is no longer a temptation I have to resist. It does not compile. The architecture went from documented and audited to structurally impossible to violate, which is the only kind of architectural rule that survives a hundred commits a week.

The functional-programming habits carry straight over, and people coming from Haskell tend to underestimate this. Rust's `enum` is an algebraic data type. `match` is exhaustive, and the compiler complains when you miss a case, which is the exact property that makes "add a syntax node, watch everything that forgot about it light up" work. `Result` and `Option` in place of exceptions and null. The passes are still tree-to-tree transformations. I did not give up the thing that made Haskell good at compilers. I kept it, and got enforced module boundaries and predictable performance alongside.

Predictable performance also solved a real problem. There is a rule in Sky's own development guide that exists because a runaway Haskell build process once used enough memory to hard-power-off my Mac. Compiler tooling that can exhaust the machine it is building on is its own kind of tax. Rust's compile times are not free, but the runtime of the compiler is fast and its memory profile is dull. No surprise thunks, no space leaks, no wondering why a build ballooned to six gigabytes. For a toolchain that has to run inside `sky watch`, inside an LSP server, and inside a deploy platform's browser editor, dull and fast is worth a great deal.

Incremental compilation came as part of the shape rather than as a later retrofit. The Rust compiler is built on a salsa-style query core, so the compiler is a graph of memoised queries and a change to one file only recomputes the queries it actually touches. That is the right foundation for the two things I care most about next. An LSP that stays instant on a large project, and a `watch` mode that rebuilds in the time it takes to alt-tab. Bolting incrementality onto the pure batch pipeline in Haskell would have been its own multi-month rewrite. Building it as the shape of the new compiler cost nothing extra.

None of this is "Rust is better than Haskell". It is "Rust answers the specific question v0.17 forced me to ask", which was how to make the architecture enforce itself.

## The decision that made it safe

This is the part that separates a disciplined rewrite from a hero-mode one.

I did not rewrite the compiler and then hope the output was right. I kept the Haskell compiler alive as a differential oracle.

The rule was simple and absolute. For every program both compilers accept, the Rust compiler must emit byte-for-byte identical Go to the Haskell one. Not equivalent, not close enough, the same bytes. The old compiler became a machine that answers, for any input, "here is exactly what the correct output looks like", and every step of the rewrite was graded against it.

That turned an unmeasurable task, reimplement a compiler, into a measurable one, make this diff empty. The gate suite runs the full example corpus, 50 example apps, through both compilers and compares the generated Go, and today 40 of the 40 deterministic examples match to the byte. On top of that there is name-resolution parity, type-acceptance parity, rejection parity so the Rust compiler rejects exactly what the oracle rejects, a fuzzer that feeds both pipelines a large space of mutated inputs and checks they agree and never crash, and a runtime gate that actually runs the compiled programs and checks the answers. 312 tests in the workspace, plus the whole differential battery, and green everywhere is a hard release gate.

When the two compilers should differ, because the Rust one intentionally fixes something, that difference does not get to hide. It goes in a known-divergences ledger, a checked-in file that records that the oracle accepts this, Rust rejects it, here is the error code, here is why, on purpose. The ledger is enforced too. An unledgered divergence fails CI as a bug. When I eventually delete the oracle at v1, that ledger is the permanent record of every place the new compiler deliberately departed from the thing I removed.

The oracle is still there today, one flag away, as a rollback. That is the point of the whole exercise. A rewrite you can diff against a known-good reference, byte for byte, on every commit, is not a leap of faith. It is the most ordinary kind of engineering there is, and ordinary is exactly what you want when you are replacing the thing every other part of the system depends on.

The Rust compiler's first commit, the empty workspace skeleton, landed on the 18th of July. Six days later it drove every command (`build`, `run`, `check`, `watch`, `test`, `fmt`, `lsp`, `doc`, and the FFI and dependency commands), reproduced the oracle's Elm-style type errors down to the source-context window, passed the whole differential suite, and shipped as v0.18.0. Six days from empty directory to primary toolchain is only possible when "is it correct?" has a mechanical answer you can run a thousand times a day.

## What it unlocks

The rewrite is not the feature. It is the foundation the features stand on.

The enforced crate boundaries mean I can keep moving quickly without re-accumulating the global-state debt that made `Compile.hs` a 24,000-line module I was afraid to touch. The salsa query core means the LSP and `watch` mode get to be incremental by construction. The predictable performance means the toolchain can sit comfortably inside the deploy platform's in-browser editor, running `fmt` and `check` as you type, without becoming the reason the tab is slow.

The differential-oracle discipline is also the template for every risky change from here. Next time I need to touch something load-bearing, I do not have to ask whether I trust myself to get it right. I ask what the oracle is and whether the diff is empty. That is a much better question, and it is the same instinct as "if it compiles, it works". The way you make big changes safely is to make correctness checkable, and then check it, over and over, instead of trusting anyone's judgement, including your own.

Haskell taught Sky how to be a language. Rust is teaching it how to be a language whose compiler I am not afraid to change. Both are the same project, making the thing correct by construction, so that shipping fast and shipping right stop being a trade-off.

The oracle is still one flag away. The diff is empty. On to v1.

---

*Anzel · [sky-lang.org](https://sky-lang.org) · [github.com/anzellai/sky](https://github.com/anzellai/sky) · v0.18.0 shipped 2026-07-24*
