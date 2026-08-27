defmodule SephiaCredo.Checks.ProcessSleepInTests do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      `Process.sleep` trades suite time for flakiness on slower machines —
      it passes until CI is loaded, then fails. Raising the duration is not a
      fix.

      Wait on the condition instead: `assert_receive`, `assert_eventually`, or
      a polling helper.

      A sleep inside a bounded retry helper — a function that calls itself with
      an argument decremented by a literal — is exempt. That sleep is the
      backoff between attempts. Test files only.
      """
    ]

  alias SephiaCredo.TestFile

  @impl true
  def run(source_file, params \\ []) do
    if TestFile.test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      case Credo.Code.ast(source_file) do
        {:ok, ast} -> find_issues(ast, issue_meta)
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp find_issues(ast, issue_meta) do
    exempt = retry_helper_sleeps(ast)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _args} = node, acc ->
          if meta[:line] in exempt,
            do: {node, acc},
            else: {node, [sleep_issue(issue_meta, meta[:line]) | acc]}

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp sleep_issue(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "`Process.sleep` in tests causes flakes and slows the suite. " <>
          "Prefer `assert_receive`, `assert_eventually`, or a polling helper.",
      trigger: "Process.sleep",
      line_no: line_no
    )
  end

  defp retry_helper_sleeps(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          if bounded_retry?(head, body), do: {node, sleep_lines(body) ++ acc}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    lines
  end

  defp bounded_retry?({:when, _, [head | _guards]}, body), do: bounded_retry?(head, body)

  defp bounded_retry?({name, _, params}, body) when is_atom(name) and is_list(params) do
    param_names = Enum.flat_map(params, &binding_name/1)

    {_ast, recurses?} =
      Macro.prewalk(body, false, fn
        node, true ->
          {node, true}

        {^name, _, args} = node, false when is_list(args) ->
          {node,
           length(args) == length(params) and Enum.any?(args, &decrements?(&1, param_names))}

        node, false ->
          {node, false}
      end)

    recurses?
  end

  defp bounded_retry?(_head, _body), do: false

  defp binding_name({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp binding_name({:\\, _, [pattern, _default]}), do: binding_name(pattern)
  defp binding_name(_), do: []

  defp decrements?({:-, _, [{name, _, ctx}, amount]}, param_names)
       when is_atom(name) and is_atom(ctx) and is_integer(amount),
       do: name in param_names

  defp decrements?(_arg, _param_names), do: false

  defp sleep_lines(body) do
    {_ast, lines} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, _args} = node, acc ->
          {node, [meta[:line] | acc]}

        node, acc ->
          {node, acc}
      end)

    lines
  end
end
