defmodule SephiaCredo.Checks.GenericModuleName do
  use Credo.Check,
    base_priority: :low,
    category: :readability,
    param_defaults: [
      denylist: ~w(
        Result Input Output Data Info Item Object Entry Manager Handler
        Helper Helpers Utils Util Common Misc Base
      ),
      extra_denylist: [],
      suffix_denylist: ~w(Implementation Impl)
    ],
    explanations: [
      check: """
      A module name has to mean something where it is *referenced*, not only
      where it is defined. `Zelo.Planner.Mutations.ReorderStopsSolver.Result`
      reads fine nested; one `alias` later the call site says `Result.new(...)`
      and names nothing.

          defmodule ReorderStopsSolver.Result do   # Result of what?
          defmodule InsertionSolverImplementation do

      Name the module for what it holds or does — `ReorderedRoute`,
      `InsertionSolver` — so the alias carries the meaning with it.

      `denylist` matches the final segment **whole**. Measured over a 2 000-module
      codebase, matching those words as suffixes instead reported roughly forty
      modules, nearly all of them meaningful — `ScanResult`, `PlanJobInput`,
      `RouteInfo`, `ZoneData` all say what they are at the call site. A qualifier
      in front of a generic word is usually what rescues it.

      `suffix_denylist` is the exception, and matches the end of the segment.
      A role suffix is not rescued by a qualifier: `RoutingImplementation` and
      `DurationMatrixImplementation` name what a module *is to the compiler*
      rather than what it does. The same codebase had eight of them and no
      legitimate `-Implementation`.

      Matching is case-sensitive throughout, so `Database` is not a `Base` and
      `Metadata` is not `Data`.

      `Credo.Check.Readability.ModuleNames` is the neighbour here and checks a
      different thing: that a name is PascalCase, not that it means anything.
      The two do not overlap.

      Framework and ecosystem names are never reported — `Application`,
      `Supervisor`, `Registry`, `Endpoint`, `Router`, `Repo`, `Telemetry`,
      `Mailer`, `Gettext`, `ErrorHTML`, `ErrorJSON`, `Layouts` and
      `CoreComponents`. There the convention carries the meaning and renaming
      would fight the tooling.

      Support modules under `test/` are best excluded through
      `files: %{excluded: [~r"/test/"]}` rather than by the check.

      Renaming a module touches every reference, so this check ships at
      `:low` priority: it reports without failing a build.

      `denylist` replaces the default list; `extra_denylist` adds to it
      without restating it.
      """,
      params: [
        denylist: "Final name segments that carry no meaning at the point of use. Matched whole.",
        extra_denylist: "Additional segments to report, on top of `denylist`. Matched whole.",
        suffix_denylist: "Role suffixes to report wherever the segment ends with one."
      ]
    ]

  alias Credo.Check.Params

  @framework_names ~w(
    Application Supervisor Registry Endpoint Router Repo Telemetry
    Mailer Gettext ErrorHTML ErrorJSON Layouts CoreComponents
  )

  @impl true
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    words = denylisted_words(params)

    case Credo.Code.ast(source_file) do
      {:ok, ast} -> find_issues(ast, issue_meta, words)
      {:error, _} -> []
    end
  end

  defp denylisted_words(params) do
    %{
      whole:
        normalise(
          Params.get(params, :denylist, __MODULE__) ++
            Params.get(params, :extra_denylist, __MODULE__)
        ),
      suffix: normalise(Params.get(params, :suffix_denylist, __MODULE__))
    }
  end

  defp normalise(words) do
    words
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort_by(&(-String.length(&1)))
  end

  defp find_issues(ast, issue_meta, words) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, segments} | _rest]} = node, acc
        when is_list(segments) ->
          {node, generic_name_issue(segments, meta[:line], issue_meta, words) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp generic_name_issue(segments, line, issue_meta, words) do
    with name when is_binary(name) <- final_segment(segments),
         word when is_binary(word) <- generic_word(name, words) do
      [issue(segments, name, word, line, issue_meta)]
    else
      _ -> []
    end
  end

  defp final_segment(segments) do
    case List.last(segments) do
      segment when is_atom(segment) -> Atom.to_string(segment)
      _segment -> nil
    end
  end

  # A conventional name means what the framework says it means, and the
  # tooling looks it up by that name.
  defp generic_word(name, _words) when name in @framework_names, do: nil

  defp generic_word(name, %{whole: whole, suffix: suffix}) do
    Enum.find(whole, &(&1 == name)) || Enum.find(suffix, &String.ends_with?(name, &1))
  end

  defp issue(segments, name, word, line, issue_meta) do
    full_name = Enum.map_join(segments, ".", &to_string/1)

    format_issue(
      issue_meta,
      message:
        "`#{name}` says nothing at the point of use — after `alias #{full_name}`, " <>
          "the call site reads `#{name}`. Name the module for what it holds " <>
          "rather than for `#{word}`.",
      trigger: name,
      line_no: line
    )
  end
end
