# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-08-27

### Added

- `EnumAtInLoop` *(Refactor)* — flags `Enum.at` with a computed index inside `Enum.*`/`Stream.*` iteration, `Task.async_stream`, or a `for` comprehension. `Enum.at` walks the enumerable to reach the index, so calling it per element turns an O(n) traversal into O(n²) — the same class as `AppendInLoop`. A non-negative integer-literal index is exempt: `Enum.at(list, 3)` takes at most four steps, bounded by the literal rather than the length of the list. A negative literal is not exempt — reaching `-1` means walking to the end — and is reported, pointing at hoisting the lookup rather than at `List.last/1`, which is the same O(n) walk. Shares `PreloadInLoop`'s per-element-region reading, so `Enum.at` in the collection a loop iterates over is not reported. On a 2129-file codebase it reports 42 sites across 11 `lib/` files and the test suite, including 2D matrix walks inside an already-cubic assignment algorithm. It cannot see collection size, so a small fixed list indexed in a loop is reported the same as a large one — documented as a known limitation rather than guessed at.
- `KeywordBagParameter` *(Refactor)* — flags a parameter the body only reaches into with `Keyword.get/fetch/fetch!/take/has_key?`, which makes it a parameter list in disguise. Detection is by shape rather than by parameter name, so renaming `opts` to `options` does not silence it, and a keyword list that is purely forwarded (`def all(query, opts), do: Repo.all(query, opts)`) reads no keys and is never reported. Neither is one the body reads keys off *and* passes on whole — it still needs the list, so the signature the message spells out would not compile — nor a callback marked `@impl`, whose arity belongs to the behaviour rather than to the author. The message names the keys it found, so it spells out the signature to write. `min_keys` (default 3) sets how many distinct keys make a bag; on a 1319-file codebase the thresholds measure 99 functions at 1 key, 32 at 2, and 7 at 3. `ignored_keys` defaults to the keys that are conventionally forwarded rather than named — `:actor`, `:authorize?`, `:tenant`, `:domain`, `:context`, `:timeout`, `:tracer`.
- `MapAsSet` *(Refactor)* — flags `Enum.member?(Map.keys(map), key)`, its pipe form, and `key in Map.keys(map)`, which are the same AST once unpiped (`in` on a non-literal right side compiles to `Enum.member?/2`). Each allocates the full key list and scans it where `Map.has_key?/2` is O(1). `Map.values/1` membership is deliberately not flagged — there is no constant-time equivalent, so the report would carry no fix.
- `MultiStepMutationWithoutTransaction` *(Warning)* — flags a function performing two or more database mutations without `Repo.transaction/1`, `Ash.transaction/2`, or `Ecto.Multi`, where a mid-sequence failure leaves the database half-updated. Counts `Repo.*` writes (any alias ending in `Repo`), direct `Ash.*` mutations, and Ash code-interface calls on resources named in `ash_resources:`; local mutating helpers are followed through the call graph. Mutually exclusive paths contribute their worst branch rather than their sum — a `case` dispatching to a different single-write helper per branch runs exactly one of them, and `try do work() rescue _ -> record_failure() end` is compensation rather than a second step. Test files are skipped: ExUnit's SQL sandbox rolls each test back, so the failure mode cannot occur there. Mutations are counted per call site, so a single write inside a loop counts as one and is not reported on its own. Measured on a 2129-file Ash/Ecto codebase it reports 4 issues, 3 of them sequential importer writes with no transaction.
- `PatternMatchInFunctionHead` *(Refactor)* — flags a single-clause function whose entire body is a `case` on one of its own parameters, which is multiple function clauses written the long way. Only the unambiguous shape is reported: one clause, no guard on the head, and the whole body is a `case` on a bare parameter with more than one branch. A `case` on a computed value, one that is part of a larger body, or one whose function also carries a `rescue`/`catch`/`else`/`after` clause — which has nowhere to go once the body is split across heads — stays put. Reports 17 sites across 15 files on the same codebase.
- `PreloadInLoop` *(Warning)* — flags `Repo.preload` and `Ash.load` inside `Enum.*`/`Stream.*` iteration, `Task.async_stream`, or a `for` comprehension — the textbook N+1. Only the regions that run per element are examined — the lambda handed to an iterating call, and a comprehension's body and filters — so the batched call that *feeds* a loop, `Enum.map(Repo.preload(users, :posts), &...)`, is not itself reported. Matches any alias whose last segment is `Repo`, plus `Ash.load`.
- `TrivialWrapperFunction` *(Refactor)* — flags a single-clause `defp` whose whole body is one call to another module, forwarding its parameters unchanged. It adds a name and nothing else, and hides which module does the work. A wrapper that supplies an argument, supplies an option, reorders or transforms arguments, matches a pattern, guards, carries a default, or adds a `rescue`/`catch`/`else`/`after` clause is not reported — the handler is usually the whole reason such a wrapper exists, and deleting the wrapper would delete the error handling with it. Public delegation is left to `defdelegate`. Reports 28 sites across 23 files.

