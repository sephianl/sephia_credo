defmodule SephiaCredo.ModulePath do
  @moduledoc """
  How the layout checks read a file's path and the module it defines, so they all agree
  on what "the path spells the module name" means. `resources` is a folder, never part of
  a name, so it is ignored on both sides.
  """

  def lib_segments(filename) do
    case filename |> Path.rootname(".ex") |> Path.split() |> Enum.drop_while(&(&1 != "lib")) do
      ["lib" | segments] -> segments
      _ -> []
    end
  end

  @doc """
  The folder holding the file's `lib/` (or `folder`), so paths a check reads resolve in
  the tree the file came from, such as the merge-base clone `credo diff` checks, and not
  the cwd.
  """
  def project_root(filename, folder \\ "lib") do
    case filename |> Path.split() |> Enum.split_while(&(&1 != folder)) do
      {[], _folder} -> "."
      {root, [^folder | _]} -> Path.join(root)
      {_root, []} -> "."
    end
  end

  def under?(path_segments, prefixes) do
    path = Path.join(["lib" | path_segments])
    Enum.any?(prefixes, &String.starts_with?(path, &1))
  end

  def top_level_expressions({:__block__, _, expressions}), do: expressions
  def top_level_expressions(expression), do: [expression]

  def defined_module(ast),
    do: ast |> top_level_expressions() |> Enum.find_value(&module_definition/1)

  defp module_definition({:defmodule, meta, [{:__aliases__, _, name}, [do: body]]}),
    do: {Enum.map(name, &Atom.to_string/1), meta[:line], top_level_expressions(body)}

  defp module_definition(_expression), do: nil

  @resource_parts [
    [:Ash, :Resource],
    [:Ash, :Resource, :Change],
    [:Ash, :Resource, :Validation],
    [:Ash, :Resource, :Preparation],
    [:Ash, :Resource, :Calculation]
  ]

  def resource_code?(body), do: Enum.any?(body, &resource_use?/1)

  defp resource_use?({:use, _, [{:__aliases__, _, module} | _]}) when module in @resource_parts,
    do: true

  defp resource_use?({:use, _, [{:__aliases__, _, [:Spark, :Dsl, :Fragment]}, opts]})
       when is_list(opts),
       do: match?({:__aliases__, _, [:Ash, :Resource]}, Keyword.get(opts, :of))

  defp resource_use?(_expression), do: false

  @doc """
  Scans each distinct set of roots the files need once per Credo run, so
  `defined_modules/2` looks them up instead of every file rescanning.
  """
  def scan_once(source_files, roots_for) do
    source_files
    |> Enum.map(&roots_for.(&1.filename))
    |> Enum.uniq()
    |> Map.new(&{&1, defined_modules(&1)})
  end

  def defined_modules(roots, params) do
    params
    |> Keyword.get(:defined_modules, %{})
    |> Map.get_lazy(roots, fn -> defined_modules(roots) end)
  end

  defp defined_modules(roots) do
    for root <- roots,
        file <- Path.wildcard(Path.join(root, "**/*.ex")),
        [_, name] <- Regex.scan(~r/^defmodule ([\w.]+) do/m, File.read!(file)),
        do: {name, Path.relative_to(file, root)}
  end

  def comparable(segments) do
    segments
    |> Enum.map(&(&1 |> String.downcase() |> String.replace("_", "")))
    |> Enum.reject(&(&1 == "resources"))
  end

  def expected_path(module_segments, path_segments) do
    folders = Enum.reject(path_segments, &(&1 == "resources"))

    parts =
      module_segments
      |> Enum.reject(&(&1 == "Resources"))
      |> Enum.zip(Stream.concat(folders, Stream.repeatedly(fn -> nil end)))
      |> Enum.map(fn {segment, folder} -> spelling(segment, folder) end)

    parts
    |> insert_resources(resources_index(parts, path_segments))
    |> then(&Path.join(["lib" | &1]))
    |> Kernel.<>(".ex")
  end

  defp insert_resources(parts, nil), do: parts
  defp insert_resources(parts, index), do: List.insert_at(parts, index, "resources")

  defp resources_index(parts, path_segments) do
    index = Enum.find_index(path_segments, &(&1 == "resources"))

    if index &&
         comparable(Enum.take(path_segments, index)) == comparable(Enum.take(parts, index)),
       do: index
  end

  defp spelling(segment, nil), do: Macro.underscore(segment)

  defp spelling(segment, folder) do
    if comparable([segment]) == comparable([folder]),
      do: folder,
      else: Macro.underscore(segment)
  end
end
