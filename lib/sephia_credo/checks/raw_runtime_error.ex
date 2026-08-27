defmodule SephiaCredo.Checks.RawRuntimeError do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `raise "msg"` lowers to `raise RuntimeError, "msg"`. Error trackers
      group exceptions by module, so every distinct message becomes its own
      issue and the signal is lost in the noise.

      Define an exception with a descriptive name and raise that:

          defmodule ImportFailedError do
            defexception [:message]
          end

          raise ImportFailedError, "row 12 has no depot"
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
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:raise, meta, [first | _rest]} = node, acc ->
          if raw_runtime_error?(first) do
            issue =
              format_issue(
                issue_meta,
                message:
                  "Avoid raising `RuntimeError` — error trackers can't group instances meaningfully. " <>
                    "Define a `defexception` module with a descriptive name instead.",
                trigger: "raise",
                line_no: meta[:line]
              )

            {node, [issue | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp raw_runtime_error?(binary) when is_binary(binary), do: true
  defp raw_runtime_error?({:<<>>, _, _}), do: true
  defp raw_runtime_error?({:__aliases__, _, [:RuntimeError]}), do: true
  defp raw_runtime_error?(_), do: false
end
