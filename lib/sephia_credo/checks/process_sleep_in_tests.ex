defmodule SephiaCredo.Checks.ProcessSleepInTests do
  @moduledoc """
  Flag `Process.sleep/1` in test files.

  `Process.sleep` in tests causes flakes (timing-dependent passes/failures)
  and slows the suite. Prefer `assert_receive`, `assert_eventually`, or a
  polling helper.

  Only files whose path ends in `_test.exs` are checked.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :refactor

  @impl true
  def run(source_file, params \\ []) do
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      case Credo.Code.ast(source_file) do
        {:ok, ast} -> find_issues(ast, issue_meta)
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp test_file?(%Credo.SourceFile{filename: filename}) when is_binary(filename) do
    String.ends_with?(filename, "_test.exs")
  end

  defp test_file?(_), do: false

  defp find_issues(ast, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _args} = node, acc ->
          issue =
            format_issue(
              issue_meta,
              message:
                "`Process.sleep` in tests causes flakes and slows the suite. " <>
                  "Prefer `assert_receive`, `assert_eventually`, or a polling helper.",
              trigger: "Process.sleep",
              line_no: meta[:line]
            )

          {node, [issue | acc]}

        node, acc ->
          {node, acc}
      end)

    issues
  end
end
