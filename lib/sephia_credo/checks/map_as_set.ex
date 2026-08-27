defmodule SephiaCredo.Checks.MapAsSet do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      Testing membership against `Map.keys/1` allocates the full key list and
      scans it linearly. The map already answers the same question in constant
      time:

          Map.has_key?(map, key)

      If the collection is genuinely a set rather than a map you are indexing,
      reach for `MapSet` instead — `MapSet.member?/2` is also constant time.
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
    {_ast, lines} =
      ast
      |> SephiaCredo.Ast.unpipe()
      |> Macro.prewalk([], fn node, acc ->
        case membership_on_keys(node) do
          nil -> {node, acc}
          line -> {node, [line | acc]}
        end
      end)

    lines
    |> Enum.sort()
    |> Enum.map(&issue(&1, issue_meta))
  end

  # `Enum.member?(Map.keys(m), k)` — the pipe form parses to this too.
  defp membership_on_keys(
         {{:., _, [{:__aliases__, _, [:Enum]}, :member?]}, meta, [subject, _key]}
       ),
       do: if(map_keys?(subject), do: meta[:line])

  defp membership_on_keys({:in, meta, [_key, subject]}),
    do: if(map_keys?(subject), do: meta[:line])

  defp membership_on_keys(_node), do: nil

  defp map_keys?({{:., _, [{:__aliases__, _, [:Map]}, :keys]}, _, [_map]}), do: true
  defp map_keys?(_node), do: false

  defp issue(line, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "Membership against `Map.keys/1` allocates the key list and scans it (O(n)). " <>
          "Use `Map.has_key?(map, key)`, which is O(1).",
      trigger: "Map.keys",
      line_no: line
    )
  end
end
