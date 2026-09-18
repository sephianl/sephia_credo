defmodule SephiaCredo.Checks.UndefinedDocReference do
  use Credo.Check,
    run_on_all: true,
    base_priority: :normal,
    category: :warning,
    param_defaults: [ignore: []],
    explanations: [
      check: """
      A backticked module reference that names no module is a dead link.

      The compiler keeps code honest through a rename and says nothing about
      prose. `@moduledoc`, `@doc`, `description:` strings and the module names
      inside `raise` messages all keep pointing at whatever the module used to
      be called:

          @moduledoc \"\"\"
          Stored on `RouteDiagnostic.undo_snapshot`. Its presence (plus validity,
          see `RouteDiagnostic.Helpers.snapshot_valid?/2`) is what makes the
          "Undo" control appear.
          \"\"\"

      `RouteDiagnostic.Helpers` was split in two some releases ago and
      `snapshot_valid?/2` is now `UndoSnapshot.valid?/2`. A reader following
      that reference finds nothing, and the only thing that would have caught
      it is `mix docs`, which most projects do not build in CI.

      A staged refactor breaks it the other way too. When one rename is split
      across several pull requests it is tempting to write the prose for the
      name the module will have at the end. Measured over one such branch —
      170 files, the first of eight slices — 45 references across 26 names
      pointed at modules that did not exist yet, alongside 20 `Logger` prefixes
      and one `raise` message. Every one of them read as a plain mistake to
      anyone working in between, which is where the whole team was for a month.

      A reference resolves if it matches any module in the project or in a
      dependency, by suffix — `ModelBuilder.Clients` resolves to
      `Zelo.Planner.Exvrp.ModelBuilder.Clients` the way a reader resolves it,
      because that is how the alias at the top of the file reads. Nested
      modules resolve under their full name, so a `defmodule Params` inside
      `ExVrp.PenaltyManager` answers to `ExVrp.PenaltyManager.Params`. Modules
      `Mox.defmock/2` creates are collected too.

      Backticks mean "literal", not "module", so most of what they wrap is not
      a reference at all. Three rules keep those out without a config entry:

        * a name containing `_` is not an alias segment — `` `DB_POOL_SIZE` ``
        * an all-capitals name is a keyword or a constant — `` `SUM` ``,
          `` `LATERAL` ``
        * a single bare word is ambiguous with prose, so it is reported only
          when it is compound. `` `RouteConversion` `` and `` `BulkUpsert` ``
          are reported; `` `Cost` ``, `` `Duration` `` and `` `Parcels` `` are
          left alone, because a check cannot tell a one-word module from a
          one-word noun and the noun is the common case.
        * a compound word spelled like a proper noun is prose too. Two capitals
          in a row are an acronym — `` `PostgreSQL` ``, `` `OpenAPI` ``,
          `` `GraphQL` `` — and a short vocabulary covers the ones with no tell
          at all, such as `` `GitHub` `` and `` `TypeScript` ``, which are
          shaped exactly like a module. Add your own to `ignore`.

      A dotted name or one carrying `fun/arity` is unambiguous and always
      reported. In practice that is where most of the rot is: the branch
      measured above had 45 broken references, 22 of them dotted, and the
      compound-word rule caught most of the rest.

      `ignore` exists for the residue — a name registered at runtime that no
      module answers to, such as a `Task.Supervisor` child spec's `:name`. It
      should stay close to empty. Prefer fixing a reference over ignoring it;
      the list is for things that were never modules, not for links that rotted.

      Turn the check off entirely where documentation is *about* code that is
      not there: a library whose docs describe the consuming project, a
      migration guide naming the version it migrates from, a test fixture
      holding a deliberately broken doc. This library disables it on itself for
      exactly that reason.
      """,
      params: [
        ignore: "Backticked names that are not modules and never will be."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Execution.ExecutionIssues

  @reference ~r/`([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*)(\.[a-z_][A-Za-z0-9_?!]*\/\d+)?`/

  @proper_nouns ~w(
    GitHub GitLab BitBucket SourceHut
    JavaScript TypeScript CoffeeScript PowerShell
    YouTube LinkedIn WordPress SharePoint
    DataDog PagerDuty CloudFlare CloudFront
  )

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    known = known_names(source_files)
    ignored = ignored_names(params)

    source_files
    |> Enum.flat_map(&issues_for(&1, params, known, ignored))
    |> append_to(exec)
  end

  defp append_to(issues, exec) do
    ExecutionIssues.append(exec, issues)
    :ok
  end

  defp ignored_names(params) do
    params
    |> Params.get(:ignore, __MODULE__)
    |> MapSet.new(&name_of/1)
  end

  # `ignore: [Zelo.TaskSupervisor]` is how every other entry in a `.credo.exs`
  # is spelled, and `to_string/1` renders that atom `Elixir.Zelo.TaskSupervisor`,
  # which no name scanned out of source can match.
  defp name_of(name) when is_binary(name), do: name
  defp name_of(name) when is_atom(name), do: inspect(name)

  # `Credo.Code.ast/1` re-parses on every call, so this is a second pass over
  # the whole tree on top of Credo's own per-file work. Credo runs its own
  # `run_on_all` checks concurrently for the same reason.
  defp known_names(source_files) do
    source_files
    |> Task.async_stream(&defined_modules/1, ordered: false, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, names} -> names end)
    |> Enum.concat(dependency_modules())
    |> Enum.flat_map(&suffixes_of/1)
    |> MapSet.new()
  end

  defp defined_modules(source_file) do
    case Credo.Code.ast(source_file) do
      {:ok, ast} -> ast |> collect_modules([]) |> expand_through_aliases(collect_aliases(ast))
      {:error, _reason} -> []
    end
  end

  defp expand_through_aliases(names, aliases) do
    Enum.flat_map(names, fn
      [single] -> Enum.uniq([single, Map.get(aliases, single, single)])
      segments -> [Enum.join(segments, ".")]
    end)
  end

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, [{:__aliases__, _, segments}]} = node, acc when is_list(segments) ->
          {node, put_alias(acc, Enum.map(segments, &to_string/1))}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp put_alias(aliases, segments) do
    Map.put(aliases, List.last(segments), Enum.join(segments, "."))
  end

  defp collect_modules({:defmodule, _meta, [{:__aliases__, _, segments} | body]}, prefix)
       when is_list(segments) do
    full = Enum.concat(prefix, Enum.map(segments, &to_string/1))

    [full | collect_modules(body, full)]
  end

  defp collect_modules({{:., _, [{:__aliases__, _, [:Mox]}, :defmock]}, _meta, args}, prefix) do
    collect_defmock(args, prefix)
  end

  defp collect_modules({:defmock, _meta, args}, prefix) when is_list(args) do
    collect_defmock(args, prefix)
  end

  defp collect_modules({_form, _meta, args}, prefix) when is_list(args) do
    Enum.flat_map(args, &collect_modules(&1, prefix))
  end

  defp collect_modules({left, right}, prefix) do
    Enum.flat_map([left, right], &collect_modules(&1, prefix))
  end

  defp collect_modules(nodes, prefix) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_modules(&1, prefix))
  end

  defp collect_modules(_node, _prefix), do: []

  defp collect_defmock([{:__aliases__, _, segments} | rest], prefix) when is_list(segments) do
    [Enum.map(segments, &to_string/1) | collect_modules(rest, prefix)]
  end

  defp collect_defmock(args, prefix), do: collect_modules(args, prefix)

  defp dependency_modules do
    Mix.Project.deps_apps()
    |> Enum.concat([Mix.Project.config()[:app]])
    |> Enum.flat_map(&modules_of_app/1)
    |> Enum.map(&inspect/1)
  end

  defp modules_of_app(app) do
    Application.load(app)

    case :application.get_key(app, :modules) do
      {:ok, modules} -> modules
      :undefined -> []
    end
  end

  defp suffixes_of(name) do
    name
    |> String.split(".")
    |> tails()
    |> Enum.map(&Enum.join(&1, "."))
  end

  defp tails([]), do: []
  defp tails([_head | rest] = segments), do: [segments | tails(rest)]

  defp issues_for(source_file, params, known, ignored) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> SourceFile.lines()
    |> Enum.flat_map(fn {line_no, line} ->
      line
      |> unresolved_references(known, ignored)
      |> Enum.map(&issue(&1, line_no, issue_meta))
    end)
  end

  defp unresolved_references(line, known, ignored) do
    @reference
    |> Regex.scan(line, capture: :all_but_first)
    |> Enum.filter(&reportable?/1)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
    |> Enum.reject(&resolvable?(&1, known, ignored))
  end

  defp resolvable?(reference, known, ignored) do
    MapSet.member?(known, reference) or MapSet.member?(ignored, reference) or loaded?(reference)
  end

  defp loaded?(reference) do
    reference
    |> String.split(".")
    |> Module.concat()
    |> Code.ensure_loaded?()
  end

  defp reportable?([name | rest]) do
    module_shaped?(name) and unambiguous?(name, List.first(rest))
  end

  defp module_shaped?(name) do
    not String.contains?(name, "_") and String.upcase(name) != name
  end

  defp unambiguous?(name, nil), do: dotted?(name) or bare_module?(name)
  defp unambiguous?(name, ""), do: dotted?(name) or bare_module?(name)
  defp unambiguous?(_name, _arity_suffix), do: true

  defp dotted?(name), do: String.contains?(name, ".")

  defp bare_module?(name), do: compound?(name) and not proper_noun?(name)

  defp compound?(name), do: length(Regex.scan(~r/[A-Z]/, name)) > 1

  # A bare word is guessed at rather than resolved, so a spelling that reads as
  # a proper noun is left to prose. Two capitals in a row are an acronym —
  # `PostgreSQL`, `OpenAPI`, `GraphQL` — and the rest are told apart from a
  # module only by being known, since `GitHub` and `BulkUpsert` are one shape.
  defp proper_noun?(name), do: acronym?(name) or name in @proper_nouns

  defp acronym?(name), do: Regex.match?(~r/[A-Z]{2}/, name)

  defp issue(reference, line_no, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "`#{reference}` names no module in this project or its dependencies. " <>
          "Reference the module that exists now, or add the name to `ignore` " <>
          "if it was never a module.",
      trigger: reference,
      line_no: line_no
    )
  end
end
