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
      Tests named after anything else, such as a feature or a flow, are not checked.
      A module's tests may be split over files next to the main one, named
      `<module>_<part>_test.exs`.

      Move the test in the same PR as its module.
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

    with true <- String.ends_with?(filename, "_test.exs"),
         {name, line_no} <- test_module(Credo.SourceFile.ast(source_file)),
         {:ok, lib_file} <- Map.fetch(module_files(lib_roots, params), subject(name)),
         expected = expected_path(lib_file),
         false <- mirrors?(path_in_project(filename), expected) do
      [issue(IssueMeta.for(source_file, params), name, expected, line_no)]
    else
      _ -> []
    end
  end

  defp test_module({:__block__, _, [expression | _]}), do: test_module(expression)

  defp test_module({:defmodule, meta, [{:__aliases__, _, name}, _body]}),
    do: {Enum.map_join(name, ".", &Atom.to_string/1), meta[:line]}

  defp test_module(_expression), do: nil

  defp subject(name), do: String.replace_suffix(name, "Test", "")

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

  defp issue(issue_meta, name, expected, line_no) do
    format_issue(issue_meta,
      message: "#{name} tests the module in lib, so it belongs at #{expected}.",
      line_no: line_no,
      trigger: name
    )
  end
end
