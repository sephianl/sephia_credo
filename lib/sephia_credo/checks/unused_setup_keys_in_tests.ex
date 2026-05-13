defmodule SephiaCredo.Checks.UnusedSetupKeysInTests do
  @moduledoc """
  Flags any `setup` return key that is not destructured by some test in
  its scope.

  - A module-level `setup` is in scope for every test in the module
    (whether the test lives at module level or inside a `describe`).
  - A `describe`-local `setup` is in scope for the tests inside that
    describe only.

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
    {module_setup_keys, module_setup_line} = extract_setup(module_body)
    describes = collect_describe_blocks(ast)

    describe_setup_destructures =
      Enum.flat_map(describes, &extract_setup_destructures/1)

    all_used_keys =
      module_body
      |> extract_tests()
      |> Kernel.++(Enum.flat_map(describes, &extract_tests/1))
      |> Enum.flat_map(fn {_name, keys, _line} -> keys end)
      |> Kernel.++(describe_setup_destructures)
      |> Enum.uniq()

    module_issues =
      check_unused(module_setup_keys, all_used_keys, module_setup_line, issue_meta)

    describe_issues =
      Enum.flat_map(describes, fn body ->
        {keys, line} = extract_setup(body)

        used =
          body
          |> extract_tests()
          |> Enum.flat_map(fn {_name, k, _l} -> k end)
          |> Enum.uniq()

        check_unused(keys, used, line, issue_meta)
      end)

    module_issues ++ describe_issues
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

  defp check_unused([], _used, _line, _issue_meta), do: []

  defp check_unused(setup_keys, used_keys, setup_line, issue_meta) do
    case setup_keys -- used_keys do
      [] ->
        []

      unused ->
        unused_str = Enum.map_join(unused, ", ", &":#{&1}")

        [
          format_issue(
            issue_meta,
            message:
              "Setup returns keys never used by any test: #{unused_str}. " <>
                "Remove from the setup return map.",
            trigger: "setup",
            line_no: setup_line
          )
        ]
    end
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
