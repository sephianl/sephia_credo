defmodule SephiaCredo.AshCall do
  @moduledoc """
  Finds the calls in a module that cost a database round trip, for the checks
  that care how often those run.

  A round trip is a call to the `Ash` action API (`Ash.read/2`, `Ash.update/3`,
  …), to an Ecto repo, or to a code interface of an Ash resource or domain. A
  code interface looks like any other remote call, so it is recognised from the
  compiled resource: `StorageItem.set_zone/3` counts when `StorageItem` is a
  resource whose `code_interface` defines `set_zone`. That needs the project
  compiled before Credo runs, as `ash_credo` does; without it only the `Ash` and
  repo calls are seen.

  A local function counts too when its body, or a local function it calls,
  makes such a call, so `Enum.each(labels, &mark_missing(&1, opts))` is found
  when `mark_missing/2` is the one that writes.
  """

  @compile {:no_warn_undefined, [Ash.Resource.Info, Ash.Domain.Info, Ash.DataLayer, Spark.Dsl]}

  @ash_kinds Map.merge(
               Map.from_keys(
                 ~w(read read! read_one read_one! read_first read_first! get get! count count!
                    exists exists? aggregate aggregate! sum sum! max max! min min! avg avg!
                    first first! list list! load load! stream!)a,
                 :read
               ),
               %{
                 create: :create,
                 create!: :create,
                 bulk_create: :create,
                 bulk_create!: :create,
                 update: :update,
                 update!: :update,
                 bulk_update: :update,
                 bulk_update!: :update,
                 update_many: :update,
                 update_many!: :update,
                 destroy: :destroy,
                 destroy!: :destroy,
                 bulk_destroy: :destroy,
                 bulk_destroy!: :destroy
               }
             )
  @repo_kinds Map.merge(
                Map.from_keys(
                  ~w(get get! get_by get_by! one one! all exists? aggregate preload stream
                     query query!)a,
                  :read
                ),
                %{
                  insert: :create,
                  insert!: :create,
                  insert_all: :create,
                  insert_or_update: :create,
                  insert_or_update!: :create,
                  update: :update,
                  update!: :update,
                  update_all: :update,
                  delete: :destroy,
                  delete!: :destroy,
                  delete_all: :destroy
                }
              )
  @oban_inserts ~w(insert insert! insert_all)a
  @memory_data_layers [Ash.DataLayer.Simple, Ash.DataLayer.Ets, Ash.DataLayer.Mnesia]

  defmodule Call do
    @moduledoc "A call that costs a round trip: what it reads as, where it is, and what it does."
    defstruct [:label, :line, :column, :kind, via: nil, batched?: false, element_query?: false]
  end

  @doc """
  Every module in `ast` as `{segments, body, aliases}`, with nested modules
  under their full name. Pipes are already rewritten to plain calls.
  """
  def modules(ast) do
    ast
    |> SephiaCredo.Ast.unpipe()
    |> collect_modules([])
  end

  defp collect_modules({:defmodule, _, [{:__aliases__, _, segments}, kw]}, prefix)
       when is_list(kw) do
    name = Enum.concat(prefix, Enum.filter(segments, &is_atom/1))
    body = Keyword.get(kw, :do)
    [{name, body, aliases(body, name)} | collect_modules(body, name)]
  end

  defp collect_modules({_form, _meta, args}, prefix) when is_list(args),
    do: Enum.flat_map(args, &collect_modules(&1, prefix))

  defp collect_modules({left, right}, prefix),
    do: collect_modules(left, prefix) ++ collect_modules(right, prefix)

  defp collect_modules(nodes, prefix) when is_list(nodes),
    do: Enum.flat_map(nodes, &collect_modules(&1, prefix))

  defp collect_modules(_node, _prefix), do: []

  defp aliases(body, module) do
    {_ast, aliases} =
      Macro.prewalk(body, %{}, fn
        {:defmodule, _, _}, acc ->
          {nil, acc}

        {:alias, _, [{{:., _, [base, :{}]}, _, children} | _]} = node, acc ->
          base = expand(base, module, acc)

          acc =
            Enum.reduce(children, acc, fn
              {:__aliases__, _, segments}, inner ->
                Map.put(inner, List.last(segments), base ++ segments)

              _child, inner ->
                inner
            end)

          {node, acc}

        {:alias, _, [target, [as: {:__aliases__, _, [as]}]]} = node, acc ->
          {node, Map.put(acc, as, expand(target, module, acc))}

        {:alias, _, [target | _]} = node, acc ->
          case expand(target, module, acc) do
            [] -> {node, acc}
            segments -> {node, Map.put(acc, List.last(segments), segments)}
          end

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  @doc "The module segments an alias node names inside `module`, through its aliases."
  def expand({:__aliases__, _, [{:__MODULE__, _, _} | rest]}, module, _aliases),
    do: module ++ rest

  def expand({:__MODULE__, _, _}, module, _aliases), do: module

  def expand({:__aliases__, _, [first | rest] = segments}, _module, aliases)
      when is_atom(first) do
    case Map.fetch(aliases, first) do
      {:ok, target} -> target ++ rest
      :error -> segments
    end
  end

  def expand(_node, _module, _aliases), do: []

  @doc """
  The round-trip call `node` makes, or `nil`. `node` is a call node, or a
  `&Mod.fun/arity` capture.
  """
  def remote_call({:&, _, [{:/, _, [{{:., _, [mod, fun]}, meta, []}, arity]}]}, module, aliases)
      when is_atom(fun) and is_integer(arity),
      do: classify(expand(mod, module, aliases), mod, {fun, arity}, meta, nil)

  def remote_call({{:., _, [mod, fun]}, meta, args}, module, aliases)
      when is_atom(fun) and is_list(args) do
    case classify(expand(mod, module, aliases), mod, {fun, length(args)}, meta, args) do
      %Call{} = call -> %{call | element_query?: element_query?(args)}
      nil -> nil
    end
  end

  def remote_call(_node, _module, _aliases), do: nil

  # A load with `lazy?: true` only queries for what is not loaded yet.
  defp classify([:Ash], _mod, {fun, _arity}, meta, args)
       when fun in [:load, :load!] and is_list(args) do
    if Enum.any?(args, &lazy_option?/1),
      do: nil,
      else: maybe_call("Ash.#{fun}", meta, :read, false)
  end

  defp classify([:Ash], _mod, {fun, _arity}, meta, _args),
    do: maybe_call("Ash.#{fun}", meta, @ash_kinds[fun], bulk_api?(fun))

  defp classify([:Oban], _mod, {fun, _arity}, meta, _args) when fun in @oban_inserts,
    do: %{call("Oban.#{fun}", meta, :job) | batched?: fun == :insert_all}

  defp classify([_ | _] = segments, mod, {fun, _arity} = fun_arity, meta, args) do
    if List.last(segments) == :Repo,
      do: classify_repo(fun, meta, written(mod)),
      else: classify_module(Module.concat(segments), fun_arity, meta, written(mod), args)
  end

  defp classify(_segments, _mod, _fun, _meta, _args), do: nil

  defp classify_repo(fun, meta, name) when fun in [:query, :query!],
    do: call("#{name}.#{fun}", meta, :sql)

  defp classify_repo(fun, meta, name),
    do:
      maybe_call(
        "#{name}.#{fun}",
        meta,
        @repo_kinds[fun],
        fun in [:insert_all, :update_all, :delete_all]
      )

  defp classify_module(module, {fun, arity}, meta, name, args) do
    case interface_kind(module, fun) do
      nil -> maybe_call("#{name}.#{fun}", meta, job_kind(module, fun, arity), false)
      kind -> maybe_call("#{name}.#{fun}", meta, kind, bulk_interface_call?(args))
    end
  end

  defp maybe_call(_label, _meta, nil, _batched?), do: nil

  defp maybe_call(label, meta, kind, batched?),
    do: %{call(label, meta, kind) | batched?: batched?}

  defp bulk_api?(fun),
    do:
      fun in [
        :bulk_create,
        :bulk_create!,
        :bulk_update,
        :bulk_update!,
        :bulk_destroy,
        :bulk_destroy!,
        :update_many,
        :update_many!
      ]

  # A code interface runs as a bulk action when it is handed `bulk_options:`,
  # which nothing else accepts, or a query to update or destroy.
  defp bulk_interface_call?(nil), do: false

  defp bulk_interface_call?(args) do
    Enum.any?(args, &keyword_with?(&1, :bulk_options)) or query_arg?(List.first(args))
  end

  defp keyword_with?({:++, _, [left, _right]}, key), do: keyword_with?(left, key)
  defp keyword_with?([_ | _] = kw, key), do: Keyword.keyword?(kw) and Keyword.has_key?(kw, key)
  defp keyword_with?(_arg, _key), do: false

  defp query_arg?({{:., _, [{:__aliases__, _, [:Ash, :Query]}, _fun]}, _, _}), do: true
  defp query_arg?(_arg), do: false

  defp lazy_option?({:++, _, [left, _right]}), do: lazy_option?(left)

  defp lazy_option?([_ | _] = kw),
    do: Keyword.keyword?(kw) and Keyword.get(kw, :lazy?) == true

  defp lazy_option?(_arg), do: false

  # `Ash.count(query_fun.())`: the query comes out of the element, so each one
  # is a different query rather than the same one per row.
  defp element_query?([{{:., _, [{var, _, context}]}, _, _} | _])
       when is_atom(var) and is_atom(context),
       do: true

  defp element_query?(_args), do: false

  @doc """
  `:job` when `fun/arity` on `module` inserts an Oban job, read from the compiled
  module: a function that calls `Oban.insert/2`, `Oban.insert!/2` or
  `Oban.insert_all/2`, directly or through its own module's functions, the way
  a worker's `enqueue/1` wraps its insert.
  """
  def job_kind(module, fun, arity) do
    with {:ok, definitions} <- compiled_definitions(module),
         true <- inserts_job?(definitions, {fun, arity}, MapSet.new()) do
      if unique_worker?(module), do: :unique_job, else: :job
    else
      _ -> nil
    end
  end

  # `use Oban.Worker` generates `__opts__/0`; a module that inserts jobs may
  # define its own returning anything.
  defp unique_worker?(module) do
    function_exported?(module, :__opts__, 0) and
      case module.__opts__() do
        opts when is_list(opts) -> Keyword.keyword?(opts) and Keyword.has_key?(opts, :unique)
        _opts -> false
      end
  end

  @doc """
  Whether a change module's `change/3` adds a `before_action`, `after_action`
  or `after_transaction` hook that its `atomic/3` does not, read from the
  compiled module. On the atomic path such a hook does not run, unless the
  module also covers bulk actions with `after_batch/3` or `before_batch/3`.
  """
  def hook_skipped_when_atomic?(module) do
    with {:ok, definitions} <- compiled_definitions(module),
         {:ok, change} <- Map.fetch(definitions, {:change, 3}),
         {:ok, atomic} <- Map.fetch(definitions, {:atomic, 3}) do
      not Map.has_key?(definitions, {:after_batch, 3}) and
        not Map.has_key?(definitions, {:before_batch, 3}) and
        adds_hook?(change) and not adds_hook?(atomic)
    else
      _ -> false
    end
  end

  @hook_functions [:before_action, :after_action, :after_transaction]

  defp adds_hook?(bodies) do
    {_ast, found?} =
      Macro.prewalk(bodies, false, fn
        {{:., _, [Ash.Changeset, hook]}, _, _} = node, _acc when hook in @hook_functions ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  @doc """
  Whether a zero-arity `fun` on `module` returns a list literal on every
  clause, read from the compiled module, where module attributes are already
  inlined: `def entity_sets, do: @entity_sets`.
  """
  def constant_list?(module, fun) do
    case compiled_definitions(module) do
      {:ok, %{{^fun, 0} => [_ | _] = bodies}} -> Enum.all?(bodies, &literal_list?/1)
      _ -> false
    end
  end

  defp literal_list?(list) when is_list(list), do: Macro.quoted_literal?(list)
  defp literal_list?(_body), do: false

  # Only the project's own modules wrap an insert worth finding, and a module's
  # definitions are read once per run: decoding debug info for every remote call
  # into `Enum` or `Ash.Changeset` would cost more than the rest of the check.
  defp compiled_definitions(module) do
    if project_module?(module), do: cached_definitions(module), else: :error
  end

  defp project_module?(module) do
    Code.ensure_loaded?(module) and
      case module.module_info(:compile)[:source] do
        nil -> false
        source -> project_source?(to_string(source))
      end
  end

  defp project_source?(source),
    do: String.starts_with?(source, File.cwd!()) and not String.contains?(source, "/deps/")

  # One entry per module, replaced when the module is recompiled, so a VM that
  # runs Credo after every compile holds no stale definitions.
  defp cached_definitions(module) do
    key = {__MODULE__, :definitions, module}
    md5 = module.module_info(:md5)

    case :persistent_term.get(key, :missing) do
      {^md5, definitions} ->
        definitions

      _missing_or_stale ->
        definitions = read_definitions(module)
        :persistent_term.put(key, {md5, definitions})
        definitions
    end
  end

  defp read_definitions(module) do
    with {^module, beam, _path} <- :code.get_object_code(module),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, %{definitions: definitions}} <- backend.debug_info(:elixir_v1, module, data, []) do
      {:ok,
       Map.new(definitions, fn {name_arity, _kind, _meta, clauses} ->
         {name_arity, bodies(clauses)}
       end)}
    else
      _ -> :error
    end
  end

  defp bodies(clauses), do: Enum.map(clauses, fn {_meta, _args, _guards, body} -> body end)

  defp inserts_job?(definitions, fun, seen) do
    case Map.fetch(definitions, fun) do
      {:ok, clauses} ->
        seen = MapSet.put(seen, fun)
        {direct?, locals} = scan_clauses(clauses, definitions)
        direct? or Enum.any?(locals, &(&1 not in seen and inserts_job?(definitions, &1, seen)))

      :error ->
        false
    end
  end

  defp scan_clauses(clauses, definitions) do
    {_ast, found} =
      Macro.prewalk(clauses, {false, []}, fn
        {{:., _, [Oban, insert]}, _, _} = node, {_direct?, locals} when insert in @oban_inserts ->
          {node, {true, locals}}

        {:&, _, [{:/, _, [{name, _, context}, arity]}]} = node, {direct?, locals}
        when is_atom(name) and is_atom(context) and is_integer(arity) ->
          {node, {direct?, add_defined({name, arity}, definitions, locals)}}

        # The wrapper a default argument generates calls the full clause as `super`.
        {:super, meta, args} = node, {direct?, locals} when is_list(args) ->
          case meta[:super] do
            {_kind, name} ->
              {node, {direct?, add_defined({name, length(args)}, definitions, locals)}}

            _other ->
              {node, {direct?, locals}}
          end

        {name, _, args} = node, {direct?, locals} when is_atom(name) and is_list(args) ->
          {node, {direct?, add_defined({name, length(args)}, definitions, locals)}}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp add_defined(key, definitions, locals),
    do: if(Map.has_key?(definitions, key), do: [key | locals], else: locals)

  defp written({:__aliases__, _, segments}), do: Enum.map_join(segments, ".", &written_segment/1)
  defp written(_mod), do: "__MODULE__"

  defp written_segment({:__MODULE__, _, _}), do: "__MODULE__"
  defp written_segment(segment), do: Atom.to_string(segment)

  defp call(label, meta, kind),
    do: %Call{label: label, line: meta[:line], column: meta[:column], kind: kind}

  @doc """
  The action type a code interface call runs, `:read`, `:create`, `:update` or
  `:destroy`, when it certainly reaches the database. `nil` for anything else:
  a generic action or a calculation interface, which may never query, a
  resource kept in memory or embedded, or a module that is not compiled.
  """
  def interface_kind(module, fun) do
    cond do
      not ash_loaded?() or not Code.ensure_loaded?(module) -> nil
      Spark.Dsl.is?(module, Ash.Resource) -> resource_interface_kind(module, fun)
      Spark.Dsl.is?(module, Ash.Domain) -> domain_interface_kind(module, fun)
      true -> nil
    end
  end

  defp ash_loaded?, do: Code.ensure_loaded?(Ash.Resource.Info) and Code.ensure_loaded?(Spark.Dsl)

  defp resource_interface_kind(resource, fun) do
    case Enum.find(Ash.Resource.Info.interfaces(resource), &interface_named?(&1, fun)) do
      nil -> nil
      interface -> action_kind(resource, interface.action || interface.name)
    end
  end

  defp domain_interface_kind(domain, fun) do
    domain
    |> Ash.Domain.Info.resource_references()
    |> Enum.find_value(fn reference ->
      case Enum.find(reference.definitions, &interface_named?(&1, fun)) do
        %{__struct__: Ash.Resource.Interface} = interface ->
          action_kind(reference.resource, interface.action || interface.name)

        _other ->
          nil
      end
    end)
  end

  @doc """
  The resource a code interface call on `module` runs against, when `fun` is
  one of its code interfaces; `nil` otherwise.
  """
  def interface_resource(module, fun) do
    cond do
      not ash_loaded?() or not Code.ensure_loaded?(module) ->
        nil

      Spark.Dsl.is?(module, Ash.Resource) ->
        if Enum.any?(Ash.Resource.Info.interfaces(module), &interface_named?(&1, fun)), do: module

      Spark.Dsl.is?(module, Ash.Domain) ->
        module
        |> Ash.Domain.Info.resource_references()
        |> Enum.find_value(&defining_resource(&1, fun))

      true ->
        nil
    end
  end

  defp defining_resource(reference, fun) do
    if Enum.any?(reference.definitions, &interface_named?(&1, fun)), do: reference.resource
  end

  @doc """
  The compiled resource a module's DSL belongs to: the module itself when it
  `use`s `Ash.Resource`, and for a `Spark.Dsl.Fragment` the nearest enclosing
  namespace that is a resource (`User.Actions` belongs to `User`), which is how
  fragments are named. `nil` otherwise.
  """
  def resource_of(segments, body) do
    cond do
      uses?(body, [:Ash, :Resource]) ->
        segments |> Module.concat() |> compiled_resource()

      uses?(body, [:Spark, :Dsl, :Fragment]) ->
        segments
        |> Enum.drop(-1)
        |> ancestors()
        |> Enum.find_value(&compiled_resource(Module.concat(&1)))

      true ->
        nil
    end
  end

  defp ancestors([]), do: []
  defp ancestors(segments), do: [segments | ancestors(Enum.drop(segments, -1))]

  defp compiled_resource(module) do
    if ash_loaded?() and Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Ash.Resource),
      do: module
  end

  @doc "Whether `module` is a compiled Ash resource stored in a database."
  def stored_resource?(module) do
    ash_loaded?() and Code.ensure_loaded?(module) and Spark.Dsl.is?(module, Ash.Resource) and
      stored?(module)
  end

  defp interface_named?(%{name: name}, fun), do: fun == name or fun == :"#{name}!"

  defp action_kind(resource, action_name) do
    with true <- stored?(resource),
         %{type: type} when type in [:read, :create, :update, :destroy] <-
           Ash.Resource.Info.action(resource, action_name) do
      type
    else
      _ -> nil
    end
  end

  defp stored?(resource) do
    not Ash.Resource.Info.embedded?(resource) and
      Ash.DataLayer.data_layer(resource) not in @memory_data_layers
  end

  @doc """
  The round-trip calls in `ast`, as `%Call{}`s in source order. `skip` names
  call labels (`"Ash.load"`) to leave out.
  """
  def calls_in(ast, module, aliases, skip \\ []) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, add_call(remote_call(node, module, aliases), skip, acc)}
      end)

    calls |> Enum.reverse() |> Enum.uniq_by(&{&1.line, &1.column})
  end

  defp add_call(%Call{label: label} = call, skip, acc),
    do: if(label in skip, do: acc, else: [call | acc])

  defp add_call(nil, _skip, acc), do: acc

  @doc """
  The local functions of a module body that cost a round trip, as a map from
  `{name, arity}` to the first `%Call{}` they reach. A function that only
  reaches one through another local function gets that call with `via` set to
  the function it called.
  """
  def costly_functions(body, module, aliases) do
    body
    |> reach_index(module, aliases)
    |> Map.new(fn {key, clauses} -> {key, Enum.find_value(clauses, & &1.call)} end)
  end

  @doc """
  Per local function, each clause's head parameters and the first round-trip
  call that clause reaches, directly or through the module's own functions.
  A call with literal arguments only reaches the clauses those literals can
  match: `toggle(socket, id, true)` never runs the clause for `false`.
  """
  def reach_index(body, module, aliases) do
    defs = definitions(body)

    body
    |> clauses()
    |> Map.new(fn {key, clauses} ->
      {key,
       Enum.map(clauses, fn clause ->
         Map.put(clause, :call, clause.body |> calls_in(module, aliases) |> List.first())
       end)}
    end)
    |> reach(defs)
  end

  defp reach(index, defs) do
    index
    |> Map.new(fn {key, clauses} ->
      {key, Enum.map(clauses, &Map.put(&1, :locals, local_calls(&1.body, defs)))}
    end)
    |> reach_until_stable()
  end

  defp reach_until_stable(index) do
    {next, changed?} =
      Enum.map_reduce(index, false, fn {key, clauses}, changed? ->
        {clauses, clause_changed?} = Enum.map_reduce(clauses, false, &reach_clause(&1, &2, index))
        {{key, clauses}, changed? or clause_changed?}
      end)

    if changed?, do: reach_until_stable(Map.new(next)), else: index
  end

  defp reach_clause(%{call: nil, locals: locals} = clause, changed?, index) do
    case Enum.find_value(locals, &through(&1, index)) do
      nil -> {clause, changed?}
      call -> {%{clause | call: call}, true}
    end
  end

  defp reach_clause(clause, changed?, _index), do: {clause, changed?}

  @doc "The round-trip call a local call reaches through the clauses its arguments can match."
  def local_call_cost(index, key, args) do
    index
    |> Map.get(key, [])
    |> Enum.filter(&can_match?(&1.params, args))
    |> Enum.find_value(& &1.call)
  end

  defp through({key, meta, args}, index) do
    case local_call_cost(index, key, args) do
      nil -> nil
      call -> %{call | via: {key, meta[:line]}}
    end
  end

  defp can_match?(nil, _args), do: true
  defp can_match?(_params, nil), do: true

  defp can_match?(params, args) when length(params) == length(args),
    do: params |> Enum.zip(args) |> Enum.all?(fn {param, arg} -> compatible?(param, arg) end)

  defp can_match?(_params, _args), do: true

  defp compatible?(param, arg) do
    not (literal?(param) and literal?(arg) and param != arg)
  end

  defp literal?(value), do: is_atom(value) or is_number(value) or is_binary(value)

  defp clauses(body) do
    body
    |> statements()
    |> Enum.flat_map(&clause_heads/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp clause_heads({kind, _, [head, _kw]} = statement) when kind in [:def, :defp] do
    params = head_params(head)

    for {{_name, arity} = key, body} <- clause_definitions(statement) do
      {key, %{params: if(params && length(params) == arity, do: params), body: body}}
    end
  end

  defp clause_heads(_statement), do: []

  defp head_params({:when, _, [head | _guards]}), do: head_params(head)

  defp head_params({_name, _, params}) when is_list(params) do
    if Enum.any?(params, &match?({:\\, _, _}, &1)), do: nil, else: params
  end

  defp head_params(_head), do: nil

  @doc "The `def`/`defp` clauses of a module body, keyed by every arity each can be called at."
  def definitions(body) do
    body
    |> statements()
    |> Enum.flat_map(&clause_definitions/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp clause_definitions({kind, _, [head, kw]}) when kind in [:def, :defp] do
    with name when is_atom(name) <- SephiaCredo.Ast.fun_name(head),
         body when not is_nil(body) <- SephiaCredo.Ast.full_body(kw) do
      for arity <- SephiaCredo.Ast.fun_arities(head), do: {{name, arity}, body}
    else
      _ -> []
    end
  end

  defp clause_definitions(_statement), do: []

  defp statements({:__block__, _, statements}), do: statements
  defp statements(nil), do: []
  defp statements(statement), do: [statement]

  @doc """
  The calls to the module's own functions in `ast`, as `{{name, arity}, meta,
  args}`; `args` is `nil` for a `&name/arity` capture.
  """
  def local_calls(ast, defs) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [{name, meta, context}, arity]}]} = node, acc
        when is_atom(name) and is_atom(context) and is_integer(arity) ->
          {node, add_local({name, arity}, meta, nil, defs, acc)}

        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, add_local({name, length(args)}, meta, args, defs, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp add_local(key, meta, args, defs, acc),
    do: if(Map.has_key?(defs, key), do: [{key, meta, args} | acc], else: acc)

  @doc "Whether a module body declares `@behaviour` for `module`, given as segments."
  def behaviour?(body, segments) do
    body
    |> statements()
    |> Enum.any?(&match?({:@, _, [{:behaviour, _, [{:__aliases__, _, ^segments}]}]}, &1))
  end

  @doc "Whether a module body `use`s `module`, given as segments."
  def uses?(body, segments) do
    body
    |> statements()
    |> Enum.any?(&match?({:use, _, [{:__aliases__, _, ^segments} | _]}, &1))
  end

  @doc "How a call reads in a message: the call, and the local function it goes through."
  def describe(%Call{label: label, line: line, via: nil}), do: "`#{label}` (line #{line})"

  def describe(%Call{label: label, line: line, via: {{name, arity}, _line}}),
    do: "`#{name}/#{arity}`, which reaches `#{label}` (line #{line})"
end
