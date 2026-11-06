defmodule SephiaCredo.Checks.TestLayout do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [lib_paths: ["lib"]],
    explanations: [
      check: """
      A test for a module mirrors that module's file:

          lib/my_app/planner/resources/route/changes/set_current_stop.ex
          test/my_app/planner/resources/route/changes/set_current_stop_test.exs

      A test module named after a module in `lib/` plus `Test` is that module's test.
      A module's tests may be split over files next to the main one, named
      `<module>_<part>_test.exs`. Move the test in the same PR as its module.

      A test named after anything else, such as a feature or a flow, is named after its
      own path instead, as `ModuleLayout` holds `lib/` modules to theirs:

          test/my_app/planner/route_lifecycle_test.exs   MyApp.Planner.RouteLifecycleTest

      So a test still named after a module that has since moved or been renamed is
      reported rather than skipped. `resources` is a folder, never part of a name, and is
      ignored on both sides. Files under `test/support/` hold helpers and are skipped.
      """,
      params: [lib_paths: "Folders whose modules tests are matched against."]
    ]

  alias SephiaCredo.ModulePath

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    lib_paths = Params.get(params, :lib_paths, __MODULE__)
    modules = ModulePath.scan_once(source_files, &lib_roots(&1, lib_paths))
    super(exec, source_files, Keyword.put(params, :defined_modules, modules))
  end

  @impl true
  def run(%Credo.SourceFile{filename: filename} = source_file, params) do
    lib_roots = lib_roots(filename, Params.get(params, :lib_paths, __MODULE__))

    with ["test" | path_segments] <- test_segments(filename),
         {name, line_no} <- test_module(Credo.SourceFile.ast(source_file)) do
      lib_roots
      |> module_files(params)
      |> Map.fetch(subject(name))
      |> issues(name, path_segments, filename, line_no, IssueMeta.for(source_file, params))
    else
      _ -> []
    end
  end

  defp issues({:ok, lib_file}, name, _path_segments, filename, line_no, issue_meta) do
    expected = expected_path(lib_file)

    if mirrors?(path_in_project(filename), expected),
      do: [],
      else: [misplaced_issue(issue_meta, name, expected, line_no)]
  end

  defp issues(:error, name, path_segments, _filename, line_no, issue_meta) do
    if spells?(name, path_segments),
      do: [],
      else: [misnamed_issue(issue_meta, name, path_segments, line_no)]
  end

  defp test_segments(filename) do
    with true <- String.ends_with?(filename, "_test.exs"),
         ["test" | segments] = in_test <- in_test_folder(filename),
         false <- match?(["support" | _], segments) do
      in_test
    else
      _ -> []
    end
  end

  defp in_test_folder(filename),
    do: filename |> Path.rootname(".exs") |> Path.split() |> Enum.drop_while(&(&1 != "test"))

  defp test_module({:__block__, _, [expression | _]}), do: test_module(expression)

  defp test_module({:defmodule, meta, [{:__aliases__, _, name}, _body]}),
    do: {Enum.map_join(name, ".", &Atom.to_string/1), meta[:line]}

  defp test_module(_expression), do: nil

  defp subject(name), do: String.replace_suffix(name, "Test", "")

  defp spells?(name, path_segments),
    do: ModulePath.comparable(String.split(name, ".")) == ModulePath.comparable(path_segments)

  defp lib_roots(filename, lib_paths) do
    root = ModulePath.project_root(filename, "test")
    Enum.map(lib_paths, &Path.expand(&1, root))
  end

  defp path_in_project(filename) do
    root = ModulePath.project_root(filename, "test")
    Path.relative_to(Path.expand(filename), Path.expand(root))
  end

  defp module_files(lib_roots, params),
    do: lib_roots |> ModulePath.defined_modules(params) |> Map.new()

  defp expected_path(lib_file),
    do: "test" |> Path.join(lib_file) |> String.replace_suffix(".ex", "_test.exs")

  defp mirrors?(path, path), do: true

  defp mirrors?(path, expected) do
    Path.dirname(path) == Path.dirname(expected) and
      String.starts_with?(Path.basename(path), Path.basename(expected, "_test.exs") <> "_")
  end

  defp misplaced_issue(issue_meta, name, expected, line_no) do
    format_issue(issue_meta,
      message: "#{name} tests the module in lib, so it belongs at #{expected}.",
      line_no: line_no,
      trigger: name
    )
  end

  defp misnamed_issue(issue_meta, name, path_segments, line_no) do
    named =
      path_segments |> Enum.reject(&(&1 == "resources")) |> Enum.map_join(".", &Macro.camelize/1)

    format_issue(issue_meta,
      message:
        "#{name} names no module in lib, so it is named after its path: #{named}. Rename the module, or move the file.",
      line_no: line_no,
      trigger: name
    )
  end
end
