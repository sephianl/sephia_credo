defmodule SephiaCredo.Checks.UnusedSetupKeysInTests do
  use Credo.Check,
    base_priority: :low,
    category: :design,
    explanations: [
      check: """
      Every key a `setup` returns is built for every test in its scope, and
      the return map counts as a use, so the compiler cannot warn when no test
      reads it.

          setup do
            company = insert(:company)
            %{company: company}
          end

      If no test reads `:company`, that row is inserted for every test and
      thrown away. Delete the binding and its key together — dropping only the
      key leaves the work running.
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
      check_unused(
        module_setup_keys,
        all_used_keys,
        all_tests,
        module_setup_line,
        module_body,
        issue_meta
      )

    describe_issues =
      Enum.flat_map(describes, fn body ->
        {keys, line} = TestContext.setup(body)
        tests = TestContext.tests(body, helpers)
        used = tests |> Enum.flat_map(& &1.keys) |> Enum.uniq()

        check_unused(keys, used, tests, line, body, issue_meta)
      end)

    module_issues ++ describe_issues
  end

  defp check_unused([], _used, _tests, _line, _body, _issue_meta), do: []

  defp check_unused(setup_keys, used_keys, tests, setup_line, body, issue_meta) do
    if Enum.any?(tests, & &1.opaque?) do
      []
    else
      body
      |> TestContext.dead_setup_keys(setup_keys -- used_keys)
      |> Enum.map(&dead_issue(&1, setup_line, issue_meta))
    end
  end

  defp dead_issue({key, nil, _line}, setup_line, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "Setup returns `:#{key}` but no test in scope uses it, so every test " <>
          "pays to build it. Remove it from the setup return map.",
      trigger: ":#{key}",
      line_no: setup_line
    )
  end

  defp dead_issue({key, var, line}, _setup_line, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{var}` is built for every test in scope, but no test uses `:#{key}`, " <>
          "so its result is thrown away. The compiler cannot warn about this — " <>
          "the setup return map counts as a use. Delete the binding and its key.",
      trigger: ":#{key}",
      line_no: line
    )
  end
end
