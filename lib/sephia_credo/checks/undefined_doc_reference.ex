defmodule SephiaCredo.Checks.UndefinedDocReference do
  use Credo.Check,
    run_on_all: true,
    base_priority: :normal,
    category: :warning,
    param_defaults: [ignore: [], extra_name_paths: []],
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

      A name a supervision tree registers counts as defined, because docs name a
      registered process exactly the way they name a module and no module ever
      answers to it. Any module-shaped value passed as `:name` is collected —
      `{Phoenix.PubSub, name: MyApp.PubSub}`, `{Registry, keys: :unique, name:
      MyApp.StopRegistry}` — from anywhere in the scanned tree, not only the
      file that documents it. What is matched is the `:name` key rather than the
      child spec around it, so a `name:` elsewhere resolves its value too. That
      costs a report on a rotted reference whose name happens to sit behind some
      other `name:`, and buys not having to hard-code the shape of a child spec,
      which every library spells its own way.

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

      `extra_name_paths` reaches names the check would otherwise never see, and
      is the answer whenever a whole *class* of reference reports. Credo scans
      `lib/`, `test/` and friends, so a module under `priv/repo/migrations` is
      real and unresolvable at once; an `.ex`/`.exs` path here is parsed for its
      `defmodule`s the same way. Any other extension is read for capitalised
      words instead, which is how a Phoenix project resolves the LiveView hooks
      its docs name — point at `assets/js/hooks.ts` and `` `RouteMapHook` ``
      resolves. That is worth more than ignoring such a name: a hook renamed in
      JavaScript then reports here, which is the whole point of the check.

      `ignore` is for the residue only — a capitalised prose word, a SQL keyword
      in a query doc, a class in a sibling repo no path here can reach. It
      should stay close to empty, and a growing list means a missing
      `extra_name_paths` entry. Prefer fixing a reference over ignoring it; the
      list is for things that were never modules, not for links that rotted.

      Turn the check off entirely where documentation is *about* code that is
      not there: a library whose docs describe the consuming project, a
      migration guide naming the version it migrates from, a test fixture
      holding a deliberately broken doc. This library disables it on itself for
      exactly that reason.
      """,
      params: [
        ignore: "Backticked names that are not modules and never will be.",
        extra_name_paths:
          "Paths or globs holding names the scanned tree does not define. " <>
            "`.ex`/`.exs` files are parsed for `defmodule`s; anything else " <>
            "contributes its capitalised words."
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
    known = known_names(source_files, params)
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
  defp known_names(source_files, params) do
    source_files
    |> Task.async_stream(&defined_modules/1, ordered: false, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, names} -> names end)
    |> Enum.concat(dependency_modules())
    |> Enum.concat(extra_names(params))
    |> Enum.flat_map(&suffixes_of/1)
    |> MapSet.new()
  end

  defp extra_names(params) do
    params
    |> Params.get(:extra_name_paths, __MODULE__)
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(&names_in_file/1)
  end

  defp names_in_file(path) do
    case File.read(path) do
      {:ok, contents} -> names_in(Path.extname(path), contents)
      {:error, _reason} -> []
    end
  end

  defp names_in(extension, contents) when extension in [".ex", ".exs"] do
    case Code.string_to_quoted(contents) do
      {:ok, ast} -> ast |> collect_modules([]) |> expand_through_aliases(collect_aliases(ast))
      {:error, _reason} -> []
    end
  end

  # Anything else is read for the shape a reference has rather than parsed: a
  # file named here is a registry the project points at on purpose, so every
  # capitalised word in it counts.
  defp names_in(_extension, contents) do
    ~r/\b[A-Z][A-Za-z0-9]*\b/
    |> Regex.scan(contents)
    |> Enum.map(&hd/1)
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

  # A module-shaped value passed as `:name` is a process registering under that
  # name — a `Phoenix.PubSub`, a `Registry`, a `Task.Supervisor`. No module ever
  # answers to it, so nothing else here would collect it, and docs name it the
  # same way they name a module.
  defp collect_modules({:name, {:__aliases__, _, segments}}, _prefix) when is_list(segments) do
    [Enum.map(segments, &to_string/1)]
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
