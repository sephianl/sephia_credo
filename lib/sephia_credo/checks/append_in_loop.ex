defmodule SephiaCredo.Checks.AppendInLoop do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    explanations: [
      check: """
      The `++` operator copies the entire left-hand list. A one-off
      concatenation is O(n) — same as `Enum.reverse/1` — and perfectly fine.

      Inside a loop, however, the cost compounds:
      n iterations × O(n) copy = **O(n²)**.

      Use `[item | acc]` to prepend (O(1) per iteration) and call
      `Enum.reverse/1` once at the end when order matters.

      This check only flags `++` inside loops (reduce, fold, for/reduce,
      recursive functions). One-off concatenations are not flagged.
      """
    ]

  alias SephiaCredo.Ast

  @reduce_funs [:reduce, :reduce_while, :map_reduce, :scan, :flat_map_reduce]
  @list_folds [:foldl, :foldr]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        recursive_funs = find_recursive_functions(ast)

        {_ast, state} =
          Macro.traverse(
            ast,
            %{acc_stack: [], capture_depth: 0, issues: [], recursive_funs: recursive_funs},
            &pre(&1, &2, issue_meta),
            &post/2
          )

        state.issues

      {:error, _} ->
        []
    end
  end

  # `post` mirrors `pre` exactly in reverse, so the capture test sees the same
  # `acc_stack` on the way out as it did on the way in and the counters balance.
  defp pre(node, state, issue_meta) do
    state =
      case accumulators(node, state) do
        nil -> state
        names -> %{state | acc_stack: [names | state.acc_stack]}
      end

    state =
      if acc_capture?(node, state),
        do: %{state | capture_depth: state.capture_depth + 1},
        else: state

    {node, check_concat(node, state, issue_meta)}
  end

  defp post(node, state) do
    state =
      if acc_capture?(node, state),
        do: %{state | capture_depth: state.capture_depth - 1},
        else: state

    state =
      case accumulators(node, state) do
        nil -> state
        _names -> %{state | acc_stack: tl(state.acc_stack)}
      end

    {node, state}
  end

  # `&1` only stands for something that grows when the capture is handed to a
  # call that also gets the accumulator — `Map.update(acc, k, d, &(&1 ++ [x]))`
  # grows the list stored under `k`. A capture that never sees the accumulator,
  # such as `Enum.map(group, &(&1 ++ [:tag]))`, appends to a bounded element.
  defp acc_capture?({{:., _, _}, _, args}, state) when is_list(args),
    do: acc_capture_args?(args, state)

  defp acc_capture?({fun, _, args}, state) when is_atom(fun) and is_list(args),
    do: acc_capture_args?(args, state)

  defp acc_capture?(_node, _state), do: false

  defp acc_capture_args?(args, %{acc_stack: [_ | _] = stack}) do
    names = Enum.reduce(stack, MapSet.new(), &MapSet.union/2)

    Enum.any?(args, &capture?/1) and Enum.any?(args, &references?(&1, names))
  end

  defp acc_capture_args?(_args, _state), do: false

  defp capture?({:&, _, [body]}) when not is_integer(body), do: true
  defp capture?(_node), do: false

  defp check_concat({:++, _meta, [[item], _]}, state, _issue_meta)
       when not (is_tuple(item) and tuple_size(item) == 3 and elem(item, 0) == :|),
       do: state

  defp check_concat({:++, meta, [left, right]}, %{acc_stack: [_ | _] = stack} = state, issue_meta) do
    names = Enum.reduce(stack, MapSet.new(), &MapSet.union/2)

    if grows?(left, names, state.capture_depth) and
         not references?(right, referenced(left, names)),
       do: add_issue(state, meta, issue_meta),
       else: state
  end

  defp check_concat(_node, state, _issue_meta), do: state

  defp referenced(ast, names) do
    {_ast, found} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if MapSet.member?(names, name), do: {node, MapSet.put(acc, name)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp add_issue(state, meta, issue_meta) do
    issue =
      format_issue(
        issue_meta,
        message:
          "`++` inside a loop copies the left-hand list every iteration (O(n²)). " <>
            "Prepend with `[item | acc]` and `Enum.reverse/1` when order matters.",
        trigger: "++",
        line_no: meta[:line]
      )

    %{state | issues: [issue | state.issues]}
  end

  defp grows?({:&, _, [n]}, _acc_names, capture_depth) when is_integer(n), do: capture_depth > 0
  defp grows?(left, acc_names, _capture_depth), do: references?(left, acc_names)

  defp references?(ast, acc_names) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true ->
          {node, true}

        {name, _, ctx} = node, false when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.member?(acc_names, name)}

        node, false ->
          {node, false}
      end)

    found?
  end

  # Only a rebinding onto a bare variable carries the accumulator. A destructure
  # such as `{work, acc} = split(acc)` says nothing about which element grows, and
  # tainting every binding in it reports the bounded half.
  defp taint(names, body) do
    expanded =
      body
      |> rebindings()
      |> Enum.reduce(names, fn {name, value}, acc ->
        if references?(value, acc), do: MapSet.put(acc, name), else: acc
      end)

    if MapSet.equal?(expanded, names), do: names, else: taint(expanded, body)
  end

  defp rebindings(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:=, _, [{name, _, ctx}, value]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, [{name, value} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp accumulators({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args}, _state)
       when fun in @reduce_funs and is_list(args),
       do: args |> List.last() |> reducer_accumulators()

  defp accumulators({{:., _, [{:__aliases__, _, [:List]}, fun]}, _, args}, _state)
       when fun in @list_folds and is_list(args),
       do: args |> List.last() |> reducer_accumulators()

  defp accumulators({:for, _, args}, _state) when is_list(args) do
    if Enum.any?(args, fn
         kw when is_list(kw) -> Keyword.has_key?(kw, :reduce)
         _ -> false
       end),
       do: args |> List.last() |> for_accumulators()
  end

  defp accumulators({kind, meta, [{:when, _, [head | _]} | rest]}, state)
       when kind in [:def, :defp],
       do: accumulators({kind, meta, [head | rest]}, state)

  # No taint here, unlike a reducer: in a recursive function a local bound from a
  # parameter is usually a sub-result, not the accumulator, so tainting them
  # reports every divide-and-conquer join.
  defp accumulators({kind, _, [{name, _, args} | _rest]}, %{recursive_funs: rf})
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    if MapSet.member?(rf, {name, length(args)}), do: whole_params(args)
  end

  defp accumulators(_node, _state), do: nil

  defp reducer_accumulators({:fn, _, clauses}) do
    Enum.reduce(clauses, MapSet.new(), fn
      {:->, _, [params, body]}, acc when is_list(params) and params != [] ->
        params |> unguard() |> List.last() |> binding_names() |> taint(body) |> MapSet.union(acc)

      _clause, acc ->
        acc
    end)
  end

  defp reducer_accumulators(_other), do: MapSet.new()

  # `fn x, acc when is_list(x) ->` packs both parameters and the guard into one
  # `when` node. Without unwrapping it the guard reads as the accumulator, and
  # every variable it mentions is taken for a list that grows.
  defp unguard([{:when, _, args}]) when is_list(args) and length(args) > 1,
    do: Enum.drop(args, -1)

  defp unguard(params), do: params

  defp for_accumulators(kw) when is_list(kw) do
    if Keyword.keyword?(kw),
      do: kw |> Keyword.get(:do) |> for_accumulators(),
      else: reducer_accumulators({:fn, [], kw})
  end

  defp for_accumulators(_other), do: MapSet.new()

  # Only a whole parameter can be the accumulator. A variable bound inside a
  # parameter's pattern — `t` in `[{:label, t, _} | rest]` — is a piece of that
  # parameter, and a piece is bounded by the whole.
  defp whole_params(args), do: args |> Enum.flat_map(&whole_param/1) |> MapSet.new()

  defp whole_param({:\\, _, [pattern, _default]}), do: whole_param(pattern)
  defp whole_param({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp whole_param(_arg), do: []

  defp binding_names(pattern) do
    {_ast, names} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    names
  end

  defp find_recursive_functions(ast) do
    {_ast, funs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head, body_kw]} = node, acc when kind in [:def, :defp] ->
          name = Ast.fun_name(head)
          arity = Ast.fun_arity(head)
          body = Ast.full_body(body_kw)

          if name && arity && body && calls?(body, name, arity) do
            {node, MapSet.put(acc, {name, arity})}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    funs
  end

  defp calls?(ast, name, arity) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _, args} = node, _acc when is_list(args) and length(args) == arity -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end
end
