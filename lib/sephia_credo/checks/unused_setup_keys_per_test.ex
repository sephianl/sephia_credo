defmodule SephiaCredo.Checks.UnusedSetupKeysPerTest do
  @moduledoc """
  Stricter, per-test variant of `SephiaCredo.Checks.UnusedSetupKeysInTests`.

  Flags any test that does not consume one or more setup keys that
  are in scope for it. The fix is either to destructure the unused
  keys in the test, or to move them into a narrower `describe` block
  whose setup does not build them — avoiding wasted fixture
  construction for tests that don't need it.

  A test "consumes" an in-scope key if any of:

  - it destructures the key (`test "...", %{key: var}`),
  - it accesses the key via the context binding (`ctx.key`),
  - the enclosing describe-local `setup` destructures it from its
    own context match (the describe setup transformed the key, so
    the construction is not wasted).

  Setups returning `%{...}` or `{:ok, %{...}}` are both supported.
  Underscore-prefixed bindings (`%{foo: _foo}`) do not count as use.
  """

  use Credo.Check,
    base_priority: :low,
    category: :design

  @impl true
  def run(%Credo.SourceFile{filename: filename} = source_file, params \\ []) do
    if String.ends_with?(filename, "_test.exs") do
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
    module_body = extract_module_body(ast)
    {module_setup_keys, _} = extract_setup(module_body)
    module_setup_body = extract_setup_body(module_body)
    module_dep_graph = build_dependency_graph(module_setup_body, module_setup_keys)
    describes = collect_describe_blocks(ast)

    module_test_issues =
      module_body
      |> extract_tests()
      |> Enum.flat_map(&check_test(&1, module_setup_keys, [], module_dep_graph, issue_meta))

    describe_test_issues =
      Enum.flat_map(describes, fn body ->
        {describe_keys, _} = extract_setup(body)
        free_keys = extract_setup_destructures(body)
        in_scope = Enum.uniq(module_setup_keys ++ describe_keys)

        describe_setup_body = extract_setup_body(body)
        describe_dep_graph = build_dependency_graph(describe_setup_body, in_scope)

        merged_dep_graph =
          Map.merge(module_dep_graph, describe_dep_graph, fn _k, v1, v2 ->
            MapSet.union(v1, v2)
          end)

        body
        |> extract_tests()
        |> Enum.flat_map(&check_test(&1, in_scope, free_keys, merged_dep_graph, issue_meta))
      end)

    module_test_issues ++ describe_test_issues
  end

  defp check_test({_name, used_keys, line}, in_scope_keys, free_keys, dep_graph, issue_meta) do
    direct_consumed = Enum.uniq(used_keys ++ free_keys)
    consumed = expand_with_dependencies(direct_consumed, dep_graph)

    case in_scope_keys -- consumed do
      [] ->
        []

      missing ->
        missing_str = Enum.map_join(missing, ", ", &":#{&1}")

        [
          format_issue(
            issue_meta,
            message:
              "Test does not consume setup keys: #{missing_str}. " <>
                "Destructure them in the test, or move them into a narrower `describe`.",
            trigger: "test",
            line_no: line
          )
        ]
    end
  end

  # ===========================================================================
  # Dependency tracking — transitively consumed keys
  # ===========================================================================

  defp extract_setup_body(nil), do: nil

  defp extract_setup_body({:__block__, _, statements}),
    do: extract_setup_body_from_list(statements)

  defp extract_setup_body(statement), do: extract_setup_body_from_list(List.wrap(statement))

  defp extract_setup_body_from_list(statements) do
    Enum.find_value(statements, fn
      {:setup, _meta, [body]} -> unwrap_do(body)
      {:setup, _meta, [_context_match, body]} -> unwrap_do(body)
      _ -> nil
    end)
  end

  defp unwrap_do(do: body), do: body
  defp unwrap_do(body), do: body

  defp build_dependency_graph(nil, _return_keys), do: %{}

  defp build_dependency_graph(body, return_keys) do
    return_key_set = MapSet.new(return_keys)

    body
    |> unwrap_block()
    |> Enum.reduce(%{}, fn
      {:=, _, [pattern, rhs]}, acc ->
        merge_assignment_deps(pattern, rhs, return_key_set, acc)

      _, acc ->
        acc
    end)
  end

  defp merge_assignment_deps(pattern, rhs, return_key_set, acc) do
    pattern
    |> extract_assigned_vars()
    |> Enum.reduce(acc, fn var_name, inner_acc ->
      if MapSet.member?(return_key_set, var_name) do
        new_deps = collect_var_refs(rhs, return_key_set, var_name)
        Map.update(inner_acc, var_name, new_deps, &MapSet.union(&1, new_deps))
      else
        inner_acc
      end
    end)
  end

  defp unwrap_block({:__block__, _, statements}), do: statements
  defp unwrap_block(statement), do: List.wrap(statement)

  defp extract_assigned_vars(atom) when is_atom(atom), do: []

  defp extract_assigned_vars(node), do: extract_assigned_vars(node, [])

  defp extract_assigned_vars({name, _, ctx}, acc) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: acc, else: [name | acc]
  end

  defp extract_assigned_vars({:{}, _, elements}, acc),
    do: Enum.reduce(elements, acc, &extract_assigned_vars/2)

  defp extract_assigned_vars({left, right}, acc),
    do: extract_assigned_vars(right, extract_assigned_vars(left, acc))

  defp extract_assigned_vars(_, acc), do: acc

  defp collect_var_refs(ast, key_set, exclude_self) do
    {_, refs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {name, _, ctx} = node, acc when is_atom(name) and is_atom(ctx) ->
          if name != exclude_self and MapSet.member?(key_set, name) do
            {node, MapSet.put(acc, name)}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    refs
  end

  defp expand_with_dependencies(consumed_keys, dep_graph) when map_size(dep_graph) == 0,
    do: consumed_keys

  defp expand_with_dependencies(consumed_keys, dep_graph) do
    consumed_keys
    |> MapSet.new()
    |> do_expand(dep_graph)
    |> MapSet.to_list()
  end

  defp do_expand(consumed, dep_graph) do
    expanded =
      Enum.reduce(consumed, consumed, fn key, acc ->
        deps = Map.get(dep_graph, key, MapSet.new())
        MapSet.union(acc, deps)
      end)

    if MapSet.equal?(expanded, consumed), do: expanded, else: do_expand(expanded, dep_graph)
  end

  defp extract_module_body({:defmodule, _, [_, [do: body]]}), do: body

  defp extract_module_body({:__block__, _, statements}) do
    Enum.find_value(statements, fn
      {:defmodule, _, [_, [do: body]]} -> body
      _ -> nil
    end)
  end

  defp extract_module_body(_), do: nil

  defp collect_describe_blocks(ast) do
    {_ast, blocks} =
      Macro.prewalk(ast, [], fn
        {:describe, _meta, [_name, [do: body]]} = node, acc ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    blocks
  end

  defp extract_setup(nil), do: {[], 0}
  defp extract_setup({:__block__, _, statements}), do: extract_setup_from_list(statements)
  defp extract_setup(statement), do: extract_setup_from_list(List.wrap(statement))

  defp extract_setup_from_list(statements) do
    Enum.find_value(statements, {[], 0}, fn
      {:setup, meta, [body]} ->
        {find_return_keys(body), meta[:line] || 0}

      {:setup, meta, [_context_match, body]} ->
        {find_return_keys(body), meta[:line] || 0}

      _ ->
        nil
    end)
  end

  defp extract_setup_destructures(nil), do: []

  defp extract_setup_destructures({:__block__, _, statements}),
    do: extract_setup_destructures_from_list(statements)

  defp extract_setup_destructures(statement),
    do: extract_setup_destructures_from_list(List.wrap(statement))

  defp extract_setup_destructures_from_list(statements) do
    Enum.flat_map(statements, fn
      {:setup, _meta, [context_match, _body]} -> extract_match_keys(context_match)
      _ -> []
    end)
  end

  defp find_return_keys(do: body), do: find_return_keys(body)

  defp find_return_keys({:__block__, _, statements}) do
    statements
    |> List.last()
    |> extract_map_keys()
  end

  defp find_return_keys(single_expr), do: extract_map_keys(single_expr)

  defp extract_map_keys({:%{}, _, pairs}) do
    Enum.flat_map(pairs, fn
      {key, _value} when is_atom(key) -> [key]
      _ -> []
    end)
  end

  defp extract_map_keys({:ok, map}), do: extract_map_keys(map)
  defp extract_map_keys({:{}, _, [:ok, map]}), do: extract_map_keys(map)
  defp extract_map_keys(_), do: []

  defp extract_tests(nil), do: []
  defp extract_tests({:__block__, _, statements}), do: extract_tests_from_list(statements)
  defp extract_tests(statement), do: extract_tests_from_list(List.wrap(statement))

  defp extract_tests_from_list(statements) do
    Enum.flat_map(statements, fn
      {:test, meta, [name, context_match, [do: body]]} ->
        destructured = extract_match_keys(context_match)
        bindings = extract_context_bindings(context_match)
        via_context = extract_context_accesses(body, bindings)
        [{name, Enum.uniq(destructured ++ via_context), meta[:line] || 0}]

      {:test, meta, [name, [do: _body]]} ->
        [{name, [], meta[:line] || 0}]

      {:for, _, [_ | [[do: body]]]} ->
        extract_tests(body)

      _ ->
        []
    end)
  end

  defp extract_match_keys(node), do: extract_match_keys(node, [])

  defp extract_match_keys({:%{}, _, pairs}, acc) do
    Enum.reduce(pairs, acc, fn
      {key, {name, _, _}}, acc when is_atom(key) and is_atom(name) ->
        if String.starts_with?(Atom.to_string(name), "_"), do: acc, else: [key | acc]

      {key, _value}, acc when is_atom(key) ->
        [key | acc]

      _, acc ->
        acc
    end)
  end

  defp extract_match_keys({:=, _, [left, right]}, acc) do
    extract_match_keys(right, extract_match_keys(left, acc))
  end

  defp extract_match_keys(_, acc), do: acc

  defp extract_context_bindings(node), do: extract_context_bindings(node, [])

  defp extract_context_bindings({name, _meta, ctx}, acc) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: acc, else: [name | acc]
  end

  defp extract_context_bindings({:=, _, [left, right]}, acc) do
    extract_context_bindings(right, extract_context_bindings(left, acc))
  end

  defp extract_context_bindings(_, acc), do: acc

  defp extract_context_accesses(_body, []), do: []

  defp extract_context_accesses(body, bindings) do
    {_, keys} =
      Macro.prewalk(body, [], fn
        {{:., _, [{name, _, ctx}, key]}, _, _} = node, acc
        when is_atom(name) and is_atom(ctx) and is_atom(key) ->
          if name in bindings, do: {node, [key | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(keys)
  end
end
