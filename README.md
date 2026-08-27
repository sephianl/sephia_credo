# SephiaCredo

[![Hex.pm](https://img.shields.io/hexpm/v/sephia_credo.svg)](https://hex.pm/packages/sephia_credo)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/sephia_credo)
[![License: MIT](https://img.shields.io/badge/license-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)

[Credo](https://github.com/rrrene/credo) checks for common Elixir pitfalls.

SephiaCredo catches performance anti-patterns, incorrect operator usage, and dead code in your test setups — issues that the compiler and standard Credo rules miss.

## Installation

SephiaCredo requires [Credo](https://hexdocs.pm/credo) to already be installed in your project.

### With Igniter (recommended)

If your project uses [Igniter](https://hexdocs.pm/igniter), a single command will add the dependency and register all checks in your `.credo.exs`:

```bash
mix igniter.install sephia_credo --only dev,test
```

### Manual

Add `sephia_credo` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sephia_credo, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Then fetch the dependency and add the checks to the `extra` section of your `.credo.exs`:

```bash
mix deps.get
```

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          {SephiaCredo.Checks.AppendInLoop, []},
          {SephiaCredo.Checks.AshCodeInterfaceReadWithArgs, []},
          {SephiaCredo.Checks.AssertWithoutAssertion, []},
          {SephiaCredo.Checks.EnumAtInLoop, []},
          {SephiaCredo.Checks.KeywordBagParameter, []},
          {SephiaCredo.Checks.MapAsSet, []},
          {SephiaCredo.Checks.MultiStepMutationWithoutTransaction, []},
          {SephiaCredo.Checks.PatternMatchInFunctionHead, []},
          {SephiaCredo.Checks.PreloadInLoop, []},
          {SephiaCredo.Checks.ProcessSleepInTests, []},
          {SephiaCredo.Checks.RawRuntimeError, []},
          {SephiaCredo.Checks.StructComparisonOperator, []},
          {SephiaCredo.Checks.TrivialWrapperFunction, []},
          {SephiaCredo.Checks.UnusedSetupKeysInTests, []},
          {SephiaCredo.Checks.UnusedSetupKeysPerTest, []}
          # Opt-in (not enabled by default):
          # {SephiaCredo.Checks.SysGetStateWithoutTimeoutInPoll, []}
        ]
      }
    }
  ]
}
```

## Upgrading from 0.3

`UnusedSetupKeysInTests` now reports on the **binding line** inside the `setup` block — the line to delete — instead of once on the `setup do` line. A `# credo:disable-for-next-line SephiaCredo.Checks.UnusedSetupKeysInTests` comment sitting above `setup do` therefore suppresses nothing any more, and the issues it was hiding will reappear. Move the comment down to the binding it covers, or switch that file to `# credo:disable-for-this-file`.

Seven checks are new and enabled by default in the generated config — `EnumAtInLoop`, `KeywordBagParameter`, `MapAsSet`, `MultiStepMutationWithoutTransaction`, `PatternMatchInFunctionHead`, `PreloadInLoop`, `TrivialWrapperFunction`. Adding them to an existing `.credo.exs` is opt-in; nothing changes until you do. `MultiStepMutationWithoutTransaction` sees Ash code-interface calls only once you list your resource modules in `ash_resources:`.

## Upgrading from 0.2

`UnusedSetupKeysPerTest` now flags only a test that consumes **none** of the setup keys in scope for it, instead of every test that fails to consume all of them. The old rule treated a shared fixture as a defect and was too noisy to enable — on a 767-file suite it reported 1747 issues, against 152 under the new rule. No config change is needed; expect far fewer reports.

Both setup-key checks now follow a context handed to a `def`/`defp` in the same file, so `analyze(ctx, ...)` helper patterns no longer report their keys as unused.

## Upgrading from 0.1

`NoDateTimeOperatorCompare` has been replaced with the more general `StructComparisonOperator` (now also covers `Decimal` and `Version`, with a configurable `extra_modules` list). Update your `.credo.exs`: replace the old tuple with `{SephiaCredo.Checks.StructComparisonOperator, []}`.

## Checks

| Check | Category | Description |
|---|---|---|
| `AppendInLoop` | Refactor | Flags O(n²) `++` inside loops (`reduce`, `fold`, `for/reduce`, recursive functions) |
| `AshCodeInterfaceReadWithArgs` | Warning | Flags `define :name, action: :read, args: [...]` inside `code_interface` — Ash's generic `:read` action raises at runtime when called with args |
| `AssertWithoutAssertion` | Warning | Flags `assert pattern = expr` in tests where the bound variables are never used — the match succeeds vacuously |
| `EnumAtInLoop` | Refactor | Flags `Enum.at` with a computed or negative index inside a loop — O(n) per element, so O(n²) overall |
| `KeywordBagParameter` | Refactor | Flags a parameter the body only reaches into with `Keyword.get/fetch/take` — a parameter list in disguise |
| `MapAsSet` | Refactor | Flags membership testing against `Map.keys/1` — allocates and scans where `Map.has_key?/2` is O(1) |
| `MultiStepMutationWithoutTransaction` | Warning | Flags a function performing 2+ database mutations outside a transaction — a mid-sequence failure leaves partial state |
| `PatternMatchInFunctionHead` | Refactor | Flags a single-clause function whose whole body is a `case` on one of its own parameters |
| `PreloadInLoop` | Warning | Flags `Repo.preload` / `Ash.load` inside `Enum.*`, `Stream.*`, `Task.async_stream` or `for` — one query per element (N+1) |
| `ProcessSleepInTests` | Refactor | Flags `Process.sleep` in `*_test.exs` files — causes flakes and slows the suite |
| `RawRuntimeError` | Warning | Flags `raise "msg"` and `raise RuntimeError, ...` — error trackers can't group these meaningfully |
| `StructComparisonOperator` | Warning | Forbids `<`/`>`/`<=`/`>=`/`==`/`!=` on `Date`/`Time`/`DateTime`/`NaiveDateTime`/`Decimal`/`Version` — use `*.compare/2` instead |
| `SysGetStateWithoutTimeoutInPoll` | Warning *(opt-in)* | Flags `:sys.get_state/1` inside a polling fn without surrounding `try/catch :exit` — flakes under load |
| `TrivialWrapperFunction` | Refactor | Flags a single-clause `defp` that only forwards its arguments to another module |
| `UnusedSetupKeysInTests` | Design | Flags `setup` fixture work no test in scope reads — the unused-variable warning the compiler can't give you |
| `UnusedSetupKeysPerTest` | Design | Flags a test that consumes none of the setup keys in scope for it |

### AppendInLoop

Appending to a list with `++` inside a loop (`Enum.reduce`, `Enum.flat_map_reduce`, `for/reduce`, or a recursive function) creates a new copy of the left-hand list on every iteration, turning an O(n) traversal into O(n²). This check flags those call sites and suggests prepending with `[head | acc]` and reversing at the end, or collecting into a different data structure.

Only the accumulator on the **left** is flagged — that is the list that grows. `item ++ acc` copies the bounded left side and is the idiomatic way to prepend a list, so it is left alone, as is `[item] ++ list` and a loop-invariant list built for a call. `acc ++ f(acc)` is left alone too: feeding the accumulator back in means each step needs it in order, so prepend-and-reverse is not available. Inside a capture, `&1` counts as the accumulator only when the capture is handed to a call that also receives the accumulator — `Map.update(acc, key, [item], &(&1 ++ [item]))` grows the list stored under `key`. A capture the accumulator never reaches, such as `Enum.map(group, &(&1 ++ [:tag]))`, appends to a bounded element and is left alone.

### AshCodeInterfaceReadWithArgs

Inside an Ash `code_interface do ... end` block, `define :name, action: :read, args: [...]` registers a code interface against Ash's generic `:read` action, which declares no inputs. Calling the resulting function raises `Ash.Error.Invalid.NoSuchInput` at runtime. The bug typically ships silently — LiveView callers wrap the call in `else {:error, _} -> ...` and the page just "doesn't do anything." Define a custom read action that declares the args, or remove `args:`.

### AssertWithoutAssertion

`assert x = expr` (or any pattern with fresh bindings on the left) succeeds vacuously: the pattern always matches a bare variable, so the assertion tests nothing about `expr`. If the bound variables are never referenced afterward, the assertion is dead. Reference them in subsequent assertions, or use `assert match?(pattern, expr)`. Test files only (`*_test.exs`).

### EnumAtInLoop

`Enum.at(list, i)` walks the enumerable to reach index `i`. Called once per element of another collection, that turns an O(n) traversal into O(n²) — the same class of bug as `AppendInLoop`. Fix by indexing the collection once into a map, or by iterating both collections together with `Enum.zip/2` and dropping the index entirely.

A non-negative integer-literal index is not flagged: `Enum.at(list, 3)` takes at most four steps, bounded by the literal rather than by the length of the list. A negative literal *is* flagged — reaching `-1` means walking to the end, so it costs O(n) like any computed index. The fix is to take the element once before the loop; swapping in `List.last/1` is the same walk and changes nothing. As with `PreloadInLoop`, only per-element regions are examined, so `Enum.at` in the collection a loop iterates over is not reported.

Known limitation: the check cannot know how large a collection is, so `Enum.at` over a three-element list inside a loop is reported the same as a walk over a large matrix. Both are O(n²); only one is worth your time.

### KeywordBagParameter

A parameter the body only reaches into with `Keyword.get/fetch/fetch!/take/has_key?` is a parameter list wearing a disguise — it hides the real signature from the caller, from the compiler, and from pattern matching. The check reports the keys it found, so the message names the signature to write:

> `create_order` reads `:customer`, `:address`, `:priority` out of `opts` — name them: `create_order(customer, address, priority)`

Detection is by **shape, not by parameter name**, so renaming `opts` to `options` changes nothing. A keyword list that is only forwarded (`def all(query, opts), do: Repo.all(query, opts)`) reads no keys and is never reported. Neither is one the body reads keys off *and* passes on whole — the callee still wants the list, so the signature in the message would not compile — nor a callback marked `@impl`, whose arity belongs to the behaviour rather than to you.

`min_keys` (default `3`) sets how many distinct keys make a bag. `ignored_keys` lists keys conventionally forwarded rather than turned into parameters — `:actor`, `:authorize?`, `:tenant`, `:domain`, `:context`, `:timeout`, `:tracer` by default. This is the most opinionated check in the set; `min_keys` is the dial.

### MapAsSet

`Enum.member?(Map.keys(map), key)` builds the entire key list and scans it linearly, where the map answers the same question in O(1). The pipe form and `key in Map.keys(map)` are the same AST — `in` on a non-literal right side compiles to `Enum.member?/2`. All three become `Map.has_key?(map, key)`.

Only `Map.keys/1` is flagged. `Map.values/1` has no constant-time membership equivalent, so reporting it would be a complaint with no fix.

### MultiStepMutationWithoutTransaction

A function that performs two or more database mutations without wrapping them in `Repo.transaction/1`, `Ash.transaction/2`, or an `Ecto.Multi` leaves the database in a partial state if one of them fails. Counts `Repo.*` writes (any alias ending in `Repo`), direct `Ash.*` mutations, and — when you list resource modules in `ash_resources:` — Ash code-interface calls on them. Local helpers that mutate are followed, so dispatching the writes into private functions doesn't hide them.

Mutually exclusive paths are not summed: a `case`, `cond`, `if`/`else`, `with`/`else`, `fn` with multiple clauses, or a `try`'s handler contributes its *worst* branch, not the total across branches. So a `case` that dispatches to a different single-write helper per branch is not a finding, and neither is `try do work() rescue _ -> record_failure() end` — the handler compensates for the body rather than continuing it. A function-level `rescue`/`catch`/`else`/`after` reads exactly like the `try` it lowers to, so the handlers are alternatives to the body and `after` counts on top of it.

Mutations are counted per call site, so a single write inside a loop (`Enum.each(items, &Repo.delete/1)`) counts as one and is not reported on its own.

Test files are skipped: ExUnit's SQL sandbox wraps each test in a transaction and rolls it back, so the failure mode can't occur there. Use `excluded_functions:` for anything else you want quiet — progress or telemetry writes that are deliberately committed ahead of the work they describe are the common case.

### PatternMatchInFunctionHead

A single-clause function whose entire body is a `case` on one of its own parameters is multiple function clauses written the long way. Move the patterns into the head, where the compiler checks them and the reader sees the shapes up front.

Only the unambiguous shape is reported: one clause, no guard on the head, and the whole body is a `case` on a *bare parameter* with more than one branch. A `case` on anything computed, one that is part of a larger body, or one whose function also carries a `rescue`/`catch`/`else`/`after` clause — which has nowhere to go once the body is split across heads — stays put.

### PreloadInLoop

`Repo.preload` or `Ash.load` inside `Enum.*`/`Stream.*` iteration, `Task.async_stream`, or a `for` comprehension runs one query per element — the textbook N+1. Load the collection in one call instead: `Repo.preload(users, :posts)`, `Ash.load(records, :items)`; both accept a list and batch the queries.

Only the parts of a loop that run per element are examined — the lambda handed to an iterating call, and a comprehension's body and filters. The collection being iterated is evaluated once, so the batched form this check asks for (`Enum.map(Repo.preload(users, :posts), &...)`) is not itself reported.

### ProcessSleepInTests

`Process.sleep/1` in test bodies, `setup` blocks, or `setup_all` blocks causes timing-dependent flakes and slows the suite linearly. Prefer `assert_receive`, `assert_eventually`, or a polling helper. Test files only (`*_test.exs`).

A sleep inside a bounded retry helper is exempt — a `def`/`defp` that calls itself with one argument decremented by a literal is the polling helper this check asks for, and its sleep is the backoff between attempts, not a guess at how long the work takes.

### RawRuntimeError

`raise "msg"` and `raise RuntimeError, ...` both lower to a `RuntimeError` exception. Error trackers (Appsignal, Sentry, etc.) group exceptions by module name — every distinct `RuntimeError` message becomes its own issue, hiding the signal in noise. Define a `defexception` module with a descriptive name and raise that instead.

### StructComparisonOperator

Elixir's comparison operators (`<`, `>`, `==`, etc.) use Erlang's term order on structs, which walks fields in declaration order. For most calendar/numeric structs this produces silently incorrect results — for example, `Decimal.new("1.0") == Decimal.new("1.00")` returns `false`, and `Decimal.new("1.5") > Decimal.new("2")` returns `true`. This check enforces the use of `Date.compare/2`, `DateTime.compare/2`, `Decimal.compare/2`, `Version.compare/2`, etc. instead. Built-in coverage: `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Decimal`, `Version`. Configurable via `extra_modules`.

The operators are treated asymmetrically. For `<`, `>`, `<=`, `>=`, one recognisable side is enough to flag — those operators are only meaningful on ordered structs anyway. For `==` and `!=`, *both* sides must be recognisable struct values, so a comparison like `record.field == ~U[...]` is left alone: the left side could just as easily be `nil`.

### SysGetStateWithoutTimeoutInPoll *(opt-in)*

Inside a polling fn (configurable via `poll_functions:`, defaults to `[:wait_until]`), `:sys.get_state(pid)` without an explicit timeout uses the default 5-second timeout. If the GenServer is blocked (e.g. by cascading PubSub), the call raises `:exit` — which `rescue` doesn't catch — and the test crashes. Pass a short explicit timeout AND wrap in `try ... catch :exit, _ -> false`. Add this check manually to `.credo.exs` if you use poll-style test helpers.

### TrivialWrapperFunction

A private function whose whole body is one call to another module, passing its parameters straight through, adds a name and nothing else — and hides which module actually does the work. Call the target at the call site and delete the wrapper.

A wrapper that earns its keep is not reported: supplying an argument (`defp fetch(id), do: Repo.get(Thing, id)`), supplying an option, reordering or transforming arguments, matching a pattern, guarding, or carrying a default. Nor is one that adds a `rescue`, `catch`, `else` or `after` clause — that handler is usually the whole reason the wrapper exists, and deleting the wrapper would delete it too. Only single-clause `defp` is reported — a public delegation is what `defdelegate` is for.

### UnusedSetupKeysInTests

This is the unused-variable warning the compiler cannot give you. ExUnit has no lazy `let`: every key a `setup` returns is built for every test in its scope, whether that test looks at it or not.

```elixir
setup do
  company = insert(:company)
  %{company: company}
end
```

`company` looks used — it is in the return map — so the compiler stays quiet. It is only genuinely used if some test reads `:company` off the context, and the compiler cannot see across that boundary. If none does, `insert(:company)` runs for every test in scope and the row is thrown away. The check reports the binding line, so the fix is to delete that line and its key.

A test consumes a key by destructuring it — in its head (`test "...", %{key: v}`) or anywhere in its body (`%{key: v} = ctx`) — by reading it off its context binding (`ctx.key`), or by handing the context to a `def`/`defp` **in the same file** that does either — so the common `analyze(ctx, ...)` helper pattern is understood. A context handed to something the check cannot read (an imported or remote function) makes the test opaque, and an opaque test suppresses the report rather than risking a false positive.

A key whose variable the setup also uses for something else is not reported — dropping `%{company: company}` from the map deletes nothing if `depot = insert(:depot, company: company)` still needs it. When a whole chain is dead, every link is reported at once rather than one layer per run.

Before deleting a key to satisfy this check, confirm nothing reads it. See [usage-rules.md](usage-rules.md) for why that order matters.

### UnusedSetupKeysPerTest

The narrow companion to `UnusedSetupKeysInTests`. Where that one asks whether *any* test uses a key, this one asks whether *this* test uses any key at all, and flags a test that consumes none of the fixture in scope for it.

It deliberately says nothing about a test that consumes *part* of a shared fixture — different tests reading different parts of one setup is what `setup` is for.

Known limitation: a test can depend on a fixture without naming it, when `setup` inserts rows that the code under test then queries. This check cannot see that and will flag such a test — disable it for those files rather than deleting the setup.

## Usage rules for AI agents

This package ships a [usage-rules.md](usage-rules.md) consumed by [usage_rules](https://hexdocs.pm/usage_rules). It documents how to respond to each check — in particular, that a report is a suspicion to verify rather than a licence to delete code:

```bash
mix usage_rules.sync AGENTS.md sephia_credo
```

## Contributing

1. [Fork](https://github.com/sephianl/sephia_credo/fork) the repository
2. Create your feature branch (`git switch -c my-new-check`)
3. Apply formatting and make sure tests pass (`mix format`, `mix test`)
4. Commit your changes
5. Open a pull request

## License

MIT - see [LICENSE](LICENSE) for details.
