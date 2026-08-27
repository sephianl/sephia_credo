defmodule SephiaCredo.Checks.UnusedSetupKeysPerTest do
  use Credo.Check,
    base_priority: :low,
    category: :design,
    explanations: [
      check: """
      ExUnit has no lazy `let`: a test pays for the whole fixture in scope even
      when it reads none of it.

      Move the test into a `describe` whose `setup` does not build the fixture,
      or narrow the fixture to a `describe` around the tests that use it.

      A test that consumes *part* of a shared fixture is not reported — that is
      what sharing a fixture is for.
      """
    ]

  alias SephiaCredo.TestContext
  alias SephiaCredo.TestFile

  @impl true
  def run(source_file, params \\ []) do
    if TestFile.test_file?(source_file) do
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
