defmodule SephiaCredo.Checks.RepoInAshResource do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [extra_resource_modules: []],
    explanations: [
      check: """
      Reaching for `Repo` from inside an Ash resource, change, validation,
      calculation, preparation or generic action goes around the framework that
      owns the data. The statement carries no tenant scoping, publishes no
      notifications, skips authorization, and sets `updated_at` from SQL rather
      than from Ash.

          Repo.query!("UPDATE orders SET current_stop_id = $1 ...", [stop_id])

      The usual defence is that a per-row bulk write needs raw SQL. It does not
      — `Ash.update_many/4` compiles to a single `MERGE` when every change is
      atomic, so it costs one statement either way:

          order_stop_pairs
          |> Enum.map(fn {order, stop} -> {%{id: order}, %{current_stop_id: stop}} end)
          |> Ash.update_many(Order, :set_current_stop, tenant: tenant)

      Reported functions are the ones that execute a statement:
      `Repo.query`, `Repo.query!`, `Repo.insert_all`, `Repo.update_all`,
      `Repo.delete_all` and `Ecto.Adapters.SQL.query/query!`. The message names
      the Ash equivalent for the one it found — `Ash.bulk_create/4`,
      `Ash.bulk_update/4`, `Ash.bulk_destroy/4` or `Ash.update_many/4`.

      A `Repo.query` is exempt only when the statement is a literal that is
      *provably* a read: it begins with `SELECT` or `WITH` and mentions no
      `INSERT`, `UPDATE` or `DELETE`. A PostGIS geometry transform touches no
      table and leaks no tenant, so reporting it would be a report with no fix
      behind it.

      SQL assembled at runtime is **not** exempt. Being unable to read a
      statement is not evidence that it is a read, and staying quiet there would
      miss exactly the case this check exists to catch — a dynamically built
      `UPDATE`.

      `Repo.transaction/1` and `Repo.rollback/1` execute no statement of their
      own. They are transaction control rather than a bypass, and are never
      reported.

      Any alias whose last segment is `Repo` matches, so `MyApp.Repo` and a
      bare aliased `Repo` are both seen. Test files are skipped.

      `extra_resource_modules` names project wrappers that themselves
      `use Ash.Resource` — without it the check is silent in a codebase where
      resources say `use MyApp.Resource`.
      """,
      params: [
        extra_resource_modules:
          "Additional modules whose `use` marks a module as an Ash resource."
      ]
    ]

  alias Credo.Check.Params
  alias SephiaCredo.TestFile

  @resource_modules ~w(
    Ash.Resource
    Ash.Resource.Change
    Ash.Resource.Validation
    Ash.Resource.Calculation
    Ash.Resource.Preparation
    Ash.Resource.Actions.Implementation
  )

  @query_functions [:query, :query!]
  @bulk_functions [:insert_all, :update_all, :delete_all]

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    markers = @resource_modules ++ Params.get(params, :extra_resource_modules, __MODULE__)

    with false <- TestFile.test_file?(source_file),
         {:ok, ast} <- Credo.Code.ast(source_file) do
      find_issues(ast, issue_meta, markers)
    else
      _ -> []
    end
  end

  defp find_issues(ast, issue_meta, markers) do
    ast
    |> resource_module_bodies(markers)
    |> Enum.flat_map(&repo_calls/1)
    |> Enum.sort()
    |> Enum.map(&issue(&1, issue_meta))
  end

  defp resource_module_bodies(ast, markers) do
    {_ast, bodies} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_name, body]} = node, acc when is_list(body) ->
          own = strip_nested_modules(body)
          {node, if(uses_resource?(own, markers), do: [own | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    bodies
  end

  # A nested `defmodule` is its own module: what it uses and what it calls both
  # belong to it rather than to the module around it.
  defp strip_nested_modules(body) do
    Macro.prewalk(body, fn
      {:defmodule, meta, _args} -> {:__stripped_module__, meta, nil}
      node -> node
    end)
  end

  defp uses_resource?(body, markers) do
    {_ast, used?} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [{:__aliases__, _, segments} | _opts]} = node, acc when is_list(segments) ->
          {node, acc or Enum.join(segments, ".") in markers}

        node, acc ->
          {node, acc}
      end)

    used?
  end

  defp repo_calls(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segments}, fun]}, meta, args} = node, acc
        when is_list(segments) and is_list(args) ->
          case trigger(segments, fun, args) do
            nil -> {node, acc}
            trigger -> {node, [{meta[:line], meta[:column], trigger, fun} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp trigger(segments, fun, _args) when fun in @bulk_functions do
    if repo?(segments), do: qualified(segments, fun)
  end

  defp trigger([:Ecto, :Adapters, :SQL] = segments, fun, args) when fun in @query_functions do
    unless provable_read?(args, 1), do: qualified(segments, fun)
  end

  defp trigger(segments, fun, args) when fun in @query_functions do
    if repo?(segments) and not provable_read?(args, 0), do: qualified(segments, fun)
  end

  defp trigger(_segments, _fun, _args), do: nil

  defp repo?(segments), do: List.last(segments) == :Repo

  defp qualified(segments, fun), do: Enum.join(segments, ".") <> "." <> to_string(fun)

  # Only a literal statement can be read. SQL assembled at runtime is opaque,
  # and opaque is not the same as safe — a built `UPDATE` still has to report.
  defp provable_read?(args, position) do
    case Enum.at(args, position) do
      sql when is_binary(sql) -> read_statement?(sql)
      {:<<>>, _meta, [sql]} when is_binary(sql) -> read_statement?(sql)
      _other -> false
    end
  end

  defp read_statement?(sql) do
    opens_read?(sql) and not (sql =~ ~r/\b(insert|update|delete)\b/i)
  end

  defp opens_read?(sql) do
    sql
    |> String.trim_leading()
    |> String.split(~r/\s/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.upcase()
    |> Kernel.in(["SELECT", "WITH"])
  end

  defp issue({line, _column, trigger, fun}, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{trigger}` inside an Ash resource runs behind the framework's back — " <>
          "no tenant scoping, no notifications, no authorization, and `updated_at` set by SQL. " <>
          fix_for(fun),
      trigger: trigger,
      line_no: line
    )
  end

  defp fix_for(:insert_all), do: "Create through the resource's action, or `Ash.bulk_create/4`."

  defp fix_for(:update_all) do
    "Update through the resource's action — `Ash.bulk_update/4`, or `Ash.update_many/4` " <>
      "when each row takes different values."
  end

  defp fix_for(:delete_all), do: "Destroy through the resource's action, or `Ash.bulk_destroy/4`."

  defp fix_for(_query) do
    "Run this through the resource's action. For a per-row bulk write, `Ash.update_many/4` " <>
      "compiles to a single `MERGE` when every change is atomic."
  end
end
