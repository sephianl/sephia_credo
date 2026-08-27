defmodule SephiaCredo.Ast do
  @moduledoc "AST readings shared across checks: pipes, function heads, and bodies."

  @doc "Rewrites `x |> f(y)` to `f(x, y)` throughout `ast`."
  def unpipe(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, {fun, meta, args}]} when is_list(args) -> {fun, meta, [left | args]}
      node -> node
    end)
  end

  def fun_name({:when, _, [{name, _, _} | _]}) when is_atom(name), do: name
  def fun_name({name, _, _}) when is_atom(name), do: name
  def fun_name(_head), do: nil

  def fun_arity({:when, _, [head | _guards]}), do: fun_arity(head)
  def fun_arity({_name, _, args}) when is_list(args), do: length(args)
  def fun_arity({_name, _, nil}), do: 0
  def fun_arity(_head), do: nil

  @doc "Every arity a head can be called at — `def f(a, b \\\\ 1)` answers `1..2`."
  def fun_arities({:when, _, [head | _guards]}), do: fun_arities(head)

  def fun_arities({_name, _, args}) when is_list(args) do
    defaults = Enum.count(args, &match?({:\\, _, [_pattern, _default]}, &1))
    (length(args) - defaults)..length(args)//1
  end

  def fun_arities({_name, _, nil}), do: 0..0//1
  def fun_arities(_head), do: 0..-1//1

  def body_from(kw) when is_list(kw), do: Keyword.get(kw, :do)
  def body_from(_kw), do: nil

  @handler_keys [:rescue, :catch, :else, :after]

  @doc "Whether a body carries `rescue`, `catch`, `else` or `after` beside its `do`."
  def handlers?(kw) when is_list(kw), do: Enum.any?(@handler_keys, &Keyword.has_key?(kw, &1))
  def handlers?(_kw), do: false

  @doc """
  Everything a `def` body runs, handler clauses included.

  `def f do ... rescue ... end` is the `try` it lowers to, so a caller that
  already reads a `try` reads this one the same way. Without handlers this is
  just the `do` body.
  """
  def full_body(kw) do
    if handlers?(kw), do: {:try, [], [kw]}, else: body_from(kw)
  end

  @doc """
  The `{name, arity}` pairs whose definition is preceded by `@impl`.

  A callback's arity belongs to the behaviour, so a check that would have the
  author change it has nothing to offer here.
  """
  def impl_funs(ast) do
    {_ast, funs} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:__block__, _, statements} = node, acc when is_list(statements) ->
          {node, Enum.into(impl_pairs(statements), acc)}

        node, acc ->
          {node, acc}
      end)

    funs
  end

  # Other attributes between `@impl` and the definition — `@doc`, `@spec` — do
  # not break the pairing; anything else does.
  defp impl_pairs(statements) do
    {pairs, _pending?} =
      Enum.reduce(statements, {[], false}, fn
        {:@, _, [{:impl, _, [_value]}]}, {pairs, _pending?} ->
          {pairs, true}

        {:@, _, _attribute}, acc ->
          acc

        {kind, _, [head | _rest]}, {pairs, true} when kind in [:def, :defp] ->
          {impl_pair(head) ++ pairs, false}

        _statement, {pairs, _pending?} ->
          {pairs, false}
      end)

    pairs
  end

  defp impl_pair(head) do
    with name when is_atom(name) <- fun_name(head),
         arity when is_integer(arity) <- fun_arity(head) do
      [{name, arity}]
    else
      _ -> []
    end
  end
end
