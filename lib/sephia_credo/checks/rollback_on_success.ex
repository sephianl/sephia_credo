defmodule SephiaCredo.Checks.RollbackOnSuccess do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      A transaction that rolls back when its work succeeds is a preview built
      by doing the work: every write, hook and notification runs, and is then
      thrown away. It costs as much as the real thing, and a page that shows
      the preview and then commits pays twice.

          Repo.transaction(fn ->
            case run(load_bearer, scans) do
              {:ok, stats} -> Repo.rollback({:planned, stats})
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

      Predict the outcome from what the writes would read: load that state
      once and compute the effects in memory, without writing. A rollback on
      the error path is fine; this flags a rollback on the `{:ok, _}` path or
      as the transaction's last expression.
      """
    ]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> ast |> SephiaCredo.Ast.unpipe() |> find_issues(issue_meta)
      {:error, _} -> []
    end
  end

  defp find_issues(ast, issue_meta) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_repo, fun]}, _, [{:fn, _, [{:->, _, [_args, body]}]} | _]} = node, acc
        when fun in [:transaction, :transact] ->
          {node, success_rollbacks(body) ++ acc}

        node, acc ->
          {node, acc}
      end)

    lines
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp success_rollbacks(body) do
    {_ast, lines} =
      Macro.prewalk(body, List.wrap(rollback_line(last(body))), fn
        {:->, _, [[pattern], clause_body]} = node, acc ->
          case success?(pattern) && rollback_line(last(clause_body)) do
            line when is_integer(line) -> {node, [line | acc]}
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    lines
  end

  defp last({:__block__, _, [_ | _] = statements}), do: List.last(statements)
  defp last(expression), do: expression

  defp rollback_line({{:., meta, [{:__aliases__, _, segments}, :rollback]}, _, [_value]}) do
    if List.last(segments) == :Repo, do: meta[:line]
  end

  defp rollback_line(_expression), do: nil

  defp success?({:when, _, [pattern | _guards]}), do: success?(pattern)
  defp success?(:ok), do: true
  defp success?({:ok, value}), do: not empty?(value)
  defp success?({:{}, _, [:ok, value | _]}), do: not empty?(value)
  defp success?(_pattern), do: false

  # `{:ok, nil} -> Repo.rollback(:not_found)` is the read that found nothing.
  defp empty?(value), do: value in [nil, false, []]

  defp issue(line, issue_meta) do
    format_issue(issue_meta,
      message:
        "This transaction rolls back when its work succeeds, so every write and hook runs only to be " <>
          "thrown away. Compute the preview from the state the writes would read instead.",
      trigger: "rollback",
      line_no: line
    )
  end
end
