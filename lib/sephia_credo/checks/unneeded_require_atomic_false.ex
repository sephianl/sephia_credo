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

      Remove the option. An action whose change cannot run atomically raises
      when Ash builds it, so the tests say whether it was needed.

      The check asks Ash: it builds the action with
      `Ash.Changeset.fully_atomic_changeset/4` and no input, which runs every
      change's and validation's `atomic/3` (the action's own, global ones and
      ones added by extensions) without touching the database. A callback that
      declines without its input leaves the action unreported. Actions in a
      `Spark.Dsl.Fragment` are read from the nearest enclosing resource
      (`User.Actions` from `User`). Run Credo after `mix compile`.
      """
    ]

  alias Ash.Resource.Info

  @compile {:no_warn_undefined, [Ash.Resource.Info, Ash.Changeset, Spark.Dsl]}

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
        builds_atomically?(resource, action) do
      issue(type, name, line, skipped_hooks(resource, action), issue_meta)
    end
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
  defp builds_atomically?(resource, action) do
    match?(
      %{__struct__: Ash.Changeset},
      Ash.Changeset.fully_atomic_changeset(resource, action, %{},
        authorize?: false,
        skip_unknown_inputs: :*
      )
    )
  rescue
    _error -> false
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
        "`#{type} :#{name}` sets `require_atomic? false`, but Ash builds it atomically. Without it " <>
          "a bulk #{type} is one statement instead of one per record." <> skipped_note(skipped),
      trigger: "require_atomic?",
      line_no: line
    )
  end

  defp skipped_note([]), do: ""

  defp skipped_note(modules) do
    names = Enum.map_join(modules, ", ", &"`#{inspect(&1)}`")
    verb = if length(modules) == 1, do: "adds", else: "add"

    " Before removing it: #{names} #{verb} a hook in `change/3` that `atomic/3` does not, so on " <>
      "the atomic path that hook stops running; add it in `atomic/3` too."
  end
end
