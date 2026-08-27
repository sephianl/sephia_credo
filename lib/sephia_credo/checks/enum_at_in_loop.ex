defmodule SephiaCredo.Checks.EnumAtInLoop do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      `Enum.at/2` is a linear walk — reaching index `i` costs `i` steps. Calling
      it once per element of another collection turns an O(n) traversal into
      O(n²).

      Build an index once, outside the loop:

          by_index = Map.new(Enum.with_index(rows), fn {row, i} -> {i, row} end)

      or, when the collections line up positionally, iterate them together with
      `Enum.zip/2` and drop the index.

      A non-negative integer-literal index (`Enum.at(list, 0)`) is bounded work
      and is not flagged. A negative one is not bounded — reaching `-1` means
      walking to the end — so it is flagged. Take the element once before the
      loop; `List.last/1` is the same O(n) walk and fixes nothing.
      """
    ]

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
    |> SephiaCredo.Loop.per_element_regions()
    |> Enum.flat_map(&enum_at_sites/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&issue(&1, issue_meta))
  end

  # Keyed by position, not line: two calls can share a line, and the same call
  # is collected once per enclosing loop.
  defp enum_at_sites(region) do
    {_ast, found} =
      Macro.prewalk(region, [], fn
        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, meta, [_enumerable, index | _default]} = node,
        acc ->
          case index_kind(index) do
            :bounded -> {node, acc}
            kind -> {node, [{meta[:line], meta[:column], kind} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp index_kind(index) when is_integer(index) and index >= 0, do: :bounded
  defp index_kind(index) when is_integer(index), do: :from_end
  defp index_kind({:-, _, [index]}) when is_integer(index), do: :from_end
  defp index_kind(_index), do: :computed

  defp issue({line, _column, :from_end}, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`Enum.at` with a negative index walks the whole enumerable to find the end, " <>
          "on every iteration (O(n²)). The enumerable does not change per iteration — " <>
          "take the element once, before the loop.",
      trigger: "Enum.at",
      line_no: line
    )
  end

  defp issue({line, _column, :computed}, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`Enum.at` inside a loop walks the enumerable on every iteration (O(n²)). " <>
          "Index the collection once into a map, or iterate both with `Enum.zip/2`.",
      trigger: "Enum.at",
      line_no: line
    )
  end
end
