defmodule SephiaCredo.Checks.PreloadInLoop do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `Repo.preload` or `Ash.load` inside `Enum.*`/`Stream.*` iteration,
      `Task.async_stream`, or a `for` comprehension runs one query per element —
      the textbook N+1 problem.

      Load the entire collection in a single call:

          Repo.preload(users, :posts)
          Ash.load(records, :items)

      rather than iterating and loading element-by-element. Both functions
      accept a list and batch the underlying queries.

      Test code is left alone: `*_test.exs` files and anything under `test/`
      that is not under `lib/`, such as `test/support`. A test's loop runs over
      a handful of fixture rows, so a load per element costs nothing worth
      saving. `include_tests: true` checks test code too.

      A loop over a collection that holds at most one element for a reason
      outside the code is fine. Name the function holding it in `.credo.exs`,
      with the reason, rather than marking the line:

          {SephiaCredo.Checks.PreloadInLoop,
           allow: [{MyApp.Accounts, :primary_user, "A company has one owner"}]}
      """,
      params: [
        include_tests: "Check test files and test support code too.",
        allow:
          "Functions whose loops are fine, as `{Module, :function, \"reason\"}` or " <>
            "`{Module, :function, arity, \"reason\"}`. The reason is required."
      ]
    ],
    param_defaults: [include_tests: false, allow: []]

  alias SephiaCredo.TestFile

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    :ok = SephiaCredo.Allow.validate!(params, __MODULE__)
    super(exec, source_files, params)
  end

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    with true <-
           Params.get(params, :include_tests, __MODULE__) or not TestFile.test_code?(source_file),
         {:ok, ast} <- Credo.Code.ast(source_file) do
      ast |> find_issues(issue_meta) |> SephiaCredo.Allow.reject(source_file, params, __MODULE__)
    else
      _skipped_or_unparsable -> []
    end
  end

  defp find_issues(ast, issue_meta) do
    ast
    |> SephiaCredo.Loop.per_element_regions()
    |> Enum.flat_map(&load_calls/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&issue(&1, issue_meta))
  end

  # Keyed by position, not line: two calls can share a line, and the same call
  # is collected once per enclosing loop.
  defp load_calls(region) do
    {_ast, found} =
      Macro.prewalk(region, [], fn
        {{:., _, [{:__aliases__, _, segments}, fun]}, meta, args} = node, acc
        when is_list(segments) and is_list(args) ->
          case trigger(segments, fun) do
            nil -> {node, acc}
            trigger -> {node, [{meta[:line], meta[:column], trigger} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp trigger(segments, :preload) do
    if List.last(segments) == :Repo, do: "Repo.preload"
  end

  defp trigger([:Ash], :load), do: "Ash.load"
  defp trigger(_segments, _fun), do: nil

  defp issue({line, _column, "Ash.load" = trigger}, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`Ash.load` inside a loop runs one query per element (N+1). " <>
          "Load the whole collection once: `Ash.load(list, :assoc)`.",
      trigger: trigger,
      line_no: line
    )
  end

  defp issue({line, _column, trigger}, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`Repo.preload` inside a loop runs one query per element (N+1). " <>
          "Preload the whole collection once: `Repo.preload(list, :assoc)`.",
      trigger: trigger,
      line_no: line
    )
  end
end
