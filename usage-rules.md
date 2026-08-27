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

Only the accumulator on the **left** is flagged. `item ++ acc` is prepending, not appending, and is
not reported; neither is a loop-invariant list built for a call, nor `acc ++ f(acc)`, which needs
the accumulator in order and has no prepend-and-reverse form. In a recursive function only a whole
parameter counts as the accumulator — a variable destructured out of one is a piece of it, and a
piece is bounded by the whole.

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

### `EnumAtInLoop` (refactor)

Flags `Enum.at(enumerable, i)` with a computed index inside `Enum.*`/`Stream.*` iteration,
`Task.async_stream`, or a `for` comprehension. `Enum.at` walks the enumerable to reach the index, so
calling it per element makes the loop O(n²).

Fix by indexing once outside the loop — `Map.new(Enum.with_index(rows), fn {r, i} -> {i, r} end)` —
or, when the collections line up positionally, iterate them together with `Enum.zip/2` and drop the
index. A non-negative integer-literal index is bounded work and is not reported. A negative one is
reported: reaching `-1` walks to the end. Hoist it — the enumerable does not change per iteration.
`List.last/1` is the same O(n) walk and is not a fix.

**Before acting, check how big the collection is.** The check cannot see that, so `Enum.at` over a
three-element config list is reported exactly like a walk over a large matrix. Both are O(n²); only
one is worth changing. If it is small and fixed, silence the line rather than restructuring.

### `KeywordBagParameter` (refactor)

Flags a parameter the body only reaches into with `Keyword.get/fetch/fetch!/take/has_key?`. Reading
three or more distinct keys off one parameter means it is a parameter list in disguise.

Fix by naming the keys as parameters — the issue message spells out the signature. Do **not** "fix"
it by renaming `opts`: detection is by shape, so the report is unchanged and nothing improved. A
keyword list that is purely forwarded is never reported, and neither is one the body reads keys off
*and* passes on whole, nor an `@impl` callback whose arity the behaviour fixes.

Tune with `min_keys` (default 3) and `ignored_keys` (framework keys that get forwarded, not named).

### `MapAsSet` (refactor)

Flags `Enum.member?(Map.keys(map), key)`, its pipe form, and `key in Map.keys(map)` — all the same
AST. Each builds the full key list and scans it, where `Map.has_key?(map, key)` answers in O(1).

Fix with `Map.has_key?/2`. If the thing is conceptually a set rather than a map you are indexing,
`MapSet.member?/2` is also constant time. `Map.values/1` membership is not flagged — there is no
constant-time equivalent, so there would be no fix to suggest.

### `MultiStepMutationWithoutTransaction` (warning)

Flags a function performing 2+ database mutations without `Repo.transaction/1`, `Ash.transaction/2`,
or `Ecto.Multi`. If the second write fails, the first is already committed and the row set is
half-updated.

Counts `Repo.*` writes (any alias ending in `Repo`), direct `Ash.*` mutations, and Ash code-interface
calls on resources listed in `ash_resources:`. Local mutating helpers are followed, so moving the
writes into private functions does not hide them.

Branches are not summed — a `case`/`cond`/`if`/`with`/`fn`/`try` contributes its worst branch, not
the total, and a function-level `rescue`/`catch`/`else`/`after` reads the same as the `try` it lowers
to. Writes are counted per call site, so a single write inside a loop counts as one. Test files are
skipped entirely (the ExUnit sandbox rolls each test back).

Fix by wrapping the sequence in a transaction. Do not "fix" it by moving one write into a helper —
the check follows local calls, and the atomicity problem is unchanged either way. If the writes are
deliberately non-atomic — progress or telemetry committed ahead of the work it describes — add the
function to `excluded_functions:` rather than restructuring it.

### `PatternMatchInFunctionHead` (refactor)

Flags a single-clause function whose entire body is a `case` on one of its own parameters. Those are
function clauses written the long way.

Fix by moving each `case` pattern into its own function head. Only the unambiguous shape is reported
— one clause, no guard, whole body is a `case` on a bare parameter with more than one branch, and no
`rescue`/`catch`/`else`/`after` clause on the function — so a report here always has a mechanical
fix.

### `PreloadInLoop` (warning)

Flags `Repo.preload` or `Ash.load` inside `Enum.*`/`Stream.*` iteration, `Task.async_stream`, or a
`for` comprehension: one query per element, the textbook N+1.

Fix by loading the collection once — `Repo.preload(users, :posts)` or `Ash.load(records, :items)`;
both take a list and batch the queries. Only per-element regions are examined, so the batched call
that *feeds* a loop is already correct and is not what the report is pointing at — read the line
number before rewriting anything.

### `ProcessSleepInTests` (refactor, test files)

Flags `Process.sleep/1` in test bodies, `setup`, and `setup_all`. It trades suite time for
flakiness on slower machines.

Fix with `assert_receive`, `assert_eventually`, or a polling helper that waits on the actual
condition. Raising the sleep duration is not a fix.

A sleep inside a bounded retry helper — a `def`/`defp` that calls itself with one argument
decremented by a literal — is exempt. That sleep is the backoff between attempts, which is what the
fix above asks you to write.

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

### `TrivialWrapperFunction` (refactor)

Flags a single-clause `defp` whose whole body is one call to another module, forwarding its
parameters unchanged.

Fix by calling the target directly at the call site and deleting the wrapper. Do not "fix" it by
adding a pointless argument to make it look non-trivial. Wrappers that supply an argument, reorder
or transform them, match a pattern, guard, carry a default, or add a `rescue`/`catch`/`else`/`after`
clause are already not reported.

### `UnusedSetupKeysInTests` (design, test files)

Flags fixture work a `setup` does that no test in its scope reads. This is the unused-variable
warning the compiler cannot give you: in `company = insert(:company); %{company: company}` the
return map counts as a use, so the compiler stays quiet — but if no test reads `:company`, the row
is inserted for every test in the block and thrown away.

A test consumes a key by destructuring it — in its head (`test "...", %{key: v}`) or anywhere in its
body (`%{key: v} = ctx`) — by reading it off its context binding (`ctx.key`), or by handing the
context to a `def`/`defp` **in the same file** that does either. A context handed to something the
check cannot read — an imported or remote function — makes the test opaque, and an opaque test
suppresses the report rather than risking a false positive.

The issue points at the binding line, not at `setup do` — that is the line to delete. A key whose
variable the setup also uses for something else is not reported, since removing it would delete
nothing.

Fix by deleting the binding *and* its key, *after* confirming nothing reads it — or by moving the
construction to the tests that need it. Dropping only the key is not a fix: the work still runs, and
you will silence the compiler warning it now raises by renaming to `_company`.

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
