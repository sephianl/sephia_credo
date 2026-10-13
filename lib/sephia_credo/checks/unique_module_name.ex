defmodule SephiaCredo.Checks.UniqueModuleName do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [included_paths: []],
    explanations: [
      check: """
      No two modules in the checked paths end in the same name. `alias A.DepotDay`
      followed by `alias B.DepotDay` compiles, and every later `DepotDay` silently means
      the second one.
      """,
      params: [included_paths: "Path prefixes whose module names must not repeat."]
    ]

  alias SephiaCredo.ModulePath

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    included_paths = Params.get(params, :included_paths, __MODULE__)
    modules = ModulePath.scan_once(source_files, &included_roots(&1, included_paths))
    super(exec, source_files, Keyword.put(params, :defined_modules, modules))
  end

  @impl true
  def run(%Credo.SourceFile{filename: filename} = source_file, params) do
    included_paths = Params.get(params, :included_paths, __MODULE__)

    if ModulePath.under?(ModulePath.lib_segments(filename), included_paths) do
      source_file
      |> Credo.SourceFile.ast()
      |> ModulePath.defined_module()
      |> issues(
        module_names(included_roots(filename, included_paths), params),
        IssueMeta.for(source_file, params)
      )
    else
      []
    end
  end

  defp issues(nil, _module_names, _issue_meta), do: []

  defp issues({module_segments, line_no, _body}, module_names, issue_meta) do
    module = Enum.join(module_segments, ".")

    case module_names |> Map.get(List.last(module_segments), []) |> List.delete(module) do
      [] -> []
      others -> [issue(issue_meta, module, others, line_no)]
    end
  end

  defp included_roots(filename, included_paths) do
    root = ModulePath.project_root(filename)
    Enum.map(included_paths, &Path.join(root, &1))
  end

  defp module_names(included_roots, params) do
    included_roots
    |> ModulePath.defined_modules(params)
    |> Enum.group_by(
      fn {name, _file} -> name |> String.split(".") |> List.last() end,
      &elem(&1, 0)
    )
  end

  defp issue(issue_meta, module, others, line_no) do
    format_issue(issue_meta,
      message:
        "#{module} ends in the same name as #{Enum.join(others, ", ")}. Name it for what sets it apart.",
      line_no: line_no,
      trigger: module
    )
  end
end
