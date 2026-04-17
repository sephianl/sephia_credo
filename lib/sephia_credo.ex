defmodule SephiaCredo do
  @moduledoc """
  Credo checks for common Elixir pitfalls.

  ## Included checks

  - `SephiaCredo.Checks.AppendInLoop` — flags O(n²) `++` inside loops
  - `SephiaCredo.Checks.NoDateTimeOperatorCompare` — forbids `<`/`>`/`==`/`!=` on date/time values
  - `SephiaCredo.Checks.UnusedSetupKeysInTests` — flags setup keys never used by any test
  - `SephiaCredo.Checks.UnusedSetupKeysPerTest` — flags tests that don't consume all in-scope setup keys

  ## Installation

  Add to your `mix.exs`:

      {:sephia_credo, "~> 0.1", only: [:dev, :test], runtime: false}

  Then run the Igniter installer to auto-configure your `.credo.exs`:

      mix igniter.install sephia_credo
  """
end
