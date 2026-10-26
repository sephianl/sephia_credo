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
      `after_action` hooks.

      `atomic/3` only helps an update that runs atomically as a whole; creates
      and non-atomic updates still go through `validate/3` and `change/3`.
      Code interfaces are recognised from the compiled resource, so run Credo
      after `mix compile`.
      """
    ]

  alias SephiaCredo.AshCall

  @callbacks [
    {[:Ash, :Resource, :Validation], {:validate, 3}, {:batch_validate, 3}},
    {[:Ash, :Resource, :Change], {:change, 3}, {:batch_change, 3}}
  ]

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
      issue(callback, batch, call, def_line(body, callback), issue_meta)
    end
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

  defp issue({name, arity}, {batch, batch_arity}, call, line, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{name}/#{arity}` runs #{AshCall.describe(call)} once per record in a bulk action. " <>
          "Define `#{batch}/#{batch_arity}` to read for the whole batch at once.",
      trigger: Atom.to_string(name),
      line_no: line
    )
  end
end