### Changed

- Every check now carries an `explanations:` block, so `mix credo explain` works for all of them rather than five. Every check that takes params documents them there too, so `explain` lists `min_keys`, `ash_resources`, `extra_modules` and the rest instead of ending on "There are no other configuration options." The hand-written `@moduledoc` each check also carried was dead code — `use Credo.Check` builds the moduledoc from `explanations` and overwrites anything above it — so 333 lines of prose that rendered nowhere have been removed. Long-form documentation lives in the README and `usage-rules.md`, both of which ship as hex doc extras.
- Test-file detection, previously written four different ways across five checks, moved to `SephiaCredo.TestFile`. Checks with configurable params now read them through `Credo.Check.Params.get/3` instead of `params[:key] || default`, which duplicated every default between `param_defaults` and the function body.
- `AppendInLoop` now flags `++` only when the list on the **left** is the loop's accumulator — the one that grows. It previously flagged every `++` inside a loop, which reported three shapes that cost nothing: `item ++ acc`, the idiomatic way to prepend a list; a loop-invariant list built for a call, such as `opts ++ [authorize?: false]`; and the bounded half of a destructured reducer result, `{work, acc} = collect(...)` followed by `work ++ works`. The accumulator is read from the reducer's last parameter and followed through rebindings onto bare variables, but not through destructures, since a pattern like `{work, acc} = split(acc)` says nothing about which element grows. Inside a recursive function only a whole parameter counts: a variable bound inside a parameter's pattern — `t` in `generate([{:label, t, _} | rest], ...)` — is a piece of that parameter, and a piece is bounded by the whole. Parameters are otherwise taken as-is with no following, since there a local bound from a parameter is usually a sub-result, not the accumulator, and tainting them reported every divide-and-conquer join.
- `AppendInLoop` also leaves `acc ++ f(acc)` alone. Feeding the accumulator back in means each step needs it in order, so prepend-and-reverse is not available and the check has no fix to offer.
- `AppendInLoop` now flags `&1 ++ [item]` inside a capture in a loop, when the capture is handed to a call that also receives the accumulator. `Map.update(acc, key, [item], &(&1 ++ [item]))` grows the list stored under `key` once per iteration, in exactly the way the check exists to catch. Keying off the sibling argument is what keeps `Enum.map(group, &(&1 ++ [:tag]))` inside a reduce quiet — there `&1` is a bounded element, not the accumulator. It also means a reducer written wholly as a capture, `Enum.reduce(list, [], &(&2 ++ [&1]))`, is missed: nothing else in that call names the accumulator to key off.
- `ProcessSleepInTests` now exempts a sleep inside a bounded retry helper — a `def`/`defp` that calls itself with one argument decremented by a literal. That is the polling helper the check asks for, and its sleep is the backoff between attempts rather than a guess at how long the work takes. A sleep in a test body, a `setup`, or a helper that recurses without decrementing is still reported.

- `UnusedSetupKeysInTests` is now about dead fixture *work* rather than a tidy return map, and reports it the way the compiler would if it could see across the setup/test boundary. In `company = insert(:company)` followed by `%{company: company}`, the return map counts as a use, so no unused-variable warning fires — but if no test reads `:company` the row is inserted for every test in scope and thrown away. Three changes follow from that framing:
  - **One issue per key, on the binding line** rather than one issue on the `setup do` line listing every key. The line reported is the line to delete. Keys whose map value is not a bare variable (`%{company: insert(:company)}`) still report at the setup line, since there is no binding to point at. `trigger` is now the key (`":company"`) rather than `"setup"`.
  - **A key whose variable the setup also uses is no longer reported.** Given `depot = insert(:depot, company: company)`, dropping `:company` deletes nothing — `insert(:company)` still has to run to build `depot`. Reporting it invited exactly the wrong fix: remove the key, keep the binding, then silence the resulting compiler warning with an underscore.
  - **Dead chains report in full.** Because removing a key can strand the binding that fed it, the reportable set is resolved to a fixpoint. If no test reads `:company` or `:depot` above, both are reported in one run instead of `:depot` now and `:company` after you fix it.

  Migration: `# credo:disable-for-next-line SephiaCredo.Checks.UnusedSetupKeysInTests` comments sitting above `setup do` no longer suppress anything, because issues now land on binding lines inside the block. Move the comment to the binding, or use `# credo:disable-for-this-file`.

### Fixed

