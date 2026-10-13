defmodule SephiaCredo.Checks.ModuleLayout do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [included_paths: []],
    explanations: [
      check: """
      A module lives at the path its name spells, so the file a name points at is the
      file it is in:

          MyApp.Planner.Solver.ModelBuilder  lib/my_app/planner/solver/model_builder.ex
          MyApp.Geography                    lib/my_app/geography/geography.ex

      `resources` is a folder, never part of a name, and is ignored on both sides. A
      domain module may sit in its own folder, as `MyApp.Geography` does. Ash resource
      code is skipped: where it lives is a convention of its own.

      The fix is a `git mv`: keep the module name.
      """,
      params: [included_paths: "Path prefixes whose modules are checked."]
    ]

  alias SephiaCredo.ModulePath

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    path_segments = ModulePath.lib_segments(source_file.filename)

    if ModulePath.under?(path_segments, Params.get(params, :included_paths, __MODULE__)) do
      source_file
      |> Credo.SourceFile.ast()
      |> ModulePath.defined_module()
      |> issues(path_segments, IssueMeta.for(source_file, params))
    else
      []
    end
  end

  defp issues(nil, _path_segments, _issue_meta), do: []

  defp issues({module_segments, line_no, body}, path_segments, issue_meta) do
    if ModulePath.resource_code?(body) or spells?(module_segments, path_segments) do
      []
    else
      [issue(issue_meta, module_segments, path_segments, line_no)]
    end
  end

  defp spells?(module_segments, path_segments) do
    module = ModulePath.comparable(module_segments)

    module == ModulePath.comparable(path_segments) or
      module == ModulePath.comparable(own_folder(path_segments))
  end

  defp own_folder(path_segments),
    do: path_segments |> Enum.reverse() |> drop_repeated_file() |> Enum.reverse()

  defp drop_repeated_file([same, same | folders]), do: [same | folders]
  defp drop_repeated_file(reversed_segments), do: reversed_segments

  defp issue(issue_meta, module_segments, path_segments, line_no) do
    module = Enum.join(module_segments, ".")
    expected = ModulePath.expected_path(module_segments, path_segments)

    format_issue(issue_meta,
      message: "#{module} belongs at #{expected}. Move the file; keep the module name.",
      line_no: line_no,
      trigger: module
    )
  end
end
