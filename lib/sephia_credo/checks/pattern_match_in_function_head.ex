defmodule SephiaCredo.Checks.PatternMatchInFunctionHead do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      A single-clause function whose entire body is a `case` on one of its own
      parameters is multiple function clauses written the long way.

          defp handle(result) do
            case result do
              {:ok, value} -> value
              {:error, reason} -> log(reason)
            end
          end

      The clauses belong in the head, where the compiler checks them and the
      reader sees the shapes up front:

          defp handle({:ok, value}), do: value
          defp handle({:error, reason}), do: log(reason)

      Only the unambiguous shape is reported: one clause, no guard on the head,
      and the whole body is a `case` on a bare parameter. A `case` on anything
      computed, one that is part of a larger body, or one whose function also
      carries a `rescue`/`catch`/`else`/`after` clause, stays put.
      """
    ]

  alias SephiaCredo.Ast

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
    |> clauses()
    |> Enum.group_by(& &1.key)
    |> Enum.flat_map(&sole_dispatching_clause/1)
    |> Enum.sort_by(& &1.line)
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp sole_dispatching_clause({_key, [%{dispatches_on: nil}]}), do: []
  defp sole_dispatching_clause({_key, [clause]}), do: [clause]
  defp sole_dispatching_clause({_key, _clauses}), do: []

  defp clauses(ast) do
    {_ast, clauses} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head, body_kw]} = node, acc when kind in [:def, :defp] ->
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
        dispatches_on: dispatch_subject(head, body, body_kw)
      }
    else
      _ -> nil
    end
  end

  # Splitting the `case` into heads would leave a `rescue`, `catch`, `else` or
  # `after` clause with nowhere to go — one per head is not the same code.
  defp dispatch_subject(head, body, body_kw) do
    if not Ast.handlers?(body_kw), do: dispatch_subject(head, body)
  end

  defp dispatch_subject({:when, _meta, _guarded}, _body), do: nil

  defp dispatch_subject(head, {:case, _meta, [{subject, _, ctx}, [do: clauses]]})
       when is_atom(subject) and is_atom(ctx) and is_list(clauses) do
    if length(clauses) > 1 and subject in params(head), do: subject
  end

  defp dispatch_subject(_head, _body), do: nil

  defp params({_name, _meta, args}) when is_list(args), do: Enum.flat_map(args, &bare_name/1)
  defp params(_head), do: []

  defp bare_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp bare_name(_arg), do: []

  defp issue(clause, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{clause.name}` is a single clause whose whole body is a `case` on `#{clause.dispatches_on}`. " <>
          "Move the patterns into the function head, one clause each.",
      trigger: to_string(clause.name),
      line_no: clause.line
    )
  end
end
