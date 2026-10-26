defmodule SephiaCredo.Checks.AshActionInLoop do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An Ash action, code interface or repo call inside `Enum.*`/`Stream.*`
      iteration, `Task.async_stream` or a `for` comprehension runs one query
      per element. So does a local function that makes such a call, called
      once per element.

          Enum.each(labels, &StorageItem.set_zone(&1, zone_id, opts))
          Enum.reduce_while(verdicts, {:ok, []}, fn verdict, {:ok, acc} ->
            case load_scan(verdict, opts) do ...  # load_scan/2 reads per verdict

      Each one looks harmless, but a hook that queries runs again for every
      element, so the round trips multiply. Do the work for the whole list at
      once:

          # reads: one query for all of them, then look each up in a map
          StorageItem.by_codes(codes, opts)

          # writes: one bulk action
          Ash.bulk_update(storage_items, :set_zone, %{zone_id: zone_id}, opts)

      Code interfaces are recognised from the compiled resource, so run Credo
      after `mix compile`; without it only `Ash.*` and `Repo.*` calls are seen.
      `Ash.load` and `Repo.preload` directly in a loop are left to
      `SephiaCredo.Checks.PreloadInLoop`.
      """
    ]

  alias SephiaCredo.AshCall

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
    |> AshCall.modules()
    |> Enum.flat_map(&module_calls/1)
    |> Enum.uniq_by(&{&1.line, &1.column})
    |> Enum.sort_by(&{&1.line, &1.column})
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp module_calls({module, body, aliases}) do
    costly = AshCall.costly_functions(body, module, aliases)
    defs = AshCall.definitions(body)

    body
    |> SephiaCredo.Loop.data_driven_regions()
    |> Enum.concat(helper_regions(body))
    |> Enum.flat_map(fn region ->
      direct =
        region |> AshCall.calls_in(module, aliases) |> Enum.reject(&(preload?(&1) or batch?(&1)))

      direct ++ through_locals(region, defs, costly)
    end)
    |> Enum.reject(&batch?/1)
  end

  # A lambda handed to a local function that calls it once per element, like
  # `reduce_ok(list, fn x -> ... end)` wrapping `Enum.reduce_while/3`, is a
  # per-element region at the call site.
  defp helper_regions(body) do
    helpers = iterating_helpers(body)

    {_ast, regions} =
      Macro.prewalk(body, [], fn
        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
          positions = Map.get(helpers, {name, length(args)}, [])

          lambdas =
            for {arg, index} <- Enum.with_index(args), index in positions, lambda?(arg), do: arg

          {node, lambdas ++ acc}

        node, acc ->
          {node, acc}
      end)

    regions
  end

  defp iterating_helpers(body) do
    {_ast, helpers} =
      body
      |> SephiaCredo.Ast.unpipe()
      |> Macro.prewalk(%{}, fn
        {kind, _, [head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          {node, add_helper(head, SephiaCredo.Ast.full_body(kw), acc)}

        node, acc ->
          {node, acc}
      end)

    helpers
  end

  defp add_helper({:when, _, [head | _]}, body, acc), do: add_helper(head, body, acc)

  defp add_helper({name, _, params}, body, acc) when is_atom(name) and is_list(params) do
    names =
      for {{var, _, ctx}, index} <- Enum.with_index(params),
          is_atom(var) and is_atom(ctx),
          into: %{},
          do: {var, index}

    case per_element_params(body, names) do
      [] ->
        acc

      positions ->
        Map.update(acc, {name, length(params)}, positions, &Enum.uniq(Enum.concat(&1, positions)))
    end
  end

  defp add_helper(_head, _body, acc), do: acc

  defp per_element_params(body, names) do
    body
    |> SephiaCredo.Loop.per_element_regions()
    |> Enum.flat_map(fn region ->
      {_ast, found} =
        Macro.prewalk(region, [], fn
          {{:., _, [{var, _, ctx}]}, _, _args} = node, acc when is_atom(var) and is_atom(ctx) ->
            {node, List.wrap(names[var]) ++ acc}

          node, acc ->
            {node, acc}
        end)

      found
    end)
    |> Enum.uniq()
  end

  defp lambda?({:fn, _, _}), do: true
  defp lambda?({:&, _, [_]}), do: true
  defp lambda?(_node), do: false

  # One bulk call per chunk or group is how a large write is meant to be split.
  defp batch?(%AshCall.Call{label: label}) do
    String.starts_with?(label, "Ash.bulk_") or
      Enum.any?(
        ["Repo.insert_all", "Repo.update_all", "Repo.delete_all"],
        &String.ends_with?(label, &1)
      )
  end

  defp through_locals(region, defs, costly) do
    region
    |> AshCall.local_calls(defs)
    |> Enum.flat_map(fn {key, meta} ->
      case costly[key] do
        nil ->
          []

        call ->
          [
            %{
              call
              | via: {key, call.line},
                line: meta[:line],
                column: meta[:column],
                label: call.label
            }
          ]
      end
    end)
  end

  defp preload?(%AshCall.Call{label: label}),
    do: label in ["Ash.load", "Ash.load!"] or String.ends_with?(label, "Repo.preload")

  defp issue(%AshCall.Call{via: nil} = call, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{call.label}` runs once per element of the enclosing loop (N+1). " <> advice(call.kind),
      trigger: call.label,
      line_no: call.line
    )
  end

  defp issue(%AshCall.Call{via: {{name, arity}, reached_line}} = call, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{name}/#{arity}` reaches `#{call.label}` (line #{reached_line}) and runs once per element " <>
          "of the enclosing loop (N+1). " <> advice(call.kind),
      trigger: Atom.to_string(name),
      line_no: call.line
    )
  end

  defp advice(:read),
    do: "Read the whole set in one query and look each element up in a map."

  defp advice(:write),
    do:
      "Write them in one call: `Ash.bulk_create/4`, `Ash.bulk_update/4` or `Ash.bulk_destroy/4`."

  defp advice(:calculation), do: "Load the calculation on the whole list with `Ash.load/3`."
  defp advice(:action), do: "Give the action a list argument and run it once."
end
