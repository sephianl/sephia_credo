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
          {SephiaCredo.Checks.NoDateTimeOperatorCompare, []},
          {SephiaCredo.Checks.UnusedSetupKeysInTests, []},
          {SephiaCredo.Checks.UnusedSetupKeysPerTest, []}
        ]
      }
    }
  ]
}
```

## Checks

| Check | Category | Description |
|---|---|---|
| `AppendInLoop` | Refactor | Flags O(n²) `++` inside loops (`reduce`, `fold`, `for/reduce`, recursive functions) |
| `NoDateTimeOperatorCompare` | Warning | Forbids `<`/`>`/`<=`/`>=`/`==`/`!=` on date/time values — use `*.compare/2` instead |
| `UnusedSetupKeysInTests` | Design | Flags `setup` return keys never destructured by any test in scope |
| `UnusedSetupKeysPerTest` | Design | Flags individual tests that don't consume all in-scope setup keys |

### AppendInLoop

Appending to a list with `++` inside a loop (`Enum.reduce`, `Enum.flat_map_reduce`, `for/reduce`, or a recursive function) creates a new copy of the left-hand list on every iteration, turning an O(n) traversal into O(n²). This check flags those call sites and suggests prepending with `[head | acc]` and reversing at the end, or collecting into a different data structure.

### NoDateTimeOperatorCompare

Elixir's comparison operators (`<`, `>`, `==`, etc.) use structural comparison on `Date`, `Time`, `DateTime`, and `NaiveDateTime` structs, which can produce incorrect results. For example, `~D[2024-02-01] > ~D[2024-01-31]` happens to work, but `~T[09:00:00] > ~T[10:00:00]` does not behave as expected in all cases. This check enforces the use of `Date.compare/2`, `Time.compare/2`, `DateTime.compare/2`, or `NaiveDateTime.compare/2` instead.

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
