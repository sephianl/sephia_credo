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

  # An alias reaches to the end of the innermost scope holding it, so a scope is
  # the unit a collision happens in — two aliases in sibling scopes never shadow.
  # `quote` counts because the alias it carries lands in the caller's scope
  # rather than this one, and `->` because each clause of a `case`, `fn`,
  # `receive` or `try` is a scope of its own.
  @scope_forms ~w(
    defmodule def defp defmacro defmacrop defimpl defprotocol
    quote fn -> if unless case cond with for try receive
  )a

  defp scopes(ast) do
    {own, nested} = partition(ast)

    [own | Enum.flat_map(nested, &scopes/1)]
  end

  # Splits one scope into the aliases written directly in it and the argument
  # lists of the scopes nested inside it, which `scopes/1` then recurses on.
  # Pruning at a boundary is what keeps a nested alias out of the outer scope.
  defp partition(ast) do
    {_ast, {aliases, nested}} = Macro.prewalk(ast, {[], []}, &partition_node/2)

    {aliases, nested}
  end

  defp partition_node({form, _meta, args}, {aliases, nested})
       when form in @scope_forms and is_list(args) do
    {nil, {aliases, [args | nested]}}
  end

  defp partition_node({:alias, meta, [target | opts]} = node, {aliases, nested}) do
    {node, {collect(target, opts, meta, aliases), nested}}
  end

  defp partition_node(node, acc), do: {node, acc}

  defp collect(target, opts, meta, aliases) do
    if explicit_as?(opts), do: aliases, else: entries(target, meta, aliases)
  end

  # Options other than `:as` — `warn: false` is the common one — say nothing
  # about the name the alias binds, so only `:as` suppresses the entry.
  defp explicit_as?([opts]) when is_list(opts),
    do: Keyword.keyword?(opts) and Keyword.has_key?(opts, :as)

  defp explicit_as?(_opts), do: false

  defp entries({{:., _, [base, :{}]}, _, children}, meta, aliases) do
    Enum.reduce(children, aliases, &[entry(join(base, &1), meta) | &2])
  end

  defp entries({:__aliases__, _, segments}, meta, aliases) when is_list(segments) do
    [entry(Enum.map(segments, &to_string/1), meta) | aliases]
  end

  defp entries(_target, _meta, aliases), do: aliases

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
