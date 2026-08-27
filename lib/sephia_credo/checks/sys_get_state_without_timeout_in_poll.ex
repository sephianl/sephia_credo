defmodule SephiaCredo.Checks.SysGetStateWithoutTimeoutInPoll do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      poll_functions: [:wait_until]
    ],
    explanations: [
      check: """
      A polling helper that probes a GenServer with `:sys.get_state(pid)` uses
      the default 5-second timeout. A blocked GenServer makes it raise `:exit`,
      which `rescue` does not catch, so the test crashes instead of retrying.

      Pass a short timeout *and* catch the exit:

          try do
            :sys.get_state(pid, 100)
          catch
            :exit, _ -> false
          end

      `poll_functions` names the helpers whose anonymous-function arguments
      count as polling bodies.
      """,
      params: [
        poll_functions: "Names of helpers whose anonymous-function arguments are polling bodies."
      ]
    ]

  alias Credo.Check.Params

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    poll_funs = Params.get(params, :poll_functions, __MODULE__)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> walk(ast, false, issue_meta, poll_funs, [])
      {:error, _} -> []
    end
  end

  defp walk({:try, _, [opts]} = node, true, im, pf, acc) when is_list(opts) do
    if catches_exit?(Keyword.get(opts, :catch, [])) do
      walk(Keyword.delete(opts, :do), true, im, pf, acc)
    else
      walk_children(node, true, im, pf, acc)
    end
  end

  defp walk({{:., _, [:sys, :get_state]}, meta, [_pid]}, true, im, _pf, acc) do
    [build_issue(meta, im) | acc]
  end

  defp walk({name, _, args} = node, in_poller?, im, pf, acc)
       when is_atom(name) and is_list(args) do
    if name in pf do
      Enum.reduce(args, acc, &walk_poller_arg(&1, in_poller?, im, pf, &2))
    else
      walk_children(node, in_poller?, im, pf, acc)
    end
  end

  defp walk(node, in_poller?, im, pf, acc) do
    walk_children(node, in_poller?, im, pf, acc)
  end

  defp walk_poller_arg(arg, in_poller?, im, pf, acc) do
    walk(arg, fn?(arg) or in_poller?, im, pf, acc)
  end

  defp walk_children({_, _, children}, in_poller?, im, pf, acc) when is_list(children) do
    Enum.reduce(children, acc, &walk(&1, in_poller?, im, pf, &2))
  end

  defp walk_children({a, b}, in_poller?, im, pf, acc) do
    acc = walk(a, in_poller?, im, pf, acc)
    walk(b, in_poller?, im, pf, acc)
  end

  defp walk_children(list, in_poller?, im, pf, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk(&1, in_poller?, im, pf, &2))
  end

  defp walk_children(_, _, _, _, acc), do: acc

  defp fn?({:fn, _, _}), do: true
  defp fn?(_), do: false

  defp catches_exit?(catches) when is_list(catches) do
    Enum.any?(catches, fn
      {:->, _, [[:exit | _], _]} -> true
      _ -> false
    end)
  end

  defp catches_exit?(_), do: false

  defp build_issue(meta, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`:sys.get_state/1` in a polling fn can flake under load — the default 5s timeout " <>
          "exits the test process. Use `:sys.get_state(pid, 100)` and wrap in " <>
          "`try ... catch :exit, _ -> false`.",
      trigger: ":sys.get_state",
      line_no: meta[:line]
    )
  end
end
