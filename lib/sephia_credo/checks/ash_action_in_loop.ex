defmodule SephiaCredo.Checks.AshActionInLoop do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      A call that reaches the database inside `Enum.*`/`Stream.*` iteration,
      `Task.async_stream` or a `for` comprehension runs once per element. So
      does a local function that makes such a call, called once per element.

          Enum.each(labels, &StorageItem.set_zone(&1, zone_id, opts))
          Enum.reduce_while(verdicts, {:ok, []}, fn verdict, {:ok, acc} ->
            case load_scan(verdict, opts) do ...  # load_scan/2 reads per verdict

      Each action's own hooks and validations run again for every element,
      so the round trips multiply. Do the work for the whole list at once:

          # reads: one query for all of them, then look each up in a map
          StorageItem.by_codes(codes, opts)

          # the same input for every record
          Ash.bulk_update(storage_items, :set_zone, %{zone_id: zone_id}, opts)

          # each record its own input, one MERGE when the changes are atomic
          Ash.update_many(Enum.map(items, &{&1, %{position: &1.position}}), Item, :move, opts)

      A call counts when it certainly reaches the database: the `Ash` read and
      write API, an Ecto repo, `Oban.insert/2`, a code interface of a
      create, read, update or destroy action on a resource with a database
      data layer, and a function the compiled module shows calling
      `Oban.insert/2`. Generic actions and calculation interfaces may never
      query, so they are not counted. A loop over a list literal, a module
      attribute, `Enum.group_by/2` or `Enum.chunk_every/2`, and one bulk call
      per chunk, are not reported. Run Credo after `mix compile`. `Ash.load`
      and `Repo.preload` directly in a loop are left to
      `SephiaCredo.Checks.PreloadInLoop`.

      What the check cannot see:

        * a collection that holds at most one element for a reason outside
          the code, such as a unique index or `top: 1` on an external API.
          Saying so in the code (match `[row]`, or update by query) helps the
          next reader as much as the check;
        * a loop that is sequential on purpose: each step reads what the
          previous one wrote, or locks are taken one by one in a fixed order.

      Mark those with the reason, so the next reader knows it was decided:

          # credo:disable-for-next-line SephiaCredo.Checks.AshActionInLoop
          # Each route departs when the previous one ends.
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
    |> innermost_only()
    |> Enum.sort_by(&{&1.line, &1.column})
    |> Enum.map(&issue(&1, issue_meta))
  end

  # A helper that loops over its own collection is reported at its own loop;
  # an outer loop calling the helper reports the same call a second time.
  defp innermost_only(calls) do
    direct = MapSet.new(for %{via: nil, line: line} <- calls, do: line)

    Enum.reject(calls, fn
      %{via: {_key, reached}} -> MapSet.member?(direct, reached)
      _direct -> false
    end)
  end

  defp module_calls({module, body, aliases}) do
    index = AshCall.reach_index(body, module, aliases)
    defs = AshCall.definitions(body)

    body
    |> statements()
    |> Enum.flat_map(fn statement ->
      SephiaCredo.Loop.data_driven_regions(statement, fixed_node_fun(module, statement, aliases))
    end)
    |> Enum.concat(helper_regions(body))
    |> Enum.flat_map(fn region ->
      direct = region |> AshCall.calls_in(module, aliases) |> Enum.reject(&preload?/1)
      direct ++ through_locals(region, defs, index)
    end)
    |> Enum.reject(&(&1.batched? or &1.element_query?))
  end

  defp statements({:__block__, _, statements}), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  # A collection is fixed when it is a variable its function only ever binds to
  # a list literal or module attribute, or a call to a zero-arity function the
  # compiled module shows returning a list literal, such as `Webhook.entity_sets()`.
  defp fixed_node_fun(module, statement, aliases) do
    fixed_vars = fixed_variables(statement)

    fn
      {var, _, context} when is_atom(var) and is_atom(context) ->
        MapSet.member?(fixed_vars, var)

      {name, _, []} when is_atom(name) ->
        AshCall.constant_list?(Module.concat(module), name)

      {{:., _, [mod, fun]}, _, []} ->
        case AshCall.expand(mod, module, aliases) do
          [] -> false
          segments -> AshCall.constant_list?(Module.concat(segments), fun)
        end

      _node ->
        false
    end
  end

  # A parameter, or a variable also bound by a pattern or to anything else, can
  # hold a collection of any length where the loop reads it.
  defp fixed_variables({kind, _, [head, _kw]} = definition) when kind in [:def, :defp] do
    {_ast, {fixed, unfixed}} =
      Macro.prewalk(definition, {MapSet.new(), pattern_vars(head)}, fn
        {:=, _, [{var, _, context}, value]} = node, {fixed, unfixed}
        when is_atom(var) and is_atom(context) ->
          if fixed_value?(value),
            do: {node, {MapSet.put(fixed, var), unfixed}},
            else: {node, {fixed, MapSet.put(unfixed, var)}}

        {op, _, [pattern, _value]} = node, {fixed, unfixed} when op in [:=, :<-, :->] ->
          {node, {fixed, MapSet.union(unfixed, pattern_vars(pattern))}}

        node, acc ->
          {node, acc}
      end)

    MapSet.difference(fixed, unfixed)
  end

  defp fixed_variables(_statement), do: MapSet.new()

  defp pattern_vars(pattern) do
    {_ast, vars} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {:^, _, _}, acc ->
          {nil, acc}

        {var, _, context} = node, acc when is_atom(var) and is_atom(context) ->
          {node, MapSet.put(acc, var)}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  defp fixed_value?(value) when is_list(value), do: SephiaCredo.Loop.fixed_length_list?(value)
  defp fixed_value?({:@, _, [{name, _, nil}]}) when is_atom(name), do: true
  defp fixed_value?(_value), do: false

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

  defp through_locals(region, defs, index) do
    region
    |> AshCall.local_calls(defs)
    |> Enum.flat_map(fn {key, meta, args} ->
      case AshCall.local_call_cost(index, key, args) do
        nil -> []
        call -> [%{call | via: {key, call.line}, line: meta[:line], column: meta[:column]}]
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
    do:
      "Read them in one query that filters on the whole list (`id in ^ids`), " <>
        "then look each element up with `Map.new/2`; `Ash.load/3` takes a list too."

  defp advice(:create), do: "Create them in one call with `Ash.bulk_create/4`."

  defp advice(:update),
    do:
      "Update them in one call: `Ash.bulk_update/4` when every record gets the same input, " <>
        "`Ash.update_many/4` when each gets its own."

  defp advice(:destroy), do: "Destroy them in one call with `Ash.bulk_destroy/4`."
  defp advice(:job), do: "Insert the jobs in one call with `Oban.insert_all/2`."

  defp advice(:unique_job),
    do:
      "The worker sets `unique`, which `Oban.insert_all/2` does not check on Oban's Basic " <>
        "engine, so drop duplicate args before inserting them in one call, or keep one insert per job."

  defp advice(:sql),
    do:
      "Send every element in one statement, passing the values as an array " <>
        "(`= ANY($1)` or `unnest($1)`)."
end
