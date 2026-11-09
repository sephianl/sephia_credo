defmodule SephiaCredo.Loop do
  @moduledoc """
  Loop structure for the checks that care about per-iteration cost.

  Only the per-element part of a loop is expensive; the collection it iterates
  over is evaluated once, so a call there costs the same with or without a loop.
  """

  @batching [:group_by, :chunk_every, :chunk_by, :chunk_while]

  @doc """
  Every region of `ast` that runs once per element: the lambdas handed to an
  iterating call, and a comprehension's body and filters but not its generators.
  A comprehension whose body defines functions or tests (`def`, `test`,
  `describe`, …) runs at compile time, so it is not a loop; the bodies it
  defines are searched like any other code.

  Nested loops nest their regions, so callers that report per call site should
  deduplicate.
  """
  def per_element_regions(ast) do
    {_ast, regions} =
      ast
      |> SephiaCredo.Ast.unpipe()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, segments}, fun]}, _, args} = node, acc
        when is_list(segments) and is_list(args) ->
          if iterating?(segments, fun),
            do: {node, per_element_lambdas(segments, fun, args) ++ acc},
            else: {node, acc}

        {:for, _, args} = node, acc when is_list(args) ->
          if defines_code?(args),
            do: {node, acc},
            else: {node, for_regions(args) ++ acc}

        node, acc ->
          {node, acc}
      end)

    regions
  end

  @doc """
  The per-element regions of loops that run once per row. A loop over a fixed
  collection runs a fixed number of times however many rows there are: a list
  literal, a module attribute, a range between literals or attributes,
  `Map.values/1` or `Map.keys/1` of one of those, or whatever `fixed_node?`
  accepts, such as a call to a function that returns a constant. A loop over
  `Enum.group_by/2` or `Enum.chunk_every/2` runs once per group or chunk,
  which is how work is batched.
  """
  def data_driven_regions(ast, fixed_node? \\ fn _node -> false end) do
    {_ast, regions} =
      ast
      |> SephiaCredo.Ast.unpipe()
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, segments}, fun]}, _, [collection | _] = args} = node, acc
        when is_list(segments) ->
          if iterating?(segments, fun) and not fixed?(collection, fixed_node?),
            do: {node, per_element_lambdas(segments, fun, args) ++ acc},
            else: {node, acc}

        {:for, _, args} = node, acc when is_list(args) ->
          if defines_code?(args) or Enum.all?(args, &fixed_generator?(&1, fixed_node?)),
            do: {node, acc},
            else: {node, for_regions(args) ++ acc}

        node, acc ->
          {node, acc}
      end)

    regions
  end

  @reorderings [:reverse, :sort, :uniq, :with_index, :to_list]

  defp fixed?(collection, _fixed_node?) when is_list(collection),
    do: fixed_length_list?(collection)

  defp fixed?({:@, _, [{name, _, nil}]}, _fixed_node?) when is_atom(name), do: true

  defp fixed?({:.., _, [first, last]}, fixed_node?),
    do: bound?(first, fixed_node?) and bound?(last, fixed_node?)

  defp fixed?({:..//, _, [first, last, _step]}, fixed_node?),
    do: bound?(first, fixed_node?) and bound?(last, fixed_node?)

  defp fixed?({{:., _, [{:__aliases__, _, [module]}, fun]}, _, _args}, _fixed_node?)
       when module in [:Enum, :Stream] and fun in @batching,
       do: true

  defp fixed?({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [map]}, fixed_node?)
       when fun in [:values, :keys, :to_list],
       do: fixed?(map, fixed_node?)

  defp fixed?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, [collection | _]}, fixed_node?)
       when fun in @reorderings,
       do: fixed?(collection, fixed_node?)

  defp fixed?({:%{}, _, _pairs} = map, _fixed_node?), do: Macro.quoted_literal?(map)
  defp fixed?(collection, fixed_node?), do: fixed_node?.(collection)

  @doc """
  Whether a list node has a length the code fixes: a list literal, whatever its
  elements, but not `[head | tail]`, whose tail can be any length.
  """
  def fixed_length_list?(list) when is_list(list), do: not match?({:|, _, _}, List.last(list))
  def fixed_length_list?(_node), do: false

  defp bound?(value, _fixed_node?) when is_integer(value), do: true
  defp bound?({:@, _, [{name, _, nil}]}, _fixed_node?) when is_atom(name), do: true
  defp bound?({:-, _, [value]}, fixed_node?), do: bound?(value, fixed_node?)
  defp bound?(_value, _fixed_node?), do: false

  defp fixed_generator?({:<-, _, [_pattern, collection]}, fixed_node?),
    do: fixed?(collection, fixed_node?)

  defp fixed_generator?(_clause, _fixed_node?), do: true

  # A `Stream.*` lambda runs where the stream is consumed rather than where it is
  # written, but still once per element, which is all these checks count.
  defp iterating?([:Enum], _fun), do: true
  defp iterating?([:Stream], _fun), do: true
  defp iterating?([:Task], fun), do: fun == :async_stream
  defp iterating?(_segments, _fun), do: false

  # `Stream.resource/3` and `Stream.transform/4,5` run their start, last and
  # after functions once; only the function that produces elements runs per
  # element.
  defp per_element_lambdas([:Stream], :resource, [_start, next, _after]), do: lambdas([next])

  defp per_element_lambdas([:Stream], :transform, [_enum, _start, reducer, _after]),
    do: lambdas([reducer])

  defp per_element_lambdas([:Stream], :transform, [_enum, _start, reducer, _last, _after]),
    do: lambdas([reducer])

  defp per_element_lambdas(_segments, _fun, args), do: lambdas(args)

  defp lambdas(args), do: Enum.filter(args, &lambda?/1)

  defp lambda?({:fn, _, _}), do: true
  defp lambda?({:&, _, [_]}), do: true
  defp lambda?(_node), do: false

  defp for_regions(args) do
    {body, clauses} =
      case List.last(args) do
        kw when is_list(kw) ->
          {kw |> Keyword.take([:do]) |> Keyword.values(), Enum.drop(args, -1)}

        _other ->
          {[], args}
      end

    body ++ Enum.reject(clauses, &generator?/1)
  end

  @definitions [:def, :defp, :defmacro, :defmacrop, :test, :describe, :property]

  # `for role <- roles do test "rejects #{role}" do ... end end` defines one
  # test per role when the module compiles; each test runs its body once.
  defp defines_code?(args) do
    case List.last(args) do
      kw when is_list(kw) ->
        kw |> Keyword.get(:do) |> body_statements() |> Enum.any?(&definition?/1)

      _other ->
        false
    end
  end

  defp body_statements({:__block__, _, statements}), do: statements
  defp body_statements(statement), do: [statement]

  # A definition has a `do` body; `test(label)` is a call to a local function.
  defp definition?({name, _, [_ | _] = args}) when name in @definitions do
    case List.last(args) do
      [{:do, _} | _] -> true
      _other -> false
    end
  end

  defp definition?(_statement), do: false

  defp generator?({:<-, _, _}), do: true
  defp generator?(_node), do: false

  @doc """
  The positions (`{line, column}`) of the calls in a reducing lambda that carry
  the accumulator from one element to the next, out of `positions`, the calls
  the caller cares about.

  In `Enum.reduce/3`, `Enum.reduce_while/3`, `Enum.map_reduce/3` or
  `Stream.transform/3`, a call that takes the accumulator as an argument and
  whose result becomes the next accumulator cannot run before the previous
  element's call returned: the loop is sequential by necessity. So is a call in
  the returned value that takes that result, as `ended_at(result)` does in
  `{result, ended_at(result)}`. A call that does not take the accumulator, like
  `create(item)` in `fn item, {:ok, acc} -> ... end`, is independent per element
  however the accumulator is built from it.
  """
  def carried_calls({:fn, _, clauses}, positions) when is_list(clauses) do
    for {:->, _, [params, body]} <- clauses,
        [_element, acc_pattern] <- [strip_guard(params)],
        position <- carried_in_clause(pattern_vars(acc_pattern), body, positions),
        into: MapSet.new(),
        do: position
  end

  def carried_calls(_region, _positions), do: MapSet.new()

  defp strip_guard([{:when, _, args}]), do: Enum.drop(args, -1)
  defp strip_guard(params), do: params

  defp carried_in_clause(acc_vars, body, positions) do
    tails = tail_expressions(body)

    body
    |> call_nodes(positions)
    |> Enum.filter(&takes_any?(&1, acc_vars))
    |> Enum.flat_map(fn {position, _args} -> carried_from(position, body, tails, positions) end)
  end

  # The call and the calls in the returned value that take its result, when
  # its result reaches the returned value at all.
  defp carried_from(position, body, tails, positions) do
    derived = derived_vars(body, position)

    if Enum.any?(tails, &(contains_call?(&1, position) or mentions_any?(&1, derived))),
      do: [position | tail_calls_taking(tails, derived, positions)],
      else: []
  end

  defp call_nodes(ast, positions) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {_fun, meta, args} = node, acc when is_list(args) and is_list(meta) ->
          position = {meta[:line], meta[:column]}

          if MapSet.member?(positions, position),
            do: {node, [{position, args} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # The accumulator itself is an argument, not a field read off it.
  defp takes_any?({_position, args}, vars) do
    Enum.any?(args, fn
      {name, _, ctx} when is_atom(name) and is_atom(ctx) -> MapSet.member?(vars, name)
      _arg -> false
    end)
  end

  defp tail_calls_taking(tails, derived, positions) do
    for tail <- tails,
        {position, args} <- call_nodes(tail, positions),
        Enum.any?(args, &mentions_any?(&1, derived)),
        do: position
  end

  # The variables bound to the call's result, and to anything computed from
  # them, in the order the body binds them.
  defp derived_vars(body, position) do
    bindings = bindings(body)

    initial =
      for {pattern, value} <- bindings, contains_call?(value, position), reduce: MapSet.new() do
        acc -> MapSet.union(acc, pattern_vars(pattern))
      end

    Enum.reduce(bindings, initial, fn {pattern, value}, acc ->
      if mentions_any?(value, acc), do: MapSet.union(acc, pattern_vars(pattern)), else: acc
    end)
  end

  defp bindings(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {op, _, [pattern, value]} = node, acc when op in [:=, :<-] ->
          {node, [{pattern, value} | acc]}

        {:case, _, [value, [do: clauses]]} = node, acc when is_list(clauses) ->
          {node, for({:->, _, [[pattern], _]} <- clauses, do: {pattern, value}) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp tail_expressions({:__block__, _, [_ | _] = statements}),
    do: tail_expressions(List.last(statements))

  defp tail_expressions({:case, _, [_value, [do: clauses]]}) when is_list(clauses),
    do: Enum.flat_map(clauses, &clause_tails/1)

  defp tail_expressions({:cond, _, [[do: clauses]]}) when is_list(clauses),
    do: Enum.flat_map(clauses, &clause_tails/1)

  defp tail_expressions({kind, _, [_condition, kw]}) when kind in [:if, :unless] and is_list(kw),
    do: kw |> Keyword.values() |> Enum.flat_map(&tail_expressions/1)

  defp tail_expressions({:with, _, [_ | _] = args}) do
    case List.last(args) do
      kw when is_list(kw) -> Enum.flat_map(kw, &with_tails/1)
      _other -> []
    end
  end

  defp tail_expressions(expression), do: [expression]

  defp with_tails({:do, body}), do: tail_expressions(body)

  defp with_tails({:else, clauses}) when is_list(clauses),
    do: Enum.flat_map(clauses, &clause_tails/1)

  defp with_tails(_other), do: []

  defp clause_tails({:->, _, [_patterns, body]}), do: tail_expressions(body)
  defp clause_tails(_clause), do: []

  defp contains_call?(ast, position) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {_fun, meta, args} = node, false when is_list(args) and is_list(meta) ->
          {node, {meta[:line], meta[:column]} == position}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp mentions_any?(ast, vars) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {name, _, ctx} = node, false when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.member?(vars, name)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp pattern_vars(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, _}, acc ->
          {nil, acc}

        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if String.starts_with?(Atom.to_string(name), "_"),
            do: {node, acc},
            else: {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    vars
  end
end
