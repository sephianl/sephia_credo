defmodule SephiaCredo.Allow do
  @moduledoc """
  The `allow` parameter of the query cost checks: functions whose reports are
  decided, named in `.credo.exs` with the reason, instead of a
  `# credo:disable-for-next-line` comment in the code.

      {SephiaCredo.Checks.AshActionInLoop,
       allow: [
         {MyApp.Routes.UnassignDriver, :handle_routes,
          "A driver overlaps at most one route, so the loop runs once"}
       ]}

  An entry is `{Module, :function, "reason"}` or `{Module, :function, arity,
  "reason"}`, and exempts every report inside that function. The reason is
  required: the entry is where the next reader finds why the loop or the
  callback is fine, so one without a reason raises.
  """

  alias Credo.Check.Params

  @doc """
  The entries of a check's `allow` parameter as `{module_name, function,
  arity | nil}`, raising on an entry without a reason.
  """
  def entries(params, check) do
    params
    |> Params.get(:allow, check)
    |> List.wrap()
    |> Enum.map(&entry(&1, check))
  end

  defp entry({module, function, reason}, check), do: entry({module, function, nil, reason}, check)

  defp entry({module, function, arity, reason}, check)
       when is_atom(function) and (is_nil(arity) or is_integer(arity)) and is_binary(reason) do
    if String.trim(reason) == "" do
      invalid!({module, function, arity, reason}, check)
    else
      {module_name(module, check), function, arity}
    end
  end

  defp entry(entry, check), do: invalid!(entry, check)

  defp module_name(module, _check) when is_atom(module),
    do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp module_name(module, _check) when is_binary(module), do: module
  defp module_name(module, check), do: invalid!(module, check)

  defp invalid!(entry, check) do
    raise ArgumentError,
          "#{inspect(check)}: each `allow` entry is {Module, :function, \"reason\"} or " <>
            "{Module, :function, arity, \"reason\"}, with the reason the function's reports " <>
            "are fine; got #{inspect(entry)}"
  end

  @doc """
  The functions a source file defines, as `{module_name, name, arities, first_line,
  last_line}`, nested modules under their full name.
  """
  def functions(ast), do: collect(ast, nil, [])

  defp collect({:defmodule, _, [{:__aliases__, _, segments}, [{:do, body} | _]]}, module, acc)
       when is_list(segments),
       do: collect(body, nested(module, Enum.map_join(segments, ".", &Atom.to_string/1)), acc)

  defp collect({kind, meta, [head, _body]} = definition, module, acc)
       when kind in [:def, :defp] do
    case SephiaCredo.Ast.fun_name(head) do
      nil ->
        acc

      name ->
        [
          {module, name, SephiaCredo.Ast.fun_arities(head), meta[:line], last_line(definition)}
          | acc
        ]
    end
  end

  defp collect({_form, _meta, args}, prefix, acc) when is_list(args),
    do: Enum.reduce(args, acc, &collect(&1, prefix, &2))

  defp collect({left, right}, prefix, acc), do: collect(right, prefix, collect(left, prefix, acc))

  defp collect(nodes, prefix, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &collect(&1, prefix, &2))

  defp collect(_node, _prefix, acc), do: acc

  defp nested(nil, name), do: name
  defp nested(module, name), do: module <> "." <> name

  defp last_line(ast) do
    {_ast, line} =
      Macro.prewalk(ast, 0, fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          {node, Enum.max([acc, meta[:line] || 0, get_in(meta, [:end, :line]) || 0])}

        node, acc ->
          {node, acc}
      end)

    line
  end

  @doc """
  Whether the report on `line` sits inside a function an entry allows, given
  the file's `functions/1`.
  """
  def allowed?([], _functions, _line), do: false

  def allowed?(entries, functions, line) do
    Enum.any?(functions, fn {module, name, arities, first, last} ->
      line >= first and line <= last and
        Enum.any?(entries, fn {allowed_module, allowed_name, arity} ->
          allowed_module == module and allowed_name == name and
            (is_nil(arity) or arity in arities)
        end)
    end)
  end

  @doc """
  Raises on an entry without a reason. Run it before the per-file work starts,
  so the error stops the run with its message rather than inside a task.
  """
  def validate!(params, check) do
    _entries = entries(params, check)
    :ok
  end

  @doc "The issues of a file that no `allow` entry exempts."
  def reject(issues, %Credo.SourceFile{} = source_file, params, check) do
    case entries(params, check) do
      [] ->
        issues

      entries ->
        functions = source_file |> Credo.SourceFile.ast() |> functions()
        Enum.reject(issues, &allowed?(entries, functions, &1.line_no))
    end
  end
end
