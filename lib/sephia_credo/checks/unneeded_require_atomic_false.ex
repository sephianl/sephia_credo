defmodule SephiaCredo.Checks.UnneededRequireAtomicFalse do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      `require_atomic? false` on an update or destroy whose changes and
      validations can all run atomically gives up the atomic path for nothing.
      A non-atomic bulk update or destroy streams the records, runs the
      changes per record, and checks the policy with one `SELECT … WHERE id =`
      per record; an atomic one is a single `UPDATE … WHERE`.

          update :set_zone do
            require_atomic? false   # set_attribute is atomic, so this costs a query per row
            argument :zone_id, :uuid
            change set_attribute(:zone_id, arg(:zone_id))
          end

      Removing the option changes what the action's changes see. On the atomic
      path Ash calls each change's `atomic/3` instead of `change/3`, and the
      statement updates each row as it stands in the database, which a bulk
      update never reads into `changeset.data`. A change that reads the
      record's previous value, such as the status an order moves from, has to
      express that read in `atomic/3` instead:

          def atomic(_changeset, _opts, _context),
            do: {:atomic, %{notified_at: expr(if status == :expected, do: now(), else: notified_at)}}

      Check what each change reads from the record before removing the
      option. An action whose change cannot run atomically raises when Ash
      builds it, so the tests say whether the option was needed, but not
      whether a change still behaves the same.

      The check asks Ash: it builds the action with
      `Ash.Changeset.fully_atomic_changeset/4` and no input, which runs every
      change's and validation's `atomic/3` (the action's own, global ones and
      ones added by extensions) without touching the database. That runs the
      project's own `atomic/3` callbacks and default functions, each action in
      a process of its own: one that declines without its input, raises, exits,
      waits five seconds on something other than loading code, or runs away
      leaves the action unreported. So does a resource with no `domain:` of
      its own, which Ash cannot build without one. Time spent waiting for the
      code server to load modules does not count towards the five seconds, so
      a busy machine, or the colder base pass of `credo diff`, gives the same
      answer as an idle one. Actions in a `Spark.Dsl.Fragment` are read from
      the nearest enclosing resource (`User.Actions` from `User`). Run Credo
      after `mix compile`.

      Building atomically is not the same as behaving the same: a change whose
      `atomic/3` leaves out a hook its `change/3` adds stops running that hook
      on the atomic path. The message names such changes; give them the hook
      in `atomic/3` before removing the option. An `atomic/3` that inspects
      the action's input can still decline once input is given, which the
      tests will show.

      An action that un-archives a row on an `AshArchival` resource is left
      alone. An atomic update finds its row through `atomic_upgrade_with` or
      the primary read, and AshArchival hides archived rows from every read
      not in `exclude_read_actions`, so the atomic path finds nothing to
      un-archive and fails with `StaleRecord`.
      """
    ]

  alias Ash.Resource.Info

  @compile {:no_warn_undefined,
            [Ash.Resource.Info, Ash.Changeset, Spark, Spark.Dsl, AshArchival.Resource.Info]}

  @poll_interval 50
  @max_blocked 5_000
  @max_reductions 500_000_000
  @code_loading [:code_server, :code, :erl_prim_loader, :error_handler]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} ->
        ast
        |> SephiaCredo.AshCall.modules()
        |> Enum.flat_map(&resource_issues(&1, issue_meta))

      {:error, _} ->
        []
    end
  end

  defp resource_issues({segments, body, _aliases}, issue_meta) do
    case SephiaCredo.AshCall.resource_of(segments, body) do
      nil -> []
      resource -> action_issues(resource, body, issue_meta)
    end
  end

  defp action_issues(resource, body, issue_meta) do
    for {type, name, line} <- non_atomic_actions(body),
        action = Info.action(resource, name, type),
        action != nil,
        not unarchives_hidden_row?(resource, action),
        builds_atomically?(resource, action) do
      issue(type, name, line, skipped_hooks(resource, action), issue_meta)
    end
  end

  defp unarchives_hidden_row?(resource, action) do
    AshArchival.Resource in Spark.extensions(resource) and
      writes_attribute?(action, AshArchival.Resource.Info.archive_attribute!(resource)) and
      archived_rows_hidden_from?(resource, upgrade_read(resource, action))
  end

  defp writes_attribute?(action, attribute) do
    attribute in action.accept or
      Enum.any?(action.changes, fn
        %{change: {Ash.Resource.Change.SetAttribute, opts}} -> opts[:attribute] == attribute
        _change -> false
      end)
  end

  defp upgrade_read(_resource, %{atomic_upgrade_with: name}) when is_atom(name) and name != nil,
    do: name

  defp upgrade_read(resource, _action) do
    case Info.primary_action(resource, :read) do
      %{name: name} -> name
      nil -> nil
    end
  end

  defp archived_rows_hidden_from?(resource, read) do
    AshArchival.Resource.Info.archive_base_filter?(resource) or
      read not in AshArchival.Resource.Info.archive_exclude_read_actions!(resource)
  end

  defp skipped_hooks(resource, action) do
    (action.changes ++ Info.changes(resource, action.type))
    |> Enum.flat_map(fn
      %{__struct__: Ash.Resource.Change, change: {module, _opts}} -> [module]
      _validation -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(&SephiaCredo.AshCall.hook_skipped_when_atomic?/1)
  end

  # Ash's own answer: it runs each change's and validation's `atomic/3`, which
  # build expressions without touching the database. A callback that needs an
  # input the empty params lack declines or raises, so the action is left alone.
  # The callbacks are the project's code, so they run in a process of their own:
  # one that raises, exits or hangs leaves the action unreported instead of
  # stopping the Credo run.
  defp builds_atomically?(resource, action) do
    {pid, ref} = spawn_monitor(fn -> exit({:built, atomic_changeset?(resource, action)}) end)
    await_build(pid, ref, 0)
  end

  # A wall-clock deadline would make the answer depend on the machine's load:
  # early in a full run every build queues behind the code server loading
  # modules, for over ten seconds on a sixteen-core machine. `credo diff`
  # analyses the base first, in the colder VM, so an action dropped there comes
  # back as a new issue on a branch that never touched it. Only time blocked on
  # something other than loading code counts towards the limit, and a build that
  # keeps computing is stopped by the work it does, not the time it takes.
  defp await_build(pid, ref, blocked) do
    receive do
      {:DOWN, ^ref, :process, ^pid, {:built, built?}} -> built?
      {:DOWN, ^ref, :process, ^pid, _reason} -> false
    after
      @poll_interval ->
        case progress(pid) do
          :loading_code -> await_build(pid, ref, blocked)
          :running -> await_build(pid, ref, blocked)
          :blocked when blocked < @max_blocked -> await_build(pid, ref, blocked + @poll_interval)
          _stuck_or_runaway -> stop_build(pid, ref)
        end
    end
  end

  defp progress(pid) do
    case Process.info(pid, [:status, :current_function, :reductions]) do
      nil ->
        :running

      [status: _, current_function: _, reductions: r] when r > @max_reductions ->
        :runaway

      [status: _, current_function: {module, _, _}, reductions: _] when module in @code_loading ->
        :loading_code

      [status: :waiting, current_function: _, reductions: _] ->
        :blocked

      _running_or_runnable ->
        :running
    end
  end

  defp stop_build(pid, ref) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    false
  end

  defp atomic_changeset?(resource, action) do
    match?(
      %{__struct__: Ash.Changeset},
      Ash.Changeset.fully_atomic_changeset(resource, action, %{},
        authorize?: false,
        skip_unknown_inputs: :*
      )
    )
  catch
    _kind, _reason -> false
  end

  defp non_atomic_actions(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {type, _meta, [name, kw]} = node, acc
        when type in [:update, :destroy] and is_atom(name) and is_list(kw) ->
          case require_atomic_false_line(Keyword.get(kw, :do)) do
            nil -> {node, acc}
            line -> {node, [{type, name, line} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp require_atomic_false_line(block) do
    {_ast, line} =
      Macro.prewalk(block, nil, fn
        {:require_atomic?, meta, [false]} = node, nil -> {node, meta[:line]}
        node, acc -> {node, acc}
      end)

    line
  end

  defp issue(type, name, line, skipped, issue_meta) do
    format_issue(issue_meta,
      message:
        "`#{type} :#{name}` sets `require_atomic? false`, but Ash builds it atomically. Without the " <>
          "option a bulk #{type} is one statement instead of one per record, and Ash calls each " <>
          "change's `atomic/3` instead of `change/3`. Before removing it, check what the changes " <>
          "read from the record as it was: a previous value read from `changeset.data` in " <>
          "`change/3` has to become an expression in `atomic/3`." <> skipped_note(skipped),
      trigger: "require_atomic?",
      line_no: line
    )
  end

  defp skipped_note([]), do: ""

  defp skipped_note(modules) do
    names = Enum.map_join(modules, ", ", &"`#{inspect(&1)}`")
    verb = if length(modules) == 1, do: "adds", else: "add"

    " And #{names} #{verb} a hook in `change/3` that `atomic/3` does not, so on the atomic " <>
      "path that hook stops running; add it in `atomic/3` too."
  end
end
