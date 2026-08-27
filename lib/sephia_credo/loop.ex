defmodule SephiaCredo.Loop do
  @moduledoc """
  Loop structure for the checks that care about per-iteration cost.

  Only the per-element part of a loop is expensive; the collection it iterates
  over is evaluated once, so a call there costs the same with or without a loop.
  """

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
