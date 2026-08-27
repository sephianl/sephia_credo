defmodule SephiaCredo.Checks.MultiStepMutationWithoutTransaction do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    param_defaults: [
      ash_resources: [],
      excluded_functions: []
    ],
    explanations: [
      check: """
      Multiple database mutations in a single function without a
      transaction risk partial-failure corruption — if the second write
      fails, the first one is already committed.

      Wrap the sequence:

          Repo.transaction(fn ->
            Repo.insert(a)
            Repo.insert(b)
          end)

      Or, for Ash code:

          Ash.transaction([Resource], fn ->
            Ash.create(a)
            Ash.update(b)
          end)

      Or build it as an `Ecto.Multi`:

          Ecto.Multi.new()
          |> Ecto.Multi.insert(:a, a)
          |> Ecto.Multi.insert(:b, b)
          |> Repo.transaction()

      For Ash code-interface calls (`Stop.delete`, `Route.update`, ...)
      to be detected, list the resource modules in the `ash_resources`
      param.

      Use `excluded_functions` to opt out of specific intentionally
      non-transactional flows.
      """,
      params: [
        ash_resources:
          "Resource modules whose code-interface calls (`Stop.delete`, ...) count as mutations.",
        excluded_functions: "Names of functions whose flow is deliberately non-transactional."
      ]
    ]

  @repo_write_funs [
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_all,
    :update_all,
    :delete_all
  ]

  @ash_write_funs [
    :create,
    :create!,
    :update,
    :update!,
    :destroy,
    :destroy!,
    :bulk_create,
    :bulk_create!,
    :bulk_update,
    :bulk_update!,
    :bulk_destroy,
    :bulk_destroy!
  ]

  @resource_write_funs [
    :create,
    :create!,
    :update,
    :update!,
    :destroy,
    :destroy!,
    :delete,
    :delete!,
    :bulk_create,
    :bulk_create!,
    :bulk_update,
    :bulk_update!,
    :bulk_destroy,
    :bulk_destroy!
  ]

  alias Credo.Check.Params
  alias SephiaCredo.Ast
  alias SephiaCredo.TestFile

  @impl true
  def run(source_file, params \\ []) do
    if TestFile.test_file?(source_file) do
      []
    else
      analyze(source_file, params)
    end
  end

  defp analyze(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    excluded = Params.get(params, :excluded_functions, __MODULE__)
    ash_resources = normalize_resources(Params.get(params, :ash_resources, __MODULE__))

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, excluded, ash_resources)
      {:error, _} -> []
    end
  end

  defp normalize_resources(resources) do
    resources |> Enum.map(&normalize_resource/1) |> Enum.reject(&is_nil/1)
  end

  defp normalize_resource(mod) when is_atom(mod), do: mod |> Atom.to_string() |> last_segment()
  defp normalize_resource(mod) when is_binary(mod), do: last_segment(mod)
  defp normalize_resource(_mod), do: nil

  defp last_segment("Elixir." <> rest), do: last_segment(rest)
  defp last_segment(name), do: name |> String.split(".") |> List.last() |> String.to_atom()

  defp find_issues(ast, issue_meta, excluded, ash_resources) do
    # Unpiped first: `fn -> ... end |> Repo.transaction()` leaves the transaction's
    # own body in a sibling position, where the count cannot see it is wrapped.
    fns = ast |> Ast.unpipe() |> collect_functions()
    mutating = mutating_call_set(fns, ash_resources)

    Enum.flat_map(fns, fn f ->
      cond do
        f.name in excluded ->
          []

        count_mutations(f.body, ash_resources, mutating) < 2 ->
          []

        true ->
          [
            format_issue(
              issue_meta,
              message:
                "Function `#{f.name}/#{f.arity}` performs multiple database mutations " <>
                  "without `Repo.transaction/1`, `Ash.transaction/2`, or `Ecto.Multi` — " <>
                  "a mid-sequence failure leaves the database in a partial state.",
              trigger: "#{f.name}/#{f.arity}",
              line_no: f.line
            )
          ]
      end
    end)
  end

  defp collect_functions(ast) do
    {_, fns} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head, body_kw]} = node, acc when kind in [:def, :defp] ->
          case describe_function(head, body_kw, meta) do
            nil -> {node, acc}
            f -> {node, [f | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(fns)
  end

  # `full_body` rather than the `do` block: a `def ... after ... end` runs its
  # handler clauses too, and counting them is the same reading `count_mutations`
  # already gives the `try` they lower to.
  defp describe_function(head, body_kw, meta) do
    with name when is_atom(name) <- Ast.fun_name(head),
         arity when is_integer(arity) <- Ast.fun_arity(head),
         body when not is_nil(body) <- Ast.full_body(body_kw) do
      %{
        name: name,
        arity: arity,
        calls: Enum.map(Ast.fun_arities(head), &{name, &1}),
        line: meta[:line],
        body: discard_transacted_fns(body)
      }
    else
      _ -> nil
    end
  end

  # `fun = fn -> ... end; Repo.transaction(fun)` wraps the writes as surely as
  # writing them inline does, but they sit at the binding rather than under the
  # transaction. Blank the body there so they are counted where they run.
  defp discard_transacted_fns(body) do
    transacted = transacted_vars(body)

    Macro.prewalk(body, fn
      {:=, meta, [{name, _, ctx} = var, {:fn, _, _}]} = node
      when is_atom(name) and is_atom(ctx) ->
        if MapSet.member?(transacted, name), do: {:=, meta, [var, nil]}, else: node

      node ->
        node
    end)
  end

  defp transacted_vars(body) do
    {_, vars} =
      Macro.prewalk(body, MapSet.new(), fn node, acc ->
        if transaction_call?(node),
          do: {node, Enum.into(bare_var_args(node), acc)},
          else: {node, acc}
      end)

    vars
  end

  defp bare_var_args({_fun, _meta, args}) do
    for {name, _, ctx} <- args, is_atom(name), is_atom(ctx), do: name
  end

  # Keyed by name *and* arity: a `save/2` that writes says nothing about a
  # `save/1` clause that does not.
  defp mutating_call_set(fns, ash_resources) do
    initial =
      fns
      |> Enum.filter(&body_has_direct_mutation?(&1.body, ash_resources))
      |> Enum.flat_map(& &1.calls)
      |> MapSet.new()

    fixed_point(initial, fns)
  end

  defp fixed_point(set, fns) do
    next = Enum.reduce(fns, set, &maybe_add_caller(&1, &2))
    if MapSet.equal?(next, set), do: set, else: fixed_point(next, fns)
  end

  defp maybe_add_caller(f, acc) do
    cond do
      Enum.all?(f.calls, &MapSet.member?(acc, &1)) -> acc
      reaches_mutating?(f.body, acc) -> Enum.into(f.calls, acc)
      true -> acc
    end
  end

  defp reaches_mutating?(body, mutating_calls) do
    Enum.any?(local_calls(body), &MapSet.member?(mutating_calls, &1))
  end

  defp body_has_direct_mutation?(body, ash_resources) do
    {_, found} =
      Macro.prewalk(body, false, fn
        node, true -> {node, true}
        node, false -> {node, mutation?(node, ash_resources)}
      end)

    found
  end

  defp local_calls(body) do
    {_, calls} =
      Macro.prewalk(body, [], fn
        {name, _meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, [{name, length(args)} | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # Sequential code sums; mutually exclusive branches take the worst one. A
  # `case` that dispatches to a different single-mutation helper per branch runs
  # exactly one of them, so summing across the branches reports a function that
  # has nothing to roll back.
  defp count_mutations({:case, _, [subject, kw]}, resources, mutating) when is_list(kw),
    do: count_mutations(subject, resources, mutating) + max_clauses(kw[:do], resources, mutating)

  defp count_mutations({:cond, _, [kw]}, resources, mutating) when is_list(kw),
    do: max_clauses(kw[:do], resources, mutating)

  defp count_mutations({branch, _, [condition, kw]}, resources, mutating)
       when branch in [:if, :unless] and is_list(kw) do
    count_mutations(condition, resources, mutating) +
      max(
        count_mutations(kw[:do], resources, mutating),
        count_mutations(kw[:else], resources, mutating)
      )
  end

  defp count_mutations({:fn, _, clauses}, resources, mutating) when is_list(clauses),
    do: max_clauses(clauses, resources, mutating)

  defp count_mutations({:with, _, args}, resources, mutating) when is_list(args) do
    {kw, clauses} = split_trailing_kw(args)

    # The `<-` clauses run in order before either outcome, so they sum; the body
    # and the else branch are alternatives.
    sum(clauses, resources, mutating) +
      max(
        count_mutations(kw[:do], resources, mutating),
        max_clauses(kw[:else], resources, mutating)
      )
  end

  # A handler is an alternative to the body, not a continuation of it: `try do
  # work() rescue _ -> record_failure() end` is compensation, and wrapping the
  # two together would roll back the record of the failure.
  defp count_mutations({:try, _, [kw]}, resources, mutating) when is_list(kw) do
    handlers =
      [kw[:rescue], kw[:catch], kw[:else]]
      |> Enum.map(&max_clauses(&1, resources, mutating))
      |> Enum.max()

    max(count_mutations(kw[:do], resources, mutating), handlers) +
      count_mutations(kw[:after], resources, mutating)
  end

  defp count_mutations(node, resources, mutating) do
    cond do
      transaction_call?(node) -> 0
      mutation?(node, resources) or local_mutation_call?(node, mutating) -> 1
      true -> sum_children(node, resources, mutating)
    end
  end

  defp sum_children({_form, _meta, args}, resources, mutating) when is_list(args),
    do: sum(args, resources, mutating)

  defp sum_children({left, right}, resources, mutating),
    do: count_mutations(left, resources, mutating) + count_mutations(right, resources, mutating)

  defp sum_children(list, resources, mutating) when is_list(list),
    do: sum(list, resources, mutating)

  defp sum_children(_other, _resources, _mutating), do: 0

  defp sum(items, resources, mutating),
    do: Enum.reduce(items, 0, &(count_mutations(&1, resources, mutating) + &2))

  defp max_clauses(clauses, resources, mutating) when is_list(clauses) do
    clauses
    |> Enum.map(fn
      {:->, _, [_head, body]} -> count_mutations(body, resources, mutating)
      other -> count_mutations(other, resources, mutating)
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp max_clauses(other, resources, mutating), do: count_mutations(other, resources, mutating)

  defp split_trailing_kw(args) do
    case List.last(args) do
      kw when is_list(kw) -> {kw, Enum.drop(args, -1)}
      _other -> {[], args}
    end
  end

  defp local_mutation_call?({name, _meta, args}, mutating_calls)
       when is_atom(name) and is_list(args) do
    MapSet.member?(mutating_calls, {name, length(args)})
  end

  defp local_mutation_call?(_, _), do: false

  defp mutation?(node, ash_resources) do
    repo_write?(node) or ash_write?(node) or resource_write?(node, ash_resources)
  end

  defp repo_write?({{:., _, [{:__aliases__, _, segments}, fun]}, _, args})
       when is_list(args) and is_list(segments) do
    fun in @repo_write_funs and List.last(segments) == :Repo
  end

  defp repo_write?(_), do: false

  defp ash_write?({{:., _, [{:__aliases__, _, [:Ash]}, fun]}, _, args})
       when is_list(args) do
    fun in @ash_write_funs
  end

  defp ash_write?(_), do: false

  defp resource_write?(_node, []), do: false

  defp resource_write?(
         {{:., _, [{:__aliases__, _, segments}, fun]}, _, args},
         ash_resources
       )
       when is_list(args) and is_list(segments) do
    fun in @resource_write_funs and List.last(segments) in ash_resources
  end

  defp resource_write?(_node, _ash_resources), do: false

  defp transaction_call?({{:., _, [{:__aliases__, _, segments}, :transaction]}, _, args})
       when is_list(args) and is_list(segments) do
    case segments do
      [:Ash] -> true
      _ -> List.last(segments) == :Repo
    end
  end

  defp transaction_call?(_), do: false
end
