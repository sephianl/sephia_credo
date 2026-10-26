defmodule SephiaCredo.Checks.DeepLoad do
  use Credo.Check,
    base_priority: :low,
    category: :refactor,
    param_defaults: [max_nodes: 6],
    explanations: [
      check: """
      Ash loads each relationship in a load tree with its own query, so a
      wide or deep tree is a fan of round trips on every call that uses it:

          @si_load [products: [:batch, item: [default_uom_factor: [:uom]]], storage_unit: [:load_bearer]]
          # up to 7 queries per Ash.load

      A tree kept in a module attribute or a read action's
      `prepare build(load: ...)` is paid by every caller, including the ones
      that read one field of it.

      When the caller needs a value rather than the records, an aggregate
      (`first`, `count`, `exists`) or an expression calculation returns it in
      the parent's query. Otherwise load only what this caller reads.

      The check counts the nodes of literal trees passed as `load:`, to
      `Ash.load/3`, `Ash.Query.load/2` and `Ash.Changeset.load/2`, following
      module attributes in the same module. It cannot tell a relationship from
      an attribute or calculation, so it is informational.
      """,
      params: [max_nodes: "The most nodes a load tree may have before it is reported."]
    ]

  @load_calls [
    {[:Ash], :load},
    {[:Ash], :load!},
    {[:Ash, :Query], :load},
    {[:Ash, :Changeset], :load}
  ]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    max_nodes = Params.get(params, :max_nodes, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> SephiaCredo.Ast.unpipe()
        |> load_trees()
        |> Enum.filter(fn {_line, nodes} -> nodes > max_nodes end)
        |> Enum.uniq()
        |> Enum.map(&issue(&1, max_nodes, issue_meta))

      {:error, _} ->
        []
    end
  end

  defp load_trees(ast) do
    attributes = attributes(ast)

    {_ast, trees} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _, segments}, fun]}, _, [_subject, tree | _] = args} = node,
        acc ->
          acc =
            if {segments, fun} in @load_calls,
              do: add_tree(tree, meta[:line], attributes, acc),
              else: acc

          {node, keyword_trees(args, meta[:line], attributes, acc)}

        {_form, meta, args} = node, acc when is_list(meta) and is_list(args) ->
          {node, keyword_trees(args, meta[:line], attributes, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(trees)
  end

  defp keyword_trees(args, line, attributes, acc) do
    Enum.reduce(args, acc, fn
      [_ | _] = kw, inner ->
        if Keyword.keyword?(kw) and Keyword.has_key?(kw, :load),
          do: add_tree(Keyword.fetch!(kw, :load), line, attributes, inner),
          else: inner

      _arg, inner ->
        inner
    end)
  end

  defp add_tree({:@, meta, [{name, _, nil}]}, _line, attributes, acc) when is_atom(name) do
    case Map.fetch(attributes, name) do
      {:ok, tree} -> [{meta[:line], count(tree)} | acc]
      :error -> acc
    end
  end

  defp add_tree(tree, line, _attributes, acc) when is_list(tree) and is_integer(line),
    do: [{line, count(tree)} | acc]

  defp add_tree(_tree, _line, _attributes, acc), do: acc

  defp attributes(ast) do
    {_ast, attributes} =
      Macro.prewalk(ast, %{}, fn
        {:@, _, [{name, _, [value]}]} = node, acc when is_atom(name) and is_list(value) ->
          {node, Map.put(acc, name, value)}

        node, acc ->
          {node, acc}
      end)

    attributes
  end

  defp count(tree) when is_list(tree), do: tree |> Enum.map(&count/1) |> Enum.sum()
  defp count({key, sub}) when is_atom(key), do: 1 + count(sub)
  defp count(atom) when is_atom(atom), do: 1
  defp count(_other), do: 0

  defp issue({line, nodes}, max_nodes, issue_meta) do
    format_issue(issue_meta,
      message:
        "This load tree has #{nodes} nodes (max #{max_nodes}); each relationship in it is its own query. " <>
          "Load only what this caller reads, or return the value through an aggregate or expression calculation.",
      trigger: "load",
      line_no: line
    )
  end
end
