defmodule SephiaCredo.Checks.TrivialWrapperFunction do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      A private function whose whole body is one call to another module,
      passing its parameters straight through, adds a name and nothing else —
      and hides which module actually does the work.

          defp unpipe(ast), do: SephiaCredo.Ast.unpipe(ast)

      Call the target at the call site and delete the wrapper.

      A wrapper that earns its keep is not reported: supplying an argument,
      reordering or transforming them, matching a pattern, guarding, carrying
      a default, or adding a `rescue`/`catch`/`else`/`after` clause all count
      as doing something.

          defp fetch(id), do: Repo.get(Thing, id)
          defp save(x), do: Repo.insert(x, returning: true)

      Only single-clause `defp` is reported. A public delegation is what
      `defdelegate` is for.
      """
    ]

  alias SephiaCredo.Ast

  @not_a_bare_variable :__not_a_bare_variable__

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta)
      {:error, _} -> []
    end
  end

  defp find_issues(ast, issue_meta) do
    ast
    |> private_clauses()
    |> Enum.group_by(& &1.key)
    |> Enum.flat_map(&sole_delegating_clause/1)
    |> Enum.sort_by(& &1.line)
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp sole_delegating_clause({_key, [%{delegates_to: nil}]}), do: []
  defp sole_delegating_clause({_key, [clause]}), do: [clause]
  defp sole_delegating_clause({_key, _clauses}), do: []

  defp private_clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {:defp, meta, [head, body_kw]} = node, acc ->
          {node, List.wrap(describe_clause(head, body_kw, meta)) ++ acc}

        node, acc ->
          {node, acc}
      end)

    clauses
  end

  defp describe_clause(head, body_kw, meta) do
    with name when is_atom(name) <- Ast.fun_name(head),
         arity when is_integer(arity) <- Ast.fun_arity(head),
         body when not is_nil(body) <- Ast.body_from(body_kw) do
      %{
        name: name,
        key: {name, arity},
        line: meta[:line],
        delegates_to: delegation(head, body, body_kw)
      }
    else
      _ -> nil
    end
  end

  # A `rescue`, `catch`, `else` or `after` clause is the whole reason such a
  # wrapper exists — deleting it would delete the error handling with it.
  defp delegation(head, body, body_kw) do
    if not Ast.handlers?(body_kw), do: delegation(head, body)
  end

  defp delegation({:when, _meta, _guarded}, _body), do: nil

  defp delegation(head, {{:., _, [{:__aliases__, _, segments}, fun]}, _meta, args})
       when is_list(segments) and is_list(args) do
    params = params(head)

    if forwards_verbatim?(params, args),
      do: Enum.join(segments ++ [fun], ".")
  end

  defp delegation(_head, _body), do: nil

  defp forwards_verbatim?([], _args), do: false

  defp forwards_verbatim?(params, args) do
    @not_a_bare_variable not in params and Enum.map(args, &bare_name/1) == params
  end

  defp params({_name, _meta, args}) when is_list(args), do: Enum.map(args, &bare_name/1)
  defp params(_head), do: []

  defp bare_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp bare_name(_arg), do: @not_a_bare_variable

  defp issue(clause, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{clause.name}` only forwards its arguments to `#{clause.delegates_to}`. " <>
          "Call it directly and delete the wrapper.",
      trigger: to_string(clause.name),
      line_no: clause.line
    )
  end
end
