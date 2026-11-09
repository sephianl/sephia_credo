defmodule SephiaCredo.Checks.MissingAtomicCallback do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      A change or validation without `atomic/3` silently decides that every
      update or destroy running it cannot be atomic. The action needs
      `require_atomic? false`, a bulk call becomes one statement per record, and
      nothing records whether that was necessary or whether nobody tried.

      Try to make it atomic first. A value the database can compute is an
      expression:

          def atomic(_changeset, _opts, _context),
            do: {:atomic, %{notified_at: expr(now())}}

      A change that only adds an `after_action` hook reading the updated record
      can keep its `change/3`:

          def atomic(changeset, opts, context),
            do: {:ok, change(changeset, opts, context)}

      A validation is a condition that fails, and the error it raises:

          def atomic(_changeset, _opts, _context),
            do: {:atomic, [:status], expr(status == :closed), expr(error(MyError, %{}))}

      Only when it really cannot run atomically, say why, so the next reader
      does not have to work it out and the reason shows up in Ash's error when
      an action forgets `require_atomic? false`:

          def atomic(_changeset, _opts, _context),
            do: {:not_atomic, "needs the driver the route held before the update"}

      The usual reasons are a previous value, since an atomic bulk update never
      loads the row into `changeset.data` and an `UPDATE` returns only the new
      one, and a value that has to be read from another table first.

      `atomic/3` is only ever called for an update or a destroy, so a module
      the compiled project runs on nothing but creates is left alone. A module
      no compiled resource uses is reported. Run Credo after `mix compile`.
      """
    ]

  alias SephiaCredo.AshCall
  alias SephiaCredo.BulkReach

  @change_advice "Try to make it atomic: return `{:atomic, %{attribute: expr(...)}}` for a value the " <>
                   "database can compute, or `{:ok, change(changeset, opts, context)}` when it only adds " <>
                   "an `after_action` hook that reads the updated record."

  @validation_advice "Try to make it atomic: return `{:atomic, [:attribute], expr(fails?), expr(error(...))}` " <>
                       "with the condition that fails and the error it raises."

  @behaviours [
    {[:Ash, :Resource, :Change], [{:change, 3}, {:batch_change, 3}], @change_advice},
    {[:Ash, :Resource, :Validation], [{:validate, 3}], @validation_advice}
  ]

  @impl true
  def run_on_all_source_files(exec, source_files, params),
    do: super(exec, source_files, Keyword.put(params, :bulk_reach, BulkReach.index_key()))

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    reach_key = Keyword.get(params, :bulk_reach)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> AshCall.modules()
        |> Enum.flat_map(&module_issues(&1, issue_meta, reach_key))

      {:error, _} ->
        []
    end
  end

  defp module_issues({module, body, _aliases}, issue_meta, reach_key) do
    defs = AshCall.definitions(body)

    for {behaviour, callbacks, advice} <- @behaviours,
        AshCall.uses?(body, behaviour),
        callback = Enum.find(callbacks, &Map.has_key?(defs, &1)),
        callback != nil,
        not Map.has_key?(defs, {:atomic, 3}),
        not BulkReach.only_creates?(reach_key, Module.concat(module)) do
      issue(callback, advice, AshCall.def_line(body, callback), issue_meta)
    end
  end

  defp issue({name, arity}, advice, line, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{name}/#{arity}` has no `atomic/3`, so every update or destroy running this module needs " <>
          "`require_atomic? false`, and nothing says whether it has to. " <>
          advice <>
          " If it cannot be atomic, say why: `def atomic(_changeset, _opts, _context), do: " <>
          "{:not_atomic, \"the reason\"}`.",
      trigger: Atom.to_string(name),
      line_no: line
    )
  end
end
