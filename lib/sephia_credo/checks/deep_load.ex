defmodule SephiaCredo.Checks.DeepLoad do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    param_defaults: [max_relationships: 4],
    explanations: [
      check: """
      Ash loads every relationship in a load with a query of its own, after
      the main read. A load that names many relationships costs that many
      queries each time it runs, and a default load in a read action's
      `prepare build(load: ...)` is paid by every caller of that action,
      including the ones that use one field of it.

          read :by_id do
            prepare build(load: [products: [:batch, item: [default_uom_factor: [:uom]]],
                                 storage_unit: [:load_bearer]])
          end
          # 7 relationships: at least 7 queries after the main read

      The check counts relationships exactly, from the compiled resource, and
      only where it knows which resource is loaded: `prepare build(load: ...)`
      in a resource or one of its fragments, a code interface call with
      `load:`, `Ash.read/2`, `Ash.get/3` and friends on a named resource, and
      `Ash.Query.load/2` on a query built from one. Attributes, aggregates and
      expression calculations come back with the main query and are not
      counted. Module attributes holding the load are followed.

      Whether a relationship is needed depends on what the caller reads from
      it. Load only what this caller uses; where it needs one value of a
      relationship, such as a count, an existence check or a field of the
      first row, an aggregate or an expression calculation returns it in the
      main query.
      """,
      params: [
        max_relationships: "The most relationships a single load may name before it is reported."
      ]
    ]

  alias Ash.Resource.Info
  alias SephiaCredo.AshCall

  @compile {:no_warn_undefined, [Ash.Resource.Info]}

  @ash_reads [
    :read,
    :read!,
    :read_one,
    :read_one!,
    :read_first,
    :read_first!,
    :get,
    :get!,
    :stream!
  ]
  @query_builders [:new, :for_read, :filter, :sort, :limit, :offset, :select, :set_tenant, :load]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    max = Params.get(params, :max_relationships, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> AshCall.modules()
        |> Enum.flat_map(&module_loads/1)
        |> Enum.uniq()
        |> Enum.filter(fn {_line, _resource, paths} -> length(paths) > max end)
        |> Enum.sort()
        |> Enum.map(&issue(&1, max, issue_meta))

      {:error, _} ->
        []
    end
  end

  defp module_loads({segments, body, aliases}) do
    context = %{
      module: segments,
      aliases: aliases,
      attributes: attributes(body),
      own: AshCall.resource_of(segments, body)
    }

    {_ast, loads} =
      Macro.prewalk(body, [], fn
        {:defmodule, _, _}, acc ->
          {nil, acc}

        node, acc ->
          {node, node |> load_site(context) |> add_load(context, acc)}
      end)

    loads
  end

  defp load_site({:build, meta, [kw]}, %{own: resource}) when is_list(kw) and resource != nil,
    do: {meta[:line], resource, Keyword.get(kw, :load)}

  defp load_site({{:., meta, [mod, fun]}, _, args}, context) when is_list(args) do
    case AshCall.expand(mod, context.module, context.aliases) do
      [:Ash] when fun in @ash_reads ->
        {meta[:line], query_resource(List.first(args), context), keyword_load(args)}

      [:Ash, :Query] when fun == :load and length(args) == 2 ->
        {meta[:line], query_resource(List.first(args), context), List.last(args)}

      [_ | _] = segments ->
        {meta[:line], AshCall.interface_resource(Module.concat(segments), fun),
         keyword_load(args)}

      [] ->
        nil
    end
  end

  defp load_site(_node, _context), do: nil

  defp keyword_load(args) do
    case List.last(args) do
      [_ | _] = kw -> if Keyword.keyword?(kw), do: Keyword.get(kw, :load)
      _other -> nil
    end
  end

  defp query_resource({:__aliases__, _, _} = alias_node, context) do
    module = alias_node |> AshCall.expand(context.module, context.aliases) |> Module.concat()
    if AshCall.stored_resource?(module), do: module
  end

  defp query_resource({{:., _, [mod, fun]}, _, [inner | _]}, context)
       when fun in @query_builders do
    if AshCall.expand(mod, context.module, context.aliases) == [:Ash, :Query],
      do: query_resource(inner, context)
  end

  defp query_resource(_node, _context), do: nil

  defp add_load({line, resource, tree}, context, acc)
       when is_integer(line) and is_atom(resource) and resource != nil and tree != nil do
    if AshCall.stored_resource?(resource),
      do: [{line, resource, relationships(resource, tree, [], context.attributes)} | acc],
      else: acc
  end

  defp add_load(_site, _context, acc), do: acc

  # Module attributes are followed wherever they sit in the tree, and lists
  # joined with `++` are read as one list.
  defp resolve({:@, _, [{name, _, nil}]}, attributes) when is_atom(name),
    do: resolve(Map.get(attributes, name), attributes)

  defp resolve({:++, _, [left, right]}, attributes) do
    case {resolve(left, attributes), resolve(right, attributes)} do
      {left, right} when is_list(left) and is_list(right) -> left ++ right
      {left, _right} -> left
    end
  end

  defp resolve(tree, _attributes), do: tree

  defp relationships(resource, tree, path, attributes) do
    case resolve(tree, attributes) do
      list when is_list(list) ->
        Enum.flat_map(list, &relationships(resource, &1, path, attributes))

      node ->
        node_relationships(resource, node, path, attributes)
    end
  end

  defp node_relationships(resource, {key, sub}, path, attributes) when is_atom(key) do
    case queried_relationship(resource, key) do
      nil ->
        []

      relationship ->
        [path ++ [key] | relationships(relationship.destination, sub, path ++ [key], attributes)]
    end
  end

  defp node_relationships(resource, key, path, _attributes)
       when is_atom(key) and key not in [nil, true, false] do
    if queried_relationship(resource, key), do: [path ++ [key]], else: []
  end

  defp node_relationships(_resource, _tree, _path, _attributes), do: []

  # A manual relationship runs its own code, and one into a resource kept in
  # memory reads no table, so neither certainly costs a query.
  defp queried_relationship(resource, key) do
    case Info.relationship(resource, key) do
      %{manual: manual} when manual != nil ->
        nil

      %{destination: destination} = relationship ->
        if AshCall.stored_resource?(destination), do: relationship

      nil ->
        nil
    end
  end

  defp attributes(body) do
    {_ast, attributes} =
      Macro.prewalk(body, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc
        when is_atom(name) and (is_list(value) or elem(value, 0) == :++) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp issue({line, resource, paths}, max, issue_meta) do
    named = Enum.map_join(paths, ", ", &Enum.join(&1, "."))

    format_issue(issue_meta,
      message:
        "This load names #{length(paths)} relationships of `#{inspect(resource)}` (max #{max}): " <>
          "#{named}. Ash loads each with its own query, so it costs at least #{length(paths)} " <>
          "queries after the main read. Load only what the caller uses; for one value of a " <>
          "relationship, an aggregate or expression calculation returns it in the main query.",
      trigger: "load",
      line_no: line
    )
  end
end
