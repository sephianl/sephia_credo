defmodule SephiaCredo.TestContext do
  @moduledoc """
  Shared reading of a test module's AST for the `setup`-key checks: what a
  `setup` returns, and which of those keys each test consumes.

  A test consumes a key by destructuring it, by reading it off its context
  binding (`ctx.key`), or by handing that context to a helper defined in the
  same file that does either. Calls this module cannot resolve — remote or
  imported — make the test opaque, and an opaque test consumes every key in
  scope, since the alternative is a false positive on the whole fixture.
  """

  @special_forms [
    :.,
    :|,
    :=,
    :^,
    :&,
    :fn,
    :->,
    :when,
    :__block__,
    :__aliases__,
    :%{},
    :%,
    :{},
    :<<>>
  ]

  @doc "The body of the first `defmodule` in `ast`."
  def module_body({:defmodule, _, [_, [do: body]]}), do: body

  def module_body({:__block__, _, statements}) do
    Enum.find_value(statements, fn
      {:defmodule, _, [_, [do: body]]} -> body
      _ -> nil
    end)
  end

  def module_body(_), do: nil

  @doc "The bodies of every `describe` block in `ast`."
  def describe_blocks(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {:describe, _meta, [_name, [do: body]]} = node, acc -> {node, [body | acc]}
        node, acc -> {node, acc}
      end)

    blocks
  end

  @doc "The keys the first `setup` in `body` returns, and the line it sits on."
  def setup(nil), do: {[], 0}
  def setup({:__block__, _, statements}), do: setup_from_list(statements)
  def setup(statement), do: setup_from_list(List.wrap(statement))

  @doc "The context keys the `setup` in `body` destructures from its own argument."
  def setup_destructures(nil), do: []

  def setup_destructures({:__block__, _, statements}),
    do: setup_destructures_from_list(statements)

  def setup_destructures(statement), do: setup_destructures_from_list(List.wrap(statement))

  @doc """
  Every `def`/`defp` in `ast`, keyed by name and arity.

  Clauses of the same function are collected together, since the context may
  reach any of them.
  """
  def helpers(ast) do
    {_ast, helpers} =
      Macro.prewalk(ast, %{}, fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, put_helper(acc, head, body)}

        node, acc ->
          {node, acc}
      end)

    helpers
  end

  @doc """
  Every test in `body`, as `%{name:, keys:, line:, opaque?:}`.

  `keys` are the context keys the test consumes; `opaque?` marks a test that
  hands its context to something unresolvable, whose key use cannot be known.
  """
  def tests(body, helpers \\ %{})
  def tests(nil, _helpers), do: []
  def tests({:__block__, _, statements}, helpers), do: tests_from_list(statements, helpers)
  def tests(statement, helpers), do: tests_from_list(List.wrap(statement), helpers)

  @doc "The context keys a pattern destructures, ignoring underscored bindings."
  def match_keys(node), do: match_keys(node, [])

  defp put_helper(acc, {:when, _, [head | _guards]}, body), do: put_helper(acc, head, body)

  defp put_helper(acc, {name, _, params}, body) when is_atom(name) and is_list(params) do
    Map.update(
      acc,
      {name, length(params)},
      [{params, unwrap_do(body)}],
      &[{params, unwrap_do(body)} | &1]
    )
  end

  defp put_helper(acc, _head, _body), do: acc

  defp unwrap_do(do: body), do: body
  defp unwrap_do(body), do: body

  defp tests_from_list(statements, helpers) do
    Enum.flat_map(statements, fn
      {:test, meta, [name, context_match, [do: body]]} ->
        {via_context, opaque?} = context_uses(body, context_bindings(context_match), helpers)

        [
          %{
            name: name,
            keys: Enum.uniq(match_keys(context_match) ++ via_context),
            line: meta[:line] || 0,
            opaque?: opaque?
          }
        ]

      {:test, meta, [name, [do: _body]]} ->
        [%{name: name, keys: [], line: meta[:line] || 0, opaque?: false}]

      {:for, _, [_ | [[do: body]]]} ->
        tests(body, helpers)

      _ ->
        []
    end)
  end

  defp setup_from_list(statements) do
    Enum.find_value(statements, {[], 0}, fn
      {:setup, meta, [body]} -> {return_keys(body), meta[:line] || 0}
      {:setup, meta, [_context_match, body]} -> {return_keys(body), meta[:line] || 0}
      _ -> nil
    end)
  end

  defp setup_destructures_from_list(statements) do
    Enum.flat_map(statements, fn
      {:setup, _meta, [context_match, _body]} -> match_keys(context_match)
      _ -> []
    end)
  end

  defp return_keys(do: body), do: return_keys(body)

  defp return_keys({:__block__, _, statements}) do
    statements
    |> List.last()
    |> map_keys()
  end

  defp return_keys(single_expr), do: map_keys(single_expr)

  defp map_keys({:%{}, _, pairs}) do
    Enum.flat_map(pairs, fn
      {key, _value} when is_atom(key) -> [key]
      _ -> []
    end)
  end

  defp map_keys({:ok, map}), do: map_keys(map)
  defp map_keys({:{}, _, [:ok, map]}), do: map_keys(map)
  defp map_keys(_), do: []

  defp match_keys({:%{}, _, pairs}, acc) do
    Enum.reduce(pairs, acc, fn
      {key, {name, _, _}}, acc when is_atom(key) and is_atom(name) ->
        if underscored?(name), do: acc, else: [key | acc]

      {key, _value}, acc when is_atom(key) ->
        [key | acc]

      _, acc ->
        acc
    end)
  end

  defp match_keys({:=, _, [left, right]}, acc), do: match_keys(right, match_keys(left, acc))
  defp match_keys(_, acc), do: acc

  defp context_bindings(node), do: context_bindings(node, [])

  defp context_bindings({name, _meta, ctx}, acc) when is_atom(name) and is_atom(ctx) do
    if underscored?(name), do: acc, else: [name | acc]
  end

  defp context_bindings({:=, _, [left, right]}, acc),
    do: context_bindings(right, context_bindings(left, acc))

  defp context_bindings(_, acc), do: acc

  defp underscored?(name), do: String.starts_with?(Atom.to_string(name), "_")

  defp context_uses(body, bindings, helpers),
    do: context_uses(body, bindings, helpers, MapSet.new())

  defp context_uses(_body, [], _helpers, _visited), do: {[], false}

  defp context_uses(body, bindings, helpers, visited) do
    body = unpipe(body)

    body
    |> collect_uses(taint(body, MapSet.new(bindings)), helpers, visited)
    |> then(fn {keys, opaque?} -> {Enum.uniq(keys), opaque?} end)
  end

  defp unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, {fun, meta, args}]} when is_list(args) -> {fun, meta, [left | args]}
      node -> node
    end)
  end

  defp taint(body, tainted) do
    expanded =
      body
      |> assignments()
      |> Enum.reduce(tainted, fn {pattern, value}, acc ->
        if references?(value, acc),
          do: MapSet.union(acc, MapSet.new(context_bindings(pattern))),
          else: acc
      end)

    if MapSet.equal?(expanded, tainted), do: tainted, else: taint(body, expanded)
  end

  defp assignments(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:=, _, [pattern, value]} = node, acc -> {node, [{pattern, value} | acc]}
        node, acc -> {node, acc}
      end)

    found
  end

  defp references?(ast, tainted) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        node, false -> {node, tainted_var?(node, tainted)}
      end)

    found?
  end

  defp tainted_var?({name, _meta, ctx}, tainted) when is_atom(name) and is_atom(ctx),
    do: MapSet.member?(tainted, name)

  defp tainted_var?(_node, _tainted), do: false

  defp collect_uses(body, tainted, helpers, visited) do
    Macro.prewalk(body, {[], false}, fn node, acc ->
      {node, node_uses(node, tainted, helpers, visited, acc)}
    end)
    |> elem(1)
  end

  defp node_uses({{:., _, [var, key]}, _, []}, tainted, _helpers, _visited, {keys, opaque?})
       when is_atom(key) do
    if tainted_var?(var, tainted), do: {[key | keys], opaque?}, else: {keys, opaque?}
  end

  defp node_uses({:%{}, _, [{:|, _, [var, pairs]}]}, tainted, _helpers, _visited, {keys, opaque?}) do
    if tainted_var?(var, tainted),
      do: {prepend(match_keys({:%{}, [], pairs}), keys), opaque?},
      else: {keys, opaque?}
  end

  defp node_uses({fun, _, args}, tainted, helpers, visited, acc)
       when is_atom(fun) and is_list(args) do
    if fun in @special_forms or not Enum.any?(args, &tainted_var?(&1, tainted)),
      do: acc,
      else: call_uses(fun, args, tainted, helpers, visited, acc)
  end

  defp node_uses({{:., _, _}, _, args}, tainted, _helpers, _visited, {keys, opaque?})
       when is_list(args) do
    if Enum.any?(args, &tainted_var?(&1, tainted)), do: {keys, true}, else: {keys, opaque?}
  end

  defp node_uses(_node, _tainted, _helpers, _visited, acc), do: acc

  defp call_uses(fun, args, tainted, helpers, visited, {keys, _opaque?} = acc) do
    call = {fun, length(args)}

    cond do
      MapSet.member?(visited, call) ->
        acc

      not Map.has_key?(helpers, call) ->
        {keys, true}

      true ->
        helpers
        |> Map.fetch!(call)
        |> Enum.reduce(
          acc,
          &clause_uses(&1, args, tainted, helpers, MapSet.put(visited, call), &2)
        )
    end
  end

  defp clause_uses({params, body}, args, tainted, helpers, visited, acc) do
    params
    |> Enum.zip(args)
    |> Enum.filter(fn {_param, arg} -> tainted_var?(arg, tainted) end)
    |> Enum.reduce(acc, fn {param, _arg}, {keys, opaque?} ->
      {nested, nested_opaque?} = context_uses(body, context_bindings(param), helpers, visited)

      {prepend(nested, prepend(match_keys(param), keys)), opaque? or nested_opaque?}
    end)
  end

  defp prepend(items, acc), do: Enum.reduce(items, acc, &[&1 | &2])
end
