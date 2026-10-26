defmodule SephiaCredo.Checks.QueryWithoutBatchCallback do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      An Ash validation whose `validate/3` queries, or a change whose
      `change/3` queries (directly or in a hook it adds), runs that query once
      per record in every bulk action unless the module also defines the batch
      callback. Ash calls `validate/3` and `change/3` per changeset when
      `batch_validate/3` or `batch_change/3` is missing.

          def validate(changeset, _opts, context) do
            {:ok, unit} = StorageUnit.get_by_id(changeset.data.storage_unit_id, ...)

      Define the batch callback and read for the whole batch at once:

          def batch_validate(changesets, _opts, context) do
            units = changesets |> Enum.map(& &1.data.storage_unit_id) |> StorageUnit.by_ids(...)
            Enum.map(changesets, &check(&1, units))
          end

      For a change, `batch_change/3` replaces `change/3` in bulk actions, and
      `before_batch/3` and `after_batch/3` replace its `before_action` and
      `after_action` hooks. A hook that tells another resource what happened
      can instead emit an `:after_action` signal (`Ash.Signals`), declared on
      the action with `emit MySignals, :name, fields: [...]`, or emitted with
      `Ash.Signals.emit_many/5` from `after_batch/3` when it carries data that
      is not an attribute. A bulk action emits `:after_action` signals once per
      batch (`:after_transaction` ones once per record), and a create, update
      or destroy listener handles them as one bulk action; a generic action
      listener needs `batch?: true` to receive them together.

      An `Ash.Notifier`'s `notify/1` runs once per notification, so once per
      record of a bulk action. What it reads belongs in `load/2`, which Ash
      loads for the whole batch before calling `notify/1`.

      `atomic/3` only helps an update that runs atomically as a whole; creates
      and non-atomic updates still go through `validate/3` and `change/3`.
      A call counts when it certainly reaches the database, as in
      `SephiaCredo.Checks.AshActionInLoop`. Run Credo after `mix compile`.
      """
    ]

  alias SephiaCredo.AshCall

  @callbacks [
    {[:Ash, :Resource, :Validation], {:validate, 3}, {:batch_validate, 3}},
    {[:Ash, :Resource, :Change], {:change, 3}, {:batch_change, 3}}
  ]

  @signal_advice "When the work tells another resource what happened, emit an `:after_action` " <>
                   "signal instead (`emit MySignals, :name, fields: [...]` on the action, or " <>
                   "`Ash.Signals.emit_many/5` from `after_batch/3` for data that is not an attribute): " <>
                   "a bulk action emits it once per batch, and a create, update or destroy listener, " <>
                   "or a generic one with `batch?: true`, handles the batch in one call."

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> ast |> AshCall.modules() |> Enum.flat_map(&module_issues(&1, issue_meta))
      {:error, _} -> []
    end
  end

  defp module_issues({module, body, aliases}, issue_meta) do
    defs = AshCall.definitions(body)

    for {behaviour, callback, batch} <- @callbacks,
        AshCall.uses?(body, behaviour),
        Map.has_key?(defs, callback),
        not Map.has_key?(defs, batch),
        call = AshCall.costly_functions(body, module, aliases)[callback],
        call != nil do
      shape = %{
        hooks?: adds_hook?(defs[callback], module, aliases),
        atomic?: Map.has_key?(defs, {:atomic, 3})
      }

      issue(callback, batch, call, shape, def_line(body, callback), issue_meta)
    end ++ notifier_issues(module, body, aliases, defs, issue_meta)
  end

  defp notifier_issues(module, body, aliases, defs, issue_meta) do
    with true <- notifier?(body),
         true <- Map.has_key?(defs, {:notify, 1}),
         %AshCall.Call{} = call <- AshCall.costly_functions(body, module, aliases)[{:notify, 1}] do
      [notifier_issue(call, def_line(body, {:notify, 1}), issue_meta)]
    else
      _ -> []
    end
  end

  defp notifier?(body),
    do: AshCall.uses?(body, [:Ash, :Notifier]) or AshCall.behaviour?(body, [:Ash, :Notifier])

  defp notifier_issue(call, line, issue_meta) do
    format_issue(issue_meta,
      message:
        "`notify/1` reaches #{AshCall.describe(call)}. Ash calls `notify/1` once per notification, " <>
          "so in a bulk action that call runs once per record. " <> notifier_advice(call.kind),
      trigger: "notify",
      line_no: line
    )
  end

  defp notifier_advice(:read),
    do:
      "Return what it reads from `load/2` instead: in a bulk action Ash loads it for the " <>
        "whole batch before calling `notify/1`."

  defp notifier_advice(_write),
    do:
      "`notify/1` has no batch form. If the write may run inside the action's transaction: " <>
        @signal_advice

  @hooks [:before_action, :after_action, :after_transaction]

  defp adds_hook?(clauses, module, aliases) do
    {_ast, found?} =
      Macro.prewalk(clauses, false, fn
        {{:., _, [mod, hook]}, _, _} = node, false when hook in @hooks ->
          {node, AshCall.expand(mod, module, aliases) == [:Ash, :Changeset]}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp def_line(body, {name, arity}) do
    {_ast, line} =
      Macro.prewalk(body, nil, fn
        {:def, meta, [head | _]} = node, nil ->
          if SephiaCredo.Ast.fun_name(head) == name and arity in SephiaCredo.Ast.fun_arities(head),
            do: {node, meta[:line]},
            else: {node, nil}

        node, acc ->
          {node, acc}
      end)

    line
  end

  defp issue({name, arity} = callback, batch, call, shape, line, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{name}/#{arity}` reaches #{AshCall.describe(call)}. Without `#{signature(batch)}` " <>
          "Ash calls `#{name}/#{arity}` once per record in a bulk action#{strategy(shape)}, so that " <>
          "call runs once per record. " <> advice(callback, shape.hooks?),
      trigger: Atom.to_string(name),
      line_no: line
    )
  end

  defp strategy(%{atomic?: true}),
    do: " that does not run atomically (an atomic one uses this module's `atomic/3`)"

  defp strategy(%{atomic?: false}), do: ""

  defp signature({name, arity}), do: "#{name}/#{arity}"

  defp advice({:validate, 3}, _hooks?),
    do: "Define `batch_validate/3` and read for every changeset in one query."

  defp advice({:change, 3}, false),
    do: "Define `batch_change/3` and read for every changeset in one query."

  defp advice({:change, 3}, true),
    do:
      "Define `batch_change/3` and move the hook's work to `after_batch/3`, which gets every " <>
        "record of the batch. " <> @signal_advice
end