- A `def` that carries `rescue`, `catch`, `else` or `after` is no longer read as though its `do` block were the whole function. Those clauses live beside `do:` rather than inside it, and every check reached for the `do:` alone. `TrivialWrapperFunction` reported `defp safe_range(node) do Sourceror.get_range(node) rescue _ -> nil end` as forwarding and nothing else, and following the advice would have deleted the error handling; `PatternMatchInFunctionHead` did the same for a `case` body with a `rescue`. `MultiStepMutationWithoutTransaction` counted the writes in a function-level `after` as zero, while counting the same code written as an explicit `try` — it now gives both the same reading, `rescue`/`catch`/`else` as alternatives to the body and `after` on top of it.
- `AppendInLoop` no longer reads a guarded reducer clause's guard as its accumulator. `fn {kind, _, [head | _]}, pairs when kind in [:def, :defp] -> ...` packs both parameters and the guard into a single `when` node, so every variable either mentions — including `head` — was taken for a list that grows, and `pair(head) ++ pairs` was reported as O(n²) when it is a bounded prepend.
- `UnusedSetupKeysInTests` and `UnusedSetupKeysPerTest` now count a `%{...} = ctx` destructure in a test body as use of those keys. Only a destructure in the test head was recognised, so a test that bound its context and unpacked it on the first line read as using nothing, and any key it consumed that way was reported as dead. The keys are harvested from the left of any match whose right side reaches the context — the same reach already used to follow a context into a helper — so a destructure of an unrelated map still does not count. Because that reach is by taint rather than by identity, a match whose right side merely mentions the context, such as `%{id: id} = Repo.get(Thing, ctx.thing_id)`, also counts its keys as consumed. That errs toward silence, as the rest of this module does.

## [0.3.0] - 2026-08-19

### Changed

- `UnusedSetupKeysInTests` and `UnusedSetupKeysPerTest` now resolve a context handed to a `def`/`defp` in the same file, following it through helper chains, pipes and `%{ctx | ...}` copies, and counting the keys that helper reads. A test that hands its context to something unresolvable — imported or remote — is treated as opaque and consumes every key in scope, so the checks stay quiet rather than report a live fixture as dead. Previously any test that passed `ctx` to a helper read as using nothing.
- `UnusedSetupKeysPerTest` now flags only a test that consumes **none** of the setup keys in scope for it. The previous rule — every test must consume every in-scope key — treated a shared fixture as a defect and was too noisy to enable: 1747 reports against 152 under the new rule, on the same 767-file suite. Its message and moduledoc now explain the cost being avoided (ExUnit has no lazy `let`), and document the case it cannot see: a `setup` whose inserted rows are queried without being named.

### Added

- `usage-rules.md`, consumed by [usage_rules](https://hexdocs.pm/usage_rules), documenting how to respond to each check — starting with the rule that a report is a suspicion to verify, not a licence to delete code.
- `SephiaCredo.TestContext`, the shared AST reading behind both setup-key checks.

## [0.2.0] - 2026-05-12

### Added

- `AshCodeInterfaceReadWithArgs` — flags `define :name, action: :read, args: [...]` inside `code_interface` blocks. Ash's generic `:read` action declares no inputs, so the resulting function raises `Ash.Error.Invalid.NoSuchInput` at runtime.
- `AssertWithoutAssertion` — flags `assert pattern = expr` in test files where the bound variables are never used afterwards. The match succeeds vacuously and tests nothing.
- `ProcessSleepInTests` — flags `Process.sleep/1` in `*_test.exs` files, including inside `setup` and `setup_all` blocks. Causes flakes and slows the suite.
- `RawRuntimeError` — flags `raise "msg"` and `raise RuntimeError, ...`. Both lower to `RuntimeError`, defeating error-tracker grouping (every message becomes its own issue).
- `SysGetStateWithoutTimeoutInPoll` *(opt-in)* — flags `:sys.get_state/1` inside a polling fn without a surrounding `try/catch :exit`. Configurable via `poll_functions:`. Not added by the installer; opt in manually.

### Changed

- `StructComparisonOperator` replaces `NoDateTimeOperatorCompare`. In addition to `Date`, `Time`, `DateTime`, and `NaiveDateTime`, it now covers `Decimal` and `Version`, and accepts an `extra_modules` config for any other struct that defines its own `compare/2`.
- `mix sephia_credo.install` registers the new default-on checks alongside the existing ones.

### Removed

- `NoDateTimeOperatorCompare` — superseded by `StructComparisonOperator`. See the "Upgrading from 0.1" section of the README for the one-line migration.

## [0.1.1] - 2026-04-17

- Igniter installer fixes.

## [0.1.0] - 2026-04-17

- Initial release with `AppendInLoop`, `NoDateTimeOperatorCompare`, `UnusedSetupKeysInTests`, `UnusedSetupKeysPerTest`.
