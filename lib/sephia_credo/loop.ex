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
            do: {node, Enum.filter(args, &lambda?/1) ++ acc},
            else: {node, acc}

        {:for, _, args} = node, acc when is_list(args) ->
          {node, for_regions(args) ++ acc}

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
            do: {node, Enum.filter(args, &lambda?/1) ++ acc},
            else: {node, acc}

        {:for, _, args} = node, acc when is_list(args) ->
          if Enum.all?(args, &fixed_generator?(&1, fixed_node?)),
            do: {node, acc},
            else: {node, for_regions(args) ++ acc}

        node, acc ->
          {node, acc}
      end)

    regions
  end

  @reorderings [:reverse, :sort, :uniq, :with_index, :to_list]

  defp fixed?(collection, _fixed_node?) when is_list(collection), do: true
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

  defp generator?({:<-, _, _}), do: true
  defp generator?(_node), do: false
end
