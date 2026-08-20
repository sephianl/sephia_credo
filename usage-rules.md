# SephiaCredo usage rules

SephiaCredo is a set of [Credo](https://hexdocs.pm/credo) checks. It adds no runtime code — it
only reports. Everything below is about how to *respond* to what it reports.

## Start here: a check reports a suspicion, not a fact

Every check here reads the AST of one file. It cannot run the code, follow a call into another
module, or know what a fixture inserts into the database. So a report means "this looks wrong from
here" — it is a prompt to verify, not a verdict.

The failure mode this causes is specific and expensive:

```elixir
# credo says: "Setup returns keys never used by any test: :model, :solve_context"
setup do
  {:ok, model, virtual_to_real} = ModelBuilder.build_model(routing_info)

  %{model: model, solve_context: %{virtual_to_real: virtual_to_real}, plan_information: %{...}}
end

test "measures a cross-route cluster", ctx do
  {verdicts, _} = analyze(ctx, [split_cluster("1000A")], far_future())
  ...
end

defp analyze(ctx, clusters, deadline) do
  CounterfactualSplit.analyze(clusters, ctx.model, ctx.solve_context, ...)
end
```

Deleting `model:` and `solve_context:` makes the check pass and every test in the block fail with
`KeyError: key :model not found`. The keys *were* used — through the helper. (Modern SephiaCredo
resolves same-file helpers, so this exact case no longer reports, but the shape of the mistake
generalises to every check here.)

**Rule: never delete code, data, or arguments to satisfy a check until you have found where the
thing is used and confirmed it is genuinely unused.** Run the test file after the change, always.

## How to respond to a report

1. Read the message and open the reported line.
2. Verify the claim. For the setup-key checks, follow where the context goes — a `defp` in the same
   file, a helper in a `Support` module, a `%{ctx | ...}` copy.
3. Fix the cause the check names, not the symptom. Usually that means restructuring (move a fixture
   into a narrower `describe`; take the value out of the context), not deleting.
4. If the check is wrong, silence it narrowly and say why:

   ```elixir
   # credo:disable-for-next-line SephiaCredo.Checks.UnusedSetupKeysPerTest
   # the setup inserts the rows this test queries by name
   test "finds every active depot", _ctx do
   ```

   Then open an issue — a false positive is a bug in the check.

## Checks

### `AppendInLoop` (refactor)

Flags `list ++ [item]` inside `Enum.reduce`, `for/reduce`, `Enum.flat_map_reduce` or a recursive
function. `++` copies its left-hand list, so appending in a loop is O(n²).

Fix by prepending and reversing once: `Enum.reduce(items, [], &[&1 | &2]) |> Enum.reverse()`. Do
not "fix" it by moving the `++` behind a function call — the cost is the same.

### `AshCodeInterfaceReadWithArgs` (warning)

Flags `define :name, action: :read, args: [...]` in an Ash `code_interface` block. Ash's generic
`:read` action declares no inputs, so the generated function raises
`Ash.Error.Invalid.NoSuchInput` at runtime — often swallowed by a `{:error, _}` branch in a
LiveView, so the page silently does nothing.

Fix by defining a real read action that declares those args, and pointing the interface at it.

### `AssertWithoutAssertion` (warning, test files)

Flags `assert pattern = expr` where the pattern only introduces fresh bindings that are never used
afterwards. A bare variable pattern always matches, so the assertion tests nothing.

Fix by asserting on the bound values afterwards, or use `assert match?(pattern, expr)`. Deleting
the line is also valid — but only once you know what the test meant to assert.

### `ProcessSleepInTests` (refactor, test files)

Flags `Process.sleep/1` in test bodies, `setup`, and `setup_all`. It trades suite time for
flakiness on slower machines.

Fix with `assert_receive`, `assert_eventually`, or a polling helper that waits on the actual
condition. Raising the sleep duration is not a fix.

### `RawRuntimeError` (warning)

Flags `raise "msg"` and `raise RuntimeError, ...`. Error trackers group by exception module, so
every distinct message becomes its own issue and the signal disappears.

Fix with a `defexception` module named for the failure.

### `StructComparisonOperator` (warning)

Flags `<`, `>`, `<=`, `>=`, `==`, `!=` applied to `Date`, `Time`, `DateTime`, `NaiveDateTime`,
`Decimal`, `Version` (plus anything in `extra_modules`). Erlang's term order compares struct fields
in declaration order, which is silently wrong: `Decimal.new("1.5") > Decimal.new("2")` is `true`,
and `Decimal.new("1.0") == Decimal.new("1.00")` is `false`.

Fix with the struct's own `compare/2`. For equality on `Decimal`, `Decimal.equal?/2`.

### `SysGetStateWithoutTimeoutInPoll` (warning, opt-in)

Flags `:sys.get_state(pid)` inside a polling function (`poll_functions:`, default `[:wait_until]`)
without a surrounding `try/catch :exit`. The default 5s timeout exits rather than raising, so
`rescue` does not catch it and the whole test crashes under load.

Fix by passing a short explicit timeout *and* wrapping in `try ... catch :exit, _ -> false`.

### `UnusedSetupKeysInTests` (design, test files)

Flags a key returned from `setup` that no test in its scope consumes — a fixture built for every
test in the block and read by none of them.

A test consumes a key by destructuring it (`test "...", %{key: v}`), by reading it off its context
binding (`ctx.key`), or by handing the context to a `def`/`defp` **in the same file** that does
either. A context handed to something the check cannot read — an imported or remote function — makes
the test opaque, and an opaque test suppresses the report rather than risking a false positive.

Fix by removing the key from the setup's return map *after* confirming nothing reads it, or by
moving its construction to the tests that need it.

### `UnusedSetupKeysPerTest` (design, test files)

Flags a single test that consumes **none** of the keys in scope for it. ExUnit has no lazy `let`:
every key its `setup` returns is built for every test in scope, so a test that reads nothing from
the fixture still pays for it, usually in database rows.

It deliberately says nothing about a test that consumes *part* of a shared fixture — different tests
reading different parts of one setup is what `setup` is for.

Fix by moving the test out of that setup's scope, or the fixture into a narrower `describe` around
the tests that use it.

**Known limitation:** a test can depend on a fixture without naming it — `setup` inserts rows that
the code under test then queries. This check cannot see that and will flag the test. Disable it for
those files; do not delete the setup.
