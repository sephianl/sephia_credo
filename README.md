# SephiaCredo

Credo checks for common Elixir pitfalls.

## Checks

| Check | Category | Description |
|-------|----------|-------------|
| `SephiaCredo.Checks.AppendInLoop` | Refactor | Flags O(n²) `++` inside loops (reduce, fold, for/reduce, recursive functions) |
| `SephiaCredo.Checks.NoDateTimeOperatorCompare` | Warning | Forbids `<`/`>`/`<=`/`>=`/`==`/`!=` on date/time values — use `*.compare/2` instead |
| `SephiaCredo.Checks.UnusedSetupKeysInTests` | Design | Flags `setup` return keys never destructured by any test in scope |
| `SephiaCredo.Checks.UnusedSetupKeysPerTest` | Design | Flags individual tests that don't consume all in-scope setup keys |

## Installation

Add `sephia_credo` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sephia_credo, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

Then run the Igniter installer to auto-configure your `.credo.exs`:

```bash
mix igniter.install sephia_credo
```

This adds all checks to your Credo config with default settings.

## License

MIT
