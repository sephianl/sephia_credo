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
          {SephiaCredo.Checks.ProcessSleepInTests, []},
          {SephiaCredo.Checks.RawRuntimeError, []},
          {SephiaCredo.Checks.StructComparisonOperator, []},
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

## Upgrading from 0.1

`NoDateTimeOperatorCompare` has been replaced with the more general `StructComparisonOperator` (now also covers `Decimal` and `Version`, with a configurable `extra_modules` list). Update your `.credo.exs`: replace the old tuple with `{SephiaCredo.Checks.StructComparisonOperator, []}`.

## Checks

| Check | Category | Description |
|---|---|---|
| `AppendInLoop` | Refactor | Flags O(n²) `++` inside loops (`reduce`, `fold`, `for/reduce`, recursive functions) |
| `AshCodeInterfaceReadWithArgs` | Warning | Flags `define :name, action: :read, args: [...]` inside `code_interface` — Ash's generic `:read` action raises at runtime when called with args |
| `AssertWithoutAssertion` | Warning | Flags `assert pattern = expr` in tests where the bound variables are never used — the match succeeds vacuously |
| `ProcessSleepInTests` | Refactor | Flags `Process.sleep` in `*_test.exs` files — causes flakes and slows the suite |
| `RawRuntimeError` | Warning | Flags `raise "msg"` and `raise RuntimeError, ...` — error trackers can't group these meaningfully |
| `StructComparisonOperator` | Warning | Forbids `<`/`>`/`<=`/`>=`/`==`/`!=` on `Date`/`Time`/`DateTime`/`NaiveDateTime`/`Decimal`/`Version` — use `*.compare/2` instead |
| `SysGetStateWithoutTimeoutInPoll` | Warning *(opt-in)* | Flags `:sys.get_state/1` inside a polling fn without surrounding `try/catch :exit` — flakes under load |
| `UnusedSetupKeysInTests` | Design | Flags `setup` return keys never destructured by any test in scope |
| `UnusedSetupKeysPerTest` | Design | Flags individual tests that don't consume all in-scope setup keys |

### AppendInLoop

Appending to a list with `++` inside a loop (`Enum.reduce`, `Enum.flat_map_reduce`, `for/reduce`, or a recursive function) creates a new copy of the left-hand list on every iteration, turning an O(n) traversal into O(n²). This check flags those call sites and suggests prepending with `[head | acc]` and reversing at the end, or collecting into a different data structure.

### AshCodeInterfaceReadWithArgs

Inside an Ash `code_interface do ... end` block, `define :name, action: :read, args: [...]` registers a code interface against Ash's generic `:read` action, which declares no inputs. Calling the resulting function raises `Ash.Error.Invalid.NoSuchInput` at runtime. The bug typically ships silently — LiveView callers wrap the call in `else {:error, _} -> ...` and the page just "doesn't do anything." Define a custom read action that declares the args, or remove `args:`.

### AssertWithoutAssertion

`assert x = expr` (or any pattern with fresh bindings on the left) succeeds vacuously: the pattern always matches a bare variable, so the assertion tests nothing about `expr`. If the bound variables are never referenced afterward, the assertion is dead. Reference them in subsequent assertions, or use `assert match?(pattern, expr)`. Test files only (`*_test.exs`).

### ProcessSleepInTests

`Process.sleep/1` in test bodies, `setup` blocks, or `setup_all` blocks causes timing-dependent flakes and slows the suite linearly. Prefer `assert_receive`, `assert_eventually`, or a polling helper. Test files only (`*_test.exs`).

### RawRuntimeError

`raise "msg"` and `raise RuntimeError, ...` both lower to a `RuntimeError` exception. Error trackers (Appsignal, Sentry, etc.) group exceptions by module name — every distinct `RuntimeError` message becomes its own issue, hiding the signal in noise. Define a `defexception` module with a descriptive name and raise that instead.

### StructComparisonOperator

Elixir's comparison operators (`<`, `>`, `==`, etc.) use Erlang's term order on structs, which walks fields in declaration order. For most calendar/numeric structs this produces silently incorrect results — for example, `Decimal.new("1.0") == Decimal.new("1.00")` returns `false`, and `Decimal.new("1.5") > Decimal.new("2")` returns `true`. This check enforces the use of `Date.compare/2`, `DateTime.compare/2`, `Decimal.compare/2`, `Version.compare/2`, etc. instead. Built-in coverage: `Date`, `Time`, `DateTime`, `NaiveDateTime`, `Decimal`, `Version`. Configurable via `extra_modules`.

### SysGetStateWithoutTimeoutInPoll *(opt-in)*

Inside a polling fn (configurable via `poll_functions:`, defaults to `[:wait_until]`), `:sys.get_state(pid)` without an explicit timeout uses the default 5-second timeout. If the GenServer is blocked (e.g. by cascading PubSub), the call raises `:exit` — which `rescue` doesn't catch — and the test crashes. Pass a short explicit timeout AND wrap in `try ... catch :exit, _ -> false`. Add this check manually to `.credo.exs` if you use poll-style test helpers.

### UnusedSetupKeysInTests

Detects keys returned from `setup` blocks that are never destructured by any `test` in the same `describe` block (or module top-level). Dead setup keys add noise and slow down test comprehension — they should be removed from the setup return value.

### UnusedSetupKeysPerTest

A more granular companion to `UnusedSetupKeysInTests`. Instead of checking whether *any* test uses a key, it checks each test individually and flags tests that don't destructure all in-scope setup keys. This helps keep tests focused by surfacing unnecessary fixtures.

## Contributing

1. [Fork](https://github.com/sephianl/sephia_credo/fork) the repository
2. Create your feature branch (`git switch -c my-new-check`)
3. Apply formatting and make sure tests pass (`mix format`, `mix test`)
4. Commit your changes
5. Open a pull request

## License

MIT - see [LICENSE](LICENSE) for details.
