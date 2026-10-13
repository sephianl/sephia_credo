defmodule SephiaCredo.Checks.ProjectImport do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [project_modules: nil, allowed: []],
    explanations: [
      check: """
      Call the project's own modules through an alias, not an import.

          # preferred
          alias MyAppWeb.Routes.ListRoutesHelpers
          ListRoutesHelpers.route_stops(route)

          # flagged
          import MyAppWeb.Routes.ListRoutesHelpers
          route_stops(route)

      An imported function is called without its module, so searching for the module
      no longer finds its callers and dead functions hide behind the import. An import
      also makes the importing module a compile-time dependent of the imported one,
      widening what an edit recompiles; an alias does not.

      Function components follow the same rule: `<ListRoutesHelpers.stop_row />` works
      as well as `<.stop_row />`. Modules whose macros must be called unqualified, such
      as ones Ash expressions use, go in `allowed`. An import inside a `quote` is left
      alone: it is what `use MyAppWeb` hands every caller, and `allowed` covers those
      modules at the call site. Test files are exempt.

      An import that supplies a function plug, as `phx.gen.auth`'s `import
      MyAppWeb.UserAuth` does for `plug :fetch_current_scope_for_user` and
      `pipe_through [:require_authenticated_user]`, is left alone: a plug named by an
      atom must be local or imported.

      `project_modules` defaults to the Mix app's module and its `Web` module, so
      `:my_app` checks imports of `MyApp` and `MyAppWeb`.
      """,
      params: [
        project_modules:
          "Module name prefixes that are the project's own, as strings. Defaults from the Mix app.",
        allowed: "Project modules that may still be imported, as module name strings."
      ]
    ]

  alias SephiaCredo.ModulePath
  alias SephiaCredo.TestFile

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    public_functions = public_functions(source_files)
    super(exec, source_files, Keyword.put(params, :public_functions, public_functions))
  end

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    if test_code?(source_file) do
      []
    else
      ast = Credo.SourceFile.ast(source_file)

      config = %{
        project: project_modules(Params.get(params, :project_modules, __MODULE__)),
        allowed: Params.get(params, :allowed, __MODULE__),
        current_module: current_module(ast),
        plugs: plug_names(ast),
        public_functions: Keyword.get(params, :public_functions, %{}),
        issue_meta: IssueMeta.for(source_file, params)
      }

      Credo.Code.prewalk(source_file, &collect(&1, &2, config))
    end
  end

  defp test_code?(%Credo.SourceFile{filename: filename} = source_file) do
    segments = Path.split(filename)
    TestFile.test_file?(source_file) or ("test" in segments and "lib" not in segments)
  end

  defp current_module(ast) do
    case ModulePath.defined_module(ast) do
      {segments, _line_no, _body} -> Enum.join(segments, ".")
      nil -> nil
    end
  end

  defp public_functions(source_files) do
    for source_file <- source_files,
        {segments, _line_no, body} <- [
          ModulePath.defined_module(Credo.SourceFile.ast(source_file))
        ],
        into: %{},
        do: {Enum.join(segments, "."), MapSet.new(body, &def_name/1)}
  end

  defp def_name({kind, _, [{:when, _, [{name, _, _} | _]} | _]})
       when kind in [:def, :defdelegate],
       do: name

  defp def_name({kind, _, [{name, _, _} | _]}) when kind in [:def, :defdelegate], do: name
  defp def_name(_expression), do: nil

  defp plug_names(ast) do
    {_ast, names} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:plug, _, [name | _]} = node, names when is_atom(name) ->
          {node, MapSet.put(names, name)}

        {:pipe_through, _, [pipelines]} = node, names ->
          {node,
           pipelines
           |> List.wrap()
           |> Enum.filter(&is_atom/1)
           |> MapSet.new()
           |> MapSet.union(names)}

        node, names ->
          {node, names}
      end)

    names
  end

  defp project_modules(nil) do
    case Mix.Project.config()[:app] do
      nil ->
        []

      app ->
        root = app |> Atom.to_string() |> Macro.camelize()
        [root, root <> "Web"]
    end
  end

  defp project_modules(modules), do: modules

  defp collect({:quote, _, _}, issues, _config), do: {:skipped_quote, issues}

  defp collect({:import, meta, [{:__aliases__, _, parts} | _]} = ast, issues, config)
       when is_list(parts) do
    module = module_name(parts, config.current_module)

    if is_binary(module) and project?(module, config.project) and module not in config.allowed and
         not supplies_plug?(module, config),
       do: {ast, [issue_for(config.issue_meta, meta[:line], module) | issues]},
       else: {ast, issues}
  end

  defp collect(ast, issues, _config), do: {ast, issues}

  defp module_name([{:__MODULE__, _, _} | parts], current) when is_binary(current),
    do: module_name([current | parts], nil)

  defp module_name(parts, _current) do
    if Enum.all?(parts, &(is_atom(&1) or is_binary(&1))),
      do: Enum.map_join(parts, ".", &to_string/1)
  end

  defp supplies_plug?(module, config) do
    config.public_functions
    |> Map.get(module, MapSet.new())
    |> MapSet.disjoint?(config.plugs)
    |> Kernel.not()
  end

  defp project?(module, project),
    do: Enum.any?(project, &(module == &1 or String.starts_with?(module, &1 <> ".")))

  defp issue_for(issue_meta, line_no, module) do
    format_issue(issue_meta,
      message: "Alias #{module} instead of importing it, so its callers stay searchable.",
      line_no: line_no,
      trigger: "import"
    )
  end
end
