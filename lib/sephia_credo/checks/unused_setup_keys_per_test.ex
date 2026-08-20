defmodule SephiaCredo.Checks.UnusedSetupKeysPerTest do
  @moduledoc """
  Flags a test that consumes none of the `setup` keys in scope for it.

  ExUnit has no lazy `let`: every key a `setup` returns is built for every test
  in its scope, whether that test looks at it or not. A test that reads nothing
  out of the fixture still pays for it — usually in database rows. The fix is to
  move that test into a `describe` whose setup does not build the fixture, or to
  move the fixture into a narrower `describe` around the tests that do use it.

  This is the narrow companion to `SephiaCredo.Checks.UnusedSetupKeysInTests`,
  which asks whether *any* test uses a key. This one asks whether *this* test
  uses any key at all, and stays quiet about a test that consumes part of a
  shared fixture — sharing a fixture across tests that each read a different
  part of it is the point of `setup`, not a defect.

  A test consumes a key if it destructures it (`test "...", %{key: var}`), reads
  it off its context binding (`ctx.key`), or hands the context to a helper in
  the same file that does either. A test that hands its context to something
  unresolvable — an imported or remote function — is left alone, since its key
  use cannot be known.

  ## Known limitation

  A test can depend on a fixture without naming it: `setup` that inserts rows
  which the code under test then queries. This check cannot see that, and will
  flag such a test. Disable it for those files rather than deleting the setup.
  """

  use Credo.Check,
    base_priority: :low,
    category: :design

  alias SephiaCredo.TestContext

  @impl true
  def run(%Credo.SourceFile{filename: filename} = source_file, params \\ []) do
    if String.ends_with?(filename, "_test.exs") do
      issue_meta = IssueMeta.for(source_file, params)

      case Credo.Code.ast(source_file) do
        {:ok, ast} -> find_issues(ast, issue_meta)
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp find_issues(ast, issue_meta) do
    module_body = TestContext.module_body(ast)
    {module_setup_keys, _line} = TestContext.setup(module_body)
    helpers = TestContext.helpers(ast)

    module_issues =
      module_body
      |> TestContext.tests(helpers)
      |> Enum.flat_map(&check_test(&1, module_setup_keys, issue_meta))

    describe_issues =
      ast
      |> TestContext.describe_blocks()
      |> Enum.flat_map(fn body ->
        {describe_keys, _line} = TestContext.setup(body)
        in_scope = Enum.uniq(module_setup_keys ++ describe_keys)

        body
        |> TestContext.tests(helpers)
        |> Enum.flat_map(&check_test(&1, in_scope, issue_meta))
      end)

    module_issues ++ describe_issues
  end

  defp check_test(_test, [], _issue_meta), do: []
  defp check_test(%{opaque?: true}, _in_scope_keys, _issue_meta), do: []

  defp check_test(test, in_scope_keys, issue_meta) do
    if Enum.any?(in_scope_keys, &(&1 in test.keys)),
      do: [],
      else: [unused_issue(in_scope_keys, test.line, issue_meta)]
  end

  defp unused_issue(in_scope_keys, line, issue_meta) do
    keys = Enum.map_join(in_scope_keys, ", ", &":#{&1}")

    format_issue(
      issue_meta,
      message:
        "Test consumes none of the setup keys in scope: #{keys}. " <>
          "The fixture is built for it anyway — move the test out of this setup's scope, " <>
          "or the fixture into a narrower `describe`.",
      trigger: "test",
      line_no: line
    )
  end
end
