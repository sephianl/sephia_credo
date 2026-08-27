defmodule SephiaCredo.Checks.AssertWithoutAssertion do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `assert x = expr` succeeds whatever `expr` is: a bare variable pattern
      always matches, so the assertion tests nothing.

          assert user = Accounts.fetch(id)

      If the bound variables are never read afterwards, the line is dead.
      Assert on them, or use `assert match?(pattern, expr)`. Test files only.
      """
    ]

  alias SephiaCredo.TestFile

  @scopes [:test, :setup, :setup_all]

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
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {scope, _meta, args} = node, acc when scope in @scopes and is_list(args) ->
          body = extract_body(args)
          new_issues = if body, do: scan_block(body, issue_meta), else: []
          {node, new_issues ++ acc}

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp extract_body(args) do
    Enum.find_value(args, fn
      kw when is_list(kw) -> Keyword.get(kw, :do)
      _ -> nil
    end)
  end

  defp scan_block(body, issue_meta) do
    statements = to_statements(body)
    do_scan(statements, [], issue_meta)
  end

  defp to_statements({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp to_statements(other), do: [other]

  defp do_scan([], issues, _issue_meta), do: issues

  defp do_scan([stmt | rest], issues, issue_meta) do
    case offending_assert(stmt, rest) do
      {:flag, meta} ->
        issue =
          format_issue(
            issue_meta,
            message:
              "`assert pattern = expr` binds variables that are never used; " <>
                "the match succeeds vacuously. " <>
                "Use `assert match?(pattern, expr)` or reference the bound variables.",
            trigger: "assert",
            line_no: meta[:line]
          )

        do_scan(rest, [issue | issues], issue_meta)

      :ok ->
        do_scan(rest, issues, issue_meta)
    end
  end

  defp offending_assert({:assert, meta, [{:=, _, [pattern, _expr]}]}, rest) do
    case bound_vars(pattern) do
      [] ->
        :ok

      vars ->
        if Enum.any?(vars, &referenced_in_any?(&1, rest)) do
          :ok
        else
          {:flag, meta}
        end
    end
  end

  defp offending_assert(_, _), do: :ok

  defp bound_vars(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, [], fn
        {:^, _, _}, acc ->
          {[], acc}

        {name, _meta, ctx} = node, acc
        when is_atom(name) and (is_nil(ctx) or ctx == Elixir) ->
          if reserved?(name) or underscore?(name) do
            {node, acc}
          else
            {node, [name | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    vars
    |> Enum.uniq()
  end

  defp reserved?(name) do
    name in [:%{}, :{}, :<<>>, :__aliases__, :__MODULE__, :__CALLER__, :__ENV__]
  end

  defp underscore?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  defp referenced_in_any?(name, statements) do
    Enum.any?(statements, &references?(&1, name))
  end

  defp references?(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        _node, true = acc ->
          {nil, acc}

        {^name, _meta, ctx} = node, _acc when is_nil(ctx) or ctx == Elixir ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
