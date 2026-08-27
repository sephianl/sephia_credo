defmodule SephiaCredo.Checks.KeywordBagParameter do
  use Credo.Check,
    base_priority: :normal,
    category: :refactor,
    param_defaults: [
      min_keys: 3,
      ignored_keys: [:actor, :authorize?, :tenant, :domain, :context, :timeout, :tracer]
    ],
    explanations: [
      check: """
      A parameter the body only reaches into with `Keyword.get/fetch/take/...`
      is a parameter list wearing a disguise. It hides the real signature from
      the caller, from the compiler, and from pattern matching.

          def create_order(opts) do
            customer = Keyword.fetch!(opts, :customer)
            address = Keyword.fetch!(opts, :address)
            priority = Keyword.get(opts, :priority, :normal)
          end

      Name them:

          def create_order(customer, address, priority \\\\ :normal)

      Detection is by shape rather than by parameter name, so renaming `opts`
      to `options` changes nothing. A keyword list that is only forwarded —
      `def all(query, opts), do: Repo.all(query, opts)` — reads no keys and is
      never reported.

      `min_keys` sets how many distinct keys make a bag (default 3).
      `ignored_keys` lists keys that are conventionally forwarded rather than
      turned into parameters.

      A parameter the body also passes on whole is not reported — it still
      needs the list — and neither is a callback marked `@impl`, whose arity
      belongs to the behaviour rather than to you.
      """,
      params: [
        min_keys: "How many distinct keys read off one parameter make it a bag.",
        ignored_keys: "Keys that are conventionally forwarded rather than named as parameters."
      ]
    ]

  alias Credo.Check.Params
  alias SephiaCredo.Ast

  @readers [:get, :fetch, :fetch!, :get_lazy, :has_key?, :take, :get_values, :pop, :pop!]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    min_keys = Params.get(params, :min_keys, __MODULE__)
    ignored = MapSet.new(Params.get(params, :ignored_keys, __MODULE__))

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, min_keys, ignored)
      {:error, _} -> []
    end
  end

  defp find_issues(ast, issue_meta, min_keys, ignored) do
    impls = Ast.impl_funs(ast)

    {_ast, issues} =
      ast
      |> Ast.unpipe()
      |> Macro.prewalk([], fn
        {kind, meta, [head, body_kw]} = node, acc when kind in [:def, :defp] ->
          {node, bag_issues(head, body_kw, meta, issue_meta, min_keys, ignored, impls) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp bag_issues(head, body_kw, meta, issue_meta, min_keys, ignored, impls) do
    with name when is_atom(name) <- Ast.fun_name(head),
         arity when is_integer(arity) <- Ast.fun_arity(head),
         false <- MapSet.member?(impls, {name, arity}),
         body when not is_nil(body) <- Ast.full_body(body_kw) do
      for param <- bare_params(head),
          not used_whole?(body, param),
          keys = keys_read(body, param, ignored),
          length(keys) >= min_keys,
          do: issue(name, param, keys, meta[:line], issue_meta)
    else
      _ -> []
    end
  end

  # Naming the keys only removes the parameter if reading keys is all the body
  # does with it. A body that also passes the list on still needs the list, and
  # the signature the message spells out would not compile.
  defp used_whole?(
         {{:., _, [{:__aliases__, _, [:Keyword]}, fun]}, _, [{param, _, ctx} | rest]},
         param
       )
       when fun in @readers and is_atom(ctx),
       do: used_whole?(rest, param)

  defp used_whole?({param, _meta, ctx}, param) when is_atom(ctx), do: true

  defp used_whole?({form, _meta, args}, param),
    do: used_whole?(form, param) or (is_list(args) and used_whole?(args, param))

  defp used_whole?({left, right}, param),
    do: used_whole?(left, param) or used_whole?(right, param)

  defp used_whole?(list, param) when is_list(list),
    do: Enum.any?(list, &used_whole?(&1, param))

  defp used_whole?(_node, _param), do: false

  defp bare_params({:when, _, [head | _guards]}), do: bare_params(head)

  defp bare_params({_name, _meta, args}) when is_list(args),
    do: Enum.flat_map(args, &bare_name/1)

  defp bare_params(_head), do: []

  defp bare_name({:\\, _, [pattern, _default]}), do: bare_name(pattern)
  defp bare_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: [name]
  defp bare_name(_arg), do: []

  defp keys_read(body, param, ignored) do
    {_ast, keys} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Keyword]}, fun]}, _, [{^param, _, ctx} | rest]} = node, acc
        when fun in @readers and is_atom(ctx) ->
          {node, read_keys(rest) ++ acc}

        node, acc ->
          {node, acc}
      end)

    keys |> Enum.reject(&MapSet.member?(ignored, &1)) |> Enum.uniq() |> Enum.reverse()
  end

  defp read_keys([key | _rest]) when is_atom(key), do: [key]
  defp read_keys([keys | _rest]) when is_list(keys), do: Enum.filter(keys, &is_atom/1)
  defp read_keys(_args), do: []

  defp issue(name, param, keys, line, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{name}` reads #{Enum.map_join(keys, ", ", &inspect/1)} out of `#{param}`, " <>
          "so `#{param}` is a parameter list in disguise. Name them: " <>
          "`#{name}(#{Enum.join(keys, ", ")})`.",
      trigger: to_string(param),
      line_no: line
    )
  end
end
