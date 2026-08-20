defmodule SephiaCredo.Checks.UnusedSetupKeysInTests do
  @moduledoc """
  Flags any `setup` return key that is not consumed by some test in
  its scope.

  - A module-level `setup` is in scope for every test in the module
    (whether the test lives at module level or inside a `describe`).
  - A `describe`-local `setup` is in scope for the tests inside that
    describe only.

  A test consumes a key by destructuring it, by reading it off its context
  binding (`ctx.key`), or by handing that context to a helper in the same file
  that does either. A test that hands its context to something unresolvable —
  an imported or remote function — is left alone, since its key use cannot be
  known.

  Setups returning `%{...}` or `{:ok, %{...}}` are both supported.
  Underscore-prefixed bindings (`%{foo: _foo}`) do not count as use.
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
    {module_setup_keys, module_setup_line} = TestContext.setup(module_body)
    describes = TestContext.describe_blocks(ast)
    helpers = TestContext.helpers(ast)

    all_tests =
      TestContext.tests(module_body, helpers) ++
        Enum.flat_map(describes, &TestContext.tests(&1, helpers))

    all_used_keys =
      all_tests
      |> Enum.flat_map(& &1.keys)
      |> Kernel.++(Enum.flat_map(describes, &TestContext.setup_destructures/1))
      |> Enum.uniq()

    module_issues =
      check_unused(module_setup_keys, all_used_keys, all_tests, module_setup_line, issue_meta)

    describe_issues =
      Enum.flat_map(describes, fn body ->
        {keys, line} = TestContext.setup(body)
        tests = TestContext.tests(body, helpers)
        used = tests |> Enum.flat_map(& &1.keys) |> Enum.uniq()

        check_unused(keys, used, tests, line, issue_meta)
      end)

    module_issues ++ describe_issues
  end

  defp check_unused([], _used, _tests, _line, _issue_meta), do: []

  defp check_unused(setup_keys, used_keys, tests, setup_line, issue_meta) do
    if Enum.any?(tests, & &1.opaque?),
      do: [],
      else: unused_issue(setup_keys -- used_keys, setup_line, issue_meta)
  end

  defp unused_issue([], _setup_line, _issue_meta), do: []

  defp unused_issue(unused, setup_line, issue_meta) do
    unused_str = Enum.map_join(unused, ", ", &":#{&1}")

    [
      format_issue(
        issue_meta,
        message:
          "Setup returns keys never used by any test: #{unused_str}. " <>
            "Remove from the setup return map.",
        trigger: "setup",
        line_no: setup_line
      )
    ]
  end
end
