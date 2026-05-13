defmodule SephiaCredo.Checks.AshCodeInterfaceReadWithArgs do
  @moduledoc """
  Flag `define :name, action: :read, args: [...]` inside an Ash
  `code_interface do ... end` block.

  Ash's generic `:read` action declares no inputs. Calling a code interface
  defined with `args:` against `:read` raises `Ash.Error.Invalid.NoSuchInput`
  at runtime. The bug typically ships silently — LiveView callers wrap in
  `else {:error, _} -> ...` so the page just "doesn't do anything".

  Either define a custom read action that declares those args, or remove the
  `args:` option.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning

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
        {:code_interface, _meta, args} = node, acc when is_list(args) ->
          block = find_do_block(args)
          new_issues = if block, do: collect_offending_defines(block, issue_meta), else: []
          {node, new_issues ++ acc}

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp find_do_block(args) do
    Enum.find_value(args, fn
      kw when is_list(kw) -> Keyword.get(kw, :do)
      _ -> nil
    end)
  end

  defp collect_offending_defines(block, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(block, [], fn
        {:define, meta, [_name, opts]} = node, acc when is_list(opts) ->
          if offending_opts?(opts) do
            issue =
              format_issue(
                issue_meta,
                message:
                  "Ash's generic `:read` action declares no inputs; calling this code interface " <>
                    "with `args:` raises `Ash.Error.Invalid.NoSuchInput` at runtime. " <>
                    "Define a custom read action or remove `args:`.",
                trigger: "define",
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

  defp offending_opts?(opts) do
    Keyword.get(opts, :action) == :read and non_empty_list?(Keyword.get(opts, :args))
  end

  defp non_empty_list?(list) when is_list(list) and list != [], do: true
  defp non_empty_list?(_), do: false
end
