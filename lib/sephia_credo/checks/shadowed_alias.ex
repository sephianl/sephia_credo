defmodule SephiaCredo.Checks.ShadowedAlias do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Two aliases in one scope that end in the same segment resolve to one
      name, and the last one wins:

          alias Zelo.Planner.Route.Delete
          alias Zelo.Planner.Stop.Delete

          Delete.delete_routes(routes, opts)   # calls Stop.Delete

      Elixir reports nothing. It is not a redefinition error, there is no
      warning, and both aliases count as used. The call compiles, dispatches to
      the wrong module, and fails at runtime — or worse, succeeds against the
      wrong data.

      Distinct full names guarantee nothing here, because an alias resolves to
      its final segment only. That makes this a standing hazard for any rename
      that moves a module under a new parent: `Route.Delete` and `Stop.Delete`
      are unambiguous in a directory listing and identical at the call site.
      Measured on one reorganisation of a 326-module namespace, two such pairs
      reached a green test run before anyone noticed — `RouteWorker.Supervisor`
      against `CompanyWorker.Supervisor` broke 10 tests, `Route.Delete` against
      `Stop.Delete` broke 4 — and nine more pairs were already latent in the
      tree, waiting for the first file that wanted both.

      Fix it at the alias, not the call site: give one of them `:as`.

          alias Zelo.Planner.Route.Delete, as: DeleteRoute
          alias Zelo.Planner.Stop.Delete, as: DeleteStop

      An explicit `:as` is never reported, even when it collides — that spelling
      is a deliberate choice a reader can see. Only the implicit final segment
      is.
      """
    ]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> ast |> scopes() |> Enum.flat_map(&issues_in(&1, issue_meta))
      {:error, _reason} -> []
    end
  end

  defp scopes({:defmodule, _meta, [_name, body]} = node) do
    [own_aliases(node) | Enum.flat_map(nested(body), &scopes/1)]
  end

  defp scopes({_form, _meta, args}) when is_list(args), do: Enum.flat_map(args, &scopes/1)
  defp scopes({left, right}), do: Enum.flat_map([left, right], &scopes/1)
  defp scopes(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &scopes/1)
  defp scopes(_node), do: []

  defp nested(body) do
    {_body, found} =
      Macro.prewalk(body, [], fn
        {:defmodule, _meta, _args} = node, acc -> {nil, [node | acc]}
        node, acc -> {node, acc}
      end)

    found
  end

  defp own_aliases({:defmodule, _meta, [_name, body]}) do
    body
    |> strip_nested()
    |> collect_aliases()
  end

  defp strip_nested(body) do
    Macro.prewalk(body, fn
      {:defmodule, _meta, _args} -> nil
      node -> node
    end)
  end

  defp collect_aliases(body) do
    {_body, aliases} = Macro.prewalk(body, [], &alias_node/2)
    aliases
  end

  defp alias_node({:alias, _meta, [_target, [as: _as]]} = node, acc), do: {node, acc}

  defp alias_node({:alias, meta, [{{:., _, [base, :{}]}, _, children}]} = node, acc) do
    {node, Enum.reduce(children, acc, &[entry(join(base, &1), meta) | &2])}
  end

  defp alias_node({:alias, meta, [{:__aliases__, _, segments}]} = node, acc)
       when is_list(segments) do
    {node, [entry(Enum.map(segments, &to_string/1), meta) | acc]}
  end

  defp alias_node(node, acc), do: {node, acc}

  defp join({:__aliases__, _, base}, {:__aliases__, _, child}) do
    Enum.map(base ++ child, &to_string/1)
  end

  defp join(_base, _child), do: []

  defp entry([], meta), do: {nil, nil, meta[:line]}
  defp entry(segments, meta), do: {List.last(segments), Enum.join(segments, "."), meta[:line]}

  defp issues_in(aliases, issue_meta) do
    aliases
    |> Enum.reject(fn {name, _full, _line} -> is_nil(name) end)
    |> Enum.group_by(fn {name, _full, _line} -> name end)
    |> Enum.filter(&shadowed?/1)
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp shadowed?({_name, entries}) do
    entries
    |> Enum.map(fn {_name, full, _line} -> full end)
    |> Enum.uniq()
    |> length() > 1
  end

  defp issue({name, entries}, issue_meta) do
    sorted = Enum.sort_by(entries, fn {_name, _full, line} -> line end)
    {_name, winner, last_line} = List.last(sorted)
    fulls = sorted |> Enum.map(fn {_name, full, _line} -> full end) |> Enum.uniq()

    format_issue(
      issue_meta,
      message:
        "`#{name}` is aliased to #{Enum.join(fulls, " and ")} in the same scope. " <>
          "Every `#{name}.` call in this module reaches #{winner}; the others are " <>
          "unreachable. Give one of them `:as`.",
      trigger: name,
      line_no: last_line
    )
  end
end
