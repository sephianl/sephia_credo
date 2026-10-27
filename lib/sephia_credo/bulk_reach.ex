defmodule SephiaCredo.BulkReach do
  @moduledoc """
  Whether a change or validation module can run in a bulk action, read from
  the compiled project.

  A module counts as reached in bulk when a resource lists it in its global
  `changes` or `validations`, which every action of those types runs, bulk ones
  included, or when an action that lists it can run in bulk:

    * a primary action, which `manage_relationship`, `cascade_destroy`,
      `cascade_update` and AshArchival run in bulk by default;
    * an action named by a `cascade_destroy`, `cascade_update` or
      `manage_relationship` option written out in a resource or in code;
    * an action named in an `Ash.bulk_create/4`, `Ash.bulk_update/4`,
      `Ash.bulk_destroy/4` or `Ash.update_many/4` call anywhere in the
      project, where a resource or action given as a variable matches every
      one;
    * an action whose code interface is called with anything but one record:
      a list, a query, a stream, or a value the code does not show to be a
      single record. A value counts as one record when it is a struct, map or
      id, comes from a single-record read or write, is one element of a
      collection, or when the caller handles the result as `{:ok, record}`,
      which a bulk call never returns. A private function's parameter is
      followed to the module's own calls of it.

  Anything the code does not show counts as bulk, so a module is only cleared
  when every action using it is shown to run on one record at a time. Every
  module the project compiles is read, test support included; `*_test.exs`
  files are never compiled into it. What this cannot see: an action run in
  bulk from a dependency other than Ash itself, through `apply/3`, or by a
  `manage_relationship` whose options are not written out. Actions AshGraphql
  and AshJsonApi run take one record per request.
  """

  @compile {:no_warn_undefined, [Ash.Resource.Info, Ash.Domain.Info, Spark.Dsl, Mix.Project]}

  @bulk_api %{
    bulk_create: :create,
    bulk_create!: :create,
    bulk_update: :update,
    bulk_update!: :update,
    bulk_destroy: :destroy,
    bulk_destroy!: :destroy,
    update_many: :update,
    update_many!: :update
  }
  @cascades [Ash.Resource.Change.CascadeDestroy, Ash.Resource.Change.CascadeUpdate]
  @one_element [:at, :fetch, :fetch!, :find, :find_value, :random, :min, :max, :min_by, :max_by]
  @one_element_list [:first, :last]
  @chunking [:chunk_every, :chunk_by, :chunk_while, :split, :split_while, :split_with]
  @max_depth 4

  @doc """
  Builds the compiled project's index once per set of compiled modules, keeps
  it in `:persistent_term` and returns its key, for `reach/2`; `nil` when there
  is no Mix project or Ash to read. Call it once per run: it lists and stats
  every compiled module.
  """
  def index_key do
    with true <- Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil,
         true <- Code.ensure_loaded?(Ash.Resource.Info) and Code.ensure_loaded?(Spark.Dsl),
         [_ | _] = beams <- Enum.flat_map(ebins(), &Path.wildcard(Path.join(&1, "*.beam"))) do
      key = {__MODULE__, :erlang.phash2(Enum.map(beams, &{&1, mtime(&1)}))}
      :global.trans({key, self()}, fn -> build_once(key, beams) end)
      key
    else
      _ -> nil
    end
  end

  # Checks run their files in parallel; the first to ask builds, the rest wait.
  defp build_once(key, beams) do
    if :persistent_term.get(key, nil) == nil,
      do: :persistent_term.put(key, beams |> build() |> Map.put(:key, key))
  end

  @doc """
  `:bulk` when some action using `module` can run in bulk, `:single` when every
  action using it runs on one record at a time, and `:unknown` when there is no
  index or no resource uses the module.
  """
  def reach(nil, _module), do: :unknown
  def reach(key, module), do: key |> :persistent_term.get(nil) |> index_reach(module)

  defp index_reach(nil, _module), do: :unknown
  defp index_reach(index, module), do: index |> uses(module) |> uses_reach(index)

  defp uses_reach([], _index), do: :unknown

  defp uses_reach(uses, index),
    do: if(Enum.any?(uses, &bulk?(index, &1)), do: :bulk, else: :single)

  defp ebins do
    apps =
      if Mix.Project.umbrella?(),
        do: Map.keys(Mix.Project.apps_paths()),
        else: List.wrap(Mix.Project.config()[:app])

    for app <- apps, do: Path.join([Mix.Project.build_path(), "lib", to_string(app), "ebin"])
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      {:error, _} -> nil
    end
  end

  defp build(beams) do
    modules =
      for beam <- beams,
          {:ok, {module, chunks}} <- [
            :beam_lib.chunks(String.to_charlist(beam), [:imports, :exports, :attributes])
          ],
          do: {module, beam, chunks}

    callers =
      Enum.reduce(modules, %{}, fn {module, _beam, chunks}, acc ->
        Enum.reduce(chunks[:imports], acc, fn {mod, fun, _arity}, acc ->
          Map.update(acc, {mod, fun}, MapSet.new([module]), &MapSet.put(&1, module))
        end)
      end)

    dsl_modules =
      for {module, _beam, chunks} <- modules,
          {:spark_dsl_config, 0} in chunks[:exports],
          Code.ensure_loaded?(module),
          do: module

    resources = Enum.filter(dsl_modules, &Spark.Dsl.is?(&1, Ash.Resource))
    domains = Enum.filter(dsl_modules, &Spark.Dsl.is?(&1, Ash.Domain))
    beams_by_module = Map.new(modules, fn {module, beam, _chunks} -> {module, beam} end)

    deliveries =
      for {module, _beam, chunks} <- modules,
          Ash.Signals.Delivery in List.wrap(chunks[:attributes][:behaviour]),
          do: module

    index = %{
      key: nil,
      resources: resources,
      domains: domains,
      callers: callers,
      beams: beams_by_module,
      deliveries: deliveries
    }

    index
    |> Map.put(:bulk_calls, bulk_calls(index) ++ listener_actions(index))
    |> Map.put(:managed_actions, managed_actions(index))
  end

  # An `Ash.Signals` listener runs its action for a whole batch of signals,
  # whichever delivery carries them.
  defp listener_actions(index) do
    if function_exported?(Ash.Resource.Info, :signal_listeners, 1) do
      for resource <- index.resources,
          listener <- Ash.Resource.Info.signal_listeners(resource),
          action = Ash.Resource.Info.action(listener.resource || resource, listener.action),
          action != nil,
          do: {listener.resource || resource, action.type, action.name}
    else
      []
    end
  end

  defp uses(index, module) do
    Enum.flat_map(index.resources, fn resource ->
      global =
        if Enum.any?(Ash.Resource.Info.changes(resource), &entry?(&1, module)) or
             Enum.any?(Ash.Resource.Info.validations(resource), &entry?(&1, module)),
           do: [{:global, resource}],
           else: []

      actions =
        for action <- Ash.Resource.Info.actions(resource),
            action.type in [:create, :update, :destroy],
            Enum.any?(Map.get(action, :changes, []), &entry?(&1, module)),
            do: {:action, resource, action}

      global ++ actions
    end)
  end

  defp entry?(%{change: {module, _opts}}, module), do: true
  defp entry?(%{validation: {module, _opts}}, module), do: true
  defp entry?(_entry, _module), do: false

  defp bulk?(_index, {:global, _resource}), do: true

  defp bulk?(index, {:action, resource, action}) do
    Map.get(action, :primary?, false) or
      MapSet.member?(index.managed_actions, action.name) or
      Enum.any?(index.bulk_calls, &bulk_call_names?(&1, resource, action)) or
      interface_called_in_bulk?(index, resource, action)
  end

  defp bulk_call_names?({call_resource, type, name}, resource, action) do
    type == action.type and call_resource in [:any, resource] and name in [:any, action.name]
  end

  ## Ash's bulk API

  # A domain generates its own `bulk_update/4` and friends, passing straight to
  # `Ash`: a call through the domain counts, the domain's own call does not. An
  # `Ash.Signals.Delivery` runs listener actions, counted from the listeners.
  defp bulk_calls(index) do
    apis = [Ash | index.domains]

    callers =
      for api <- apis, fun <- Map.keys(@bulk_api), reduce: MapSet.new() do
        acc -> MapSet.union(acc, callers_of(index, api, fun))
      end

    for caller <- MapSet.difference(callers, MapSet.new(index.domains ++ index.deliveries)),
        definitions = definitions(index, caller),
        {key, kind, clauses} <- definitions,
        {_meta, params, _guards, body} <- clauses,
        call <-
          remote_calls(body, &(elem(&1, 0) in apis and Map.has_key?(@bulk_api, elem(&1, 1)))),
        ctx = context(index, definitions, key, kind, params, body),
        entry <- bulk_call(call, ctx),
        do: own_resource(entry, caller, index)
  end

  defp context(index, definitions, key, kind, params, body) do
    %{
      index: index,
      definitions: definitions,
      key: key,
      kind: kind,
      params: params,
      body: body,
      depth: 0
    }
  end

  # An embedded resource's generated array handling bulk-destroys its own
  # records through a variable; in a resource, an unnamed resource is itself.
  defp own_resource({:any, type, action}, caller, index) do
    if caller in index.resources, do: {caller, type, action}, else: {:any, type, action}
  end

  defp own_resource(call, _caller, _index), do: call

  defp bulk_call({{:., _, [_api, fun]}, _, args}, ctx) do
    type = @bulk_api[fun]

    {resources, actions} =
      case {fun, args} do
        {create, [_inputs, resource, action | _]} when create in [:bulk_create, :bulk_create!] ->
          {resources_of(resource, ctx), possible_atoms(action, ctx)}

        {many, [_inputs, resource, action | _]} when many in [:update_many, :update_many!] ->
          {resources_of(resource, ctx), possible_atoms(action, ctx)}

        {_update_or_destroy, [subject, action | rest]} ->
          {subject_resources(subject, rest, ctx), possible_atoms(action, ctx)}

        _other ->
          {[:any], :any}
      end

    for resource <- resources, action <- any_or_list(actions), do: {resource, type, action}
  end

  defp any_or_list(:any), do: [:any]
  defp any_or_list({:atoms, atoms}), do: MapSet.to_list(atoms)

  # The resources an expression can name; `[:any]` when it can be any.
  defp resources_of(expr, ctx) do
    case possible_atoms(expr, ctx) do
      :any ->
        [:any]

      {:atoms, atoms} ->
        case Enum.filter(atoms, &(&1 in ctx.index.resources)) do
          [] -> [:any]
          resources -> resources
        end
    end
  end

  defp subject_resources(subject, rest, ctx) do
    opts_resources =
      Enum.find_value(rest, fn
        opts when is_list(opts) ->
          Keyword.keyword?(opts) && opts[:resource] && resources_of(opts[:resource], ctx)

        _other ->
          nil
      end)

    case {opts_resources, resources_in(subject, ctx.index)} do
      {[_ | _] = resources, _subject} when resources != [:any] -> resources
      {_opts, [_ | _] = resources} -> resources
      _unknown -> [:any]
    end
  end

  defp resources_in(ast, index) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        atom, acc when is_atom(atom) ->
          {atom, if(atom in index.resources, do: [atom | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(found)
  end

  ## Actions Ash runs in bulk on another resource's behalf

  defp managed_actions(index) do
    from_resources =
      for resource <- index.resources,
          action <- Ash.Resource.Info.actions(resource),
          %{change: {module, opts}} <-
            Map.get(action, :changes, []) ++ Ash.Resource.Info.changes(resource),
          name <- named_actions(module, opts),
          do: name

    from_code =
      for caller <- callers_of(index, Ash.Changeset, :manage_relationship),
          {_key, _kind, clauses} <- definitions(index, caller),
          {_meta, _args, _guards, body} <- clauses,
          {_call, _meta, [_changeset, _relationship, _input, opts | _]} <-
            remote_calls(body, &(&1 == {Ash.Changeset, :manage_relationship})),
          name <- atoms(opts),
          do: name

    MapSet.new(from_resources ++ from_code)
  end

  defp named_actions(module, opts) when module in @cascades, do: List.wrap(opts[:action])

  defp named_actions(Ash.Resource.Change.ManageRelationship, opts), do: atoms(opts[:opts])
  defp named_actions(_module, _opts), do: []

  defp atoms(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        atom, acc when is_atom(atom) and atom not in [nil, true, false] -> {atom, [atom | acc]}
        node, acc -> {node, acc}
      end)

    found
  end

  ## Code interfaces

  defp interface_called_in_bulk?(index, resource, action) do
    resource
    |> interfaces(index, action)
    |> Enum.any?(fn {module, interface} ->
      [interface.name, :"#{interface.name}!"]
      |> Enum.flat_map(&(index |> callers_of(module, &1) |> MapSet.to_list()))
      |> Enum.uniq()
      |> Enum.any?(&caller_in_bulk?(index, &1, module, interface, action))
    end)
  end

  defp interfaces(resource, index, action) do
    own =
      for %{__struct__: Ash.Resource.Interface} = interface <-
            Ash.Resource.Info.interfaces(resource),
          do: {resource, interface}

    domain =
      for domain <- index.domains,
          reference <- Ash.Domain.Info.resource_references(domain),
          reference.resource == resource,
          %{__struct__: Ash.Resource.Interface} = interface <- reference.definitions,
          do: {domain, interface}

    Enum.filter(own ++ domain, fn {_module, interface} ->
      (interface.action || interface.name) == action.name
    end)
  end

  defp caller_in_bulk?(index, caller, module, interface, action) do
    definitions = definitions(index, caller)
    names = [interface.name, :"#{interface.name}!"]
    target? = &(elem(&1, 0) == module and elem(&1, 1) in names)

    # An unreadable caller is a caller we cannot clear.
    definitions == [] or
      Enum.any?(definitions, fn {key, kind, clauses} ->
        Enum.any?(clauses, fn {_meta, params, _guards, body} ->
          ctx = %{
            definitions: definitions,
            key: key,
            kind: kind,
            params: params,
            body: body,
            index: index,
            depth: 0
          }

          body
          |> classified_calls(target?, &subject_cardinality(&1, interface, action, ctx))
          |> Enum.any?(&(&1 != :one))
        end)
      end)
  end

  # A get interface finds its one record; a create's params follow its named
  # arguments, an update's or destroy's subject comes first.
  defp subject_cardinality({_call, _meta, args}, interface, action, ctx) do
    cond do
      get_interface?(interface) ->
        :one

      action.type == :create ->
        args |> Enum.drop(length(interface.args || [])) |> params_cardinality(ctx)

      true ->
        subject_arg_cardinality(args, ctx)
    end
  end

  defp get_interface?(interface),
    do: interface.get? or interface.get_by not in [nil, []] or interface.get_by_identity != nil

  defp subject_arg_cardinality([subject | _], ctx), do: cardinality(subject, ctx)
  defp subject_arg_cardinality([], _ctx), do: :unknown

  defp params_cardinality([], _ctx), do: :one
  defp params_cardinality([params | _], ctx), do: given_params_cardinality(params, ctx)

  defp given_params_cardinality(params, _ctx) when is_list(params),
    do: if(params == [] or Keyword.keyword?(params), do: :one, else: :many)

  defp given_params_cardinality(params, ctx), do: cardinality(params, ctx)

  # Each target call in `body` classified, either by how its result is handled
  # or by `classify`: a call whose result a `case`, `with` or match takes as
  # `{:ok, record}` runs on one record.
  defp classified_calls(body, target?, classify) do
    {_ast, {found, _handled}} =
      Macro.prewalk(body, {[], MapSet.new()}, fn node, {found, handled} ->
        cond do
          single_result_use?(node, target?) ->
            call = used_call(node)
            {node, {[:one | found], MapSet.put(handled, call_id(call))}}

          target_call?(node, target?) and not MapSet.member?(handled, call_id(node)) ->
            {node, {[classify.(node) | found], handled}}

          true ->
            {node, {found, handled}}
        end
      end)

    found
  end

  defp call_id({_call, meta, _args}), do: {meta[:line], meta[:column], meta[:counter]}

  defp target_call?({{:., _, [module, fun]}, _, args}, target?) when is_list(args),
    do: target?.({module, fun})

  defp target_call?(_node, _target?), do: false

  defp single_result_use?({:case, _, [call, [do: clauses]]}, target?) when is_list(clauses),
    do: target_call?(call, target?) and ok_clause?(Enum.map(clauses, &clause_pattern/1))

  defp single_result_use?({op, _, [pattern, call]}, target?) when op in [:=, :<-],
    do: target_call?(call, target?) and ok_pattern?(pattern)

  defp single_result_use?(_node, _target?), do: false

  defp used_call({:case, _, [call, _]}), do: call
  defp used_call({_op, _, [_pattern, call]}), do: call

  defp clause_pattern({:->, _, [[{:when, _, [pattern | _]}], _body]}), do: pattern
  defp clause_pattern({:->, _, [[pattern], _body]}), do: pattern
  defp clause_pattern(_clause), do: nil

  defp ok_clause?(patterns),
    do: Enum.any?(patterns, &ok_pattern?/1) and not Enum.any?(patterns, &bulk_result_pattern?/1)

  defp ok_pattern?({:ok, _record}), do: true
  defp ok_pattern?({:{}, _, [:ok, _record | _]}), do: true
  defp ok_pattern?({:=, _, [left, right]}), do: ok_pattern?(left) or ok_pattern?(right)
  defp ok_pattern?(_pattern), do: false

  defp bulk_result_pattern?({:%, _, [Ash.BulkResult, _]}), do: true

  defp bulk_result_pattern?({:=, _, [left, right]}),
    do: bulk_result_pattern?(left) or bulk_result_pattern?(right)

  defp bulk_result_pattern?(_pattern), do: false

  ## How many records a value holds

  defp cardinality({:%{}, _, _}, _ctx), do: :one
  defp cardinality({:%, _, [Ash.Query, _]}, _ctx), do: :many
  defp cardinality({:%, _, [_struct, _]}, _ctx), do: :one
  defp cardinality(value, _ctx) when is_binary(value) or is_integer(value), do: :one
  defp cardinality([], _ctx), do: :one

  defp cardinality(list, _ctx) when is_list(list),
    do: if(Keyword.keyword?(list), do: :one, else: :many)

  defp cardinality({:for, _, _}, _ctx), do: :many

  defp cardinality({:__block__, _, [_ | _] = statements}, ctx),
    do: cardinality(List.last(statements), ctx)

  defp cardinality({{:., _, [module, fun]}, _, args}, ctx) when is_atom(module) and is_list(args),
    do: call_cardinality(module, fun, args, ctx)

  defp cardinality({name, _, context}, ctx) when is_atom(name) and is_atom(context),
    do: variable_cardinality(name, ctx)

  defp cardinality(_value, _ctx), do: :unknown

  defp call_cardinality(module, fun, _args, _ctx) when module in [Enum, Stream],
    do: if(fun in @one_element, do: :one, else: :many)

  defp call_cardinality(List, fun, _args, _ctx) when fun in @one_element_list, do: :one
  defp call_cardinality(:erlang, :hd, _args, _ctx), do: :one

  defp call_cardinality(module, _fun, _args, _ctx) when module in [List, :lists, Ash.Query, Map],
    do: :many

  defp call_cardinality(Ash, fun, _args, _ctx) when fun in [:read, :read!, :stream!], do: :many

  defp call_cardinality(Ash, fun, _args, _ctx)
       when fun in [
              :get,
              :get!,
              :read_one,
              :read_one!,
              :read_first,
              :read_first!,
              :create!,
              :update!
            ],
       do: :one

  defp call_cardinality(Ash, fun, [subject | _], ctx) when fun in [:load, :load!],
    do: cardinality(subject, ctx)

  defp call_cardinality(module, fun, _args, ctx), do: read_interface_cardinality(module, fun, ctx)

  # What `{:ok, value}` holds when matched against the call's result.
  defp result_cardinality({:ok, value}, ctx), do: cardinality(value, ctx)

  defp result_cardinality({{:., _, [Ash, fun]}, _, _args}, _ctx) when fun in [:read, :read_page],
    do: :many

  defp result_cardinality({{:., _, [Ash, fun]}, _, _args}, _ctx)
       when fun in [:get, :read_one, :read_first, :create, :update, :destroy],
       do: :one

  defp result_cardinality({{:., _, [module, fun]}, _, args}, ctx)
       when is_atom(module) and is_list(args),
       do: read_interface_cardinality(module, fun, ctx)

  defp result_cardinality({:__block__, _, [_ | _] = statements}, ctx),
    do: result_cardinality(List.last(statements), ctx)

  defp result_cardinality(_value, _ctx), do: :unknown

  defp read_interface_cardinality(module, fun, %{index: index}) do
    cond do
      module in index.resources ->
        interface_read_cardinality(Ash.Resource.Info.interfaces(module), module, fun)

      module in index.domains ->
        domain_read_cardinality(module, fun)

      true ->
        :unknown
    end
  end

  defp domain_read_cardinality(domain, fun) do
    domain
    |> Ash.Domain.Info.resource_references()
    |> Enum.find_value(:unknown, fn reference ->
      case interface_read_cardinality(reference.definitions, reference.resource, fun) do
        :unknown -> nil
        cardinality -> cardinality
      end
    end)
  end

  defp interface_read_cardinality(interfaces, resource, fun) do
    with %{__struct__: Ash.Resource.Interface} = interface <-
           Enum.find(interfaces, &(Map.get(&1, :name) == fun or :"#{Map.get(&1, :name)}!" == fun)),
         %{type: :read} = action <-
           Ash.Resource.Info.action(resource, interface.action || interface.name) do
      if interface.get? or interface.get_by not in [nil, []] or interface.get_by_identity != nil or
           Map.get(action, :get?, false),
         do: :one,
         else: :many
    else
      %{type: type} when type in [:create, :update, :destroy] -> :one
      _ -> :unknown
    end
  end

  ## Variables

  defp variable_cardinality(name, %{depth: depth}) when depth > @max_depth or name == :_,
    do: :unknown

  defp variable_cardinality(name, ctx) do
    param_bindings =
      for {param, position} <- Enum.with_index(ctx.params),
          binds?(param, name),
          do: {:param, position, param}

    (param_bindings ++ body_bindings(ctx.body, name))
    |> Enum.map(&binding_cardinality(&1, name, ctx))
    |> combine()
  end

  defp combine([]), do: :unknown

  defp combine(cardinalities) do
    cond do
      :many in cardinalities -> :many
      Enum.all?(cardinalities, &(&1 == :one)) -> :one
      true -> :unknown
    end
  end

  defp binding_cardinality({:match, pattern, value}, name, ctx) do
    case relation(pattern, name) do
      :direct -> cardinality(value, deeper(ctx))
      :ok -> result_cardinality(value, deeper(ctx))
      known -> known
    end
  end

  defp binding_cardinality({:element, pattern, collection}, name, _ctx) do
    cond do
      chunked?(collection) -> :many
      relation(pattern, name) in [:direct, :element] -> :one
      true -> :unknown
    end
  end

  defp binding_cardinality({:lambda, collection, _element?}, _name, _ctx),
    do: if(chunked?(collection), do: :many, else: :one)

  defp binding_cardinality({:param, position, pattern}, name, ctx) do
    case relation(pattern, name) do
      relation when relation in [:direct, :ok] -> traced_param(ctx, position, relation)
      known -> known
    end
  end

  defp deeper(ctx), do: %{ctx | depth: ctx.depth + 1}

  # A private function's parameter holds what its callers in the module pass.
  defp traced_param(%{kind: :defp, key: {name, arity}} = ctx, position, relation) do
    sites =
      for {key, kind, clauses} <- ctx.definitions,
          {_meta, params, _guards, body} <- clauses,
          {^name, _meta, args} <- local_calls(body, name, arity),
          {arg, ^position} <- Enum.with_index(args) do
        site_ctx = %{ctx | key: key, kind: kind, params: params, body: body, depth: ctx.depth + 1}

        if relation == :ok,
          do: result_cardinality(arg, site_ctx),
          else: cardinality(arg, site_ctx)
      end

    combine(sites)
  end

  defp traced_param(_ctx, _position, _relation), do: :unknown

  defp local_calls(body, name, arity) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {^name, _meta, args} = node, acc when is_list(args) and length(args) == arity ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # How a pattern binds `name`: the whole value, the record in `{:ok, record}`,
  # one element of a list, or something only the pattern itself says.
  defp relation({name, _, context}, name) when is_atom(context), do: :direct

  defp relation({:=, _, [left, right]}, name) do
    cond do
      direct?(left, name) -> shape(right) || relation(right, name)
      direct?(right, name) -> shape(left) || relation(left, name)
      true -> known([relation(left, name), relation(right, name)])
    end
  end

  defp relation({:ok, value}, name),
    do: if(direct?(value, name), do: :ok, else: nested(value, name))

  defp relation({:{}, _, [:ok, value | _]}, name),
    do: if(direct?(value, name), do: :ok, else: :unknown)

  defp relation(list, name) when is_list(list) do
    if Enum.any?(list, &element?(&1, name)), do: :element, else: nested(list, name)
  end

  defp relation(pattern, name), do: nested(pattern, name)

  defp nested(pattern, name), do: if(binds?(pattern, name), do: :unknown, else: nil)

  defp known(relations), do: Enum.find(relations, :unknown, &(&1 not in [nil, :unknown]))

  defp element?({:|, _, [head, _tail]}, name), do: direct?(head, name)
  defp element?(element, name), do: direct?(element, name)

  defp direct?({name, _, context}, name) when is_atom(context), do: true
  defp direct?(_pattern, _name), do: false

  defp shape({:%, _, [Ash.Query, _]}), do: :many
  defp shape({:%, _, [_struct, _]}), do: :one
  defp shape({:%{}, _, _}), do: :one
  defp shape(list) when is_list(list) and list != [], do: :many
  defp shape(_pattern), do: nil

  defp binds?(pattern, name) do
    {_ast, found?} =
      Macro.prewalk(pattern, false, fn
        {:^, _, _}, acc -> {nil, acc}
        {^name, _, context} = node, _acc when is_atom(context) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  # Every place the body binds `name`, with what it is bound to.
  defp body_bindings(body, name) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:for, _, args} = node, acc when is_list(args) ->
          {node,
           for(
             {:<-, _, [pattern, collection]} <- args,
             binds?(pattern, name),
             do: {:element, pattern, collection}
           ) ++ acc}

        {:case, _, [value, [do: clauses]]} = node, acc when is_list(clauses) ->
          {node,
           for(
             clause <- clauses,
             pattern = clause_pattern(clause),
             binds?(pattern, name),
             do: {:match, pattern, value}
           ) ++ acc}

        {:with, _, args} = node, acc when is_list(args) ->
          {node,
           for(
             {:<-, _, [pattern, value]} <- args,
             binds?(pattern, name),
             do: {:match, pattern, value}
           ) ++ acc}

        {:=, _, [pattern, value]} = node, acc ->
          {node, if(binds?(pattern, name), do: [{:match, pattern, value} | acc], else: acc)}

        {{:., _, [module, _fun]}, _, [collection | rest]} = node, acc
        when module in [Enum, Stream] ->
          {node, lambda_bindings(rest, name, collection) ++ acc}

        {:fn, _, clauses} = node, acc ->
          {node, lambda_bindings([{:fn, [], clauses}], name, nil) ++ acc}

        node, acc ->
          {node, acc}
      end)

    # A lambda an `Enum` call iterates with is found twice, the second time
    # without the collection that binds it.
    iterated = for {:lambda, collection, _, clause} <- found, collection != nil, do: clause

    found
    |> Enum.reject(fn
      {:lambda, nil, _element?, clause} -> clause in iterated
      _binding -> false
    end)
    |> Enum.map(fn
      {:lambda, collection, element?, _clause} -> {:lambda, collection, element?}
      binding -> binding
    end)
  end

  # A lambda handed to `Enum` or `Stream` takes one element of the collection
  # as its first parameter.
  defp lambda_bindings(args, name, collection) do
    for {:fn, _, clauses} <- args,
        {:->, _, [params, _body]} = clause <- clauses,
        Enum.any?(params, &binds?(&1, name)),
        do: {:lambda, collection, binds?(List.first(params), name), clause}
  end

  defp chunked?({{:., _, [module, fun]}, _, _args}) when module in [Enum, Stream],
    do: fun in @chunking

  defp chunked?(_collection), do: false

  ## Which atoms a value can be

  # Every atom an action or resource argument can hold, or `:any`. A literal
  # holds the atoms written in it, a variable what each of its bindings holds,
  # a private function's parameter what the module's calls of it pass, and a
  # lambda's element what its collection holds. Over-collecting is safe: an
  # atom that names no action matches nothing.
  defp possible_atoms(atom, _ctx) when is_atom(atom) and atom not in [nil, true, false],
    do: {:atoms, MapSet.new([atom])}

  defp possible_atoms(value, _ctx)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:atoms, MapSet.new()}

  defp possible_atoms(list, ctx) when is_list(list), do: union_atoms(list, ctx)
  defp possible_atoms({left, right}, ctx), do: union_atoms([left, right], ctx)
  defp possible_atoms({:{}, _, elements}, ctx), do: union_atoms(elements, ctx)
  defp possible_atoms({:%{}, _, pairs}, ctx), do: union_atoms(pairs, ctx)

  defp possible_atoms({:__block__, _, [_ | _] = statements}, ctx),
    do: possible_atoms(List.last(statements), ctx)

  defp possible_atoms({name, _, context}, ctx) when is_atom(name) and is_atom(context),
    do: variable_atoms(name, ctx)

  defp possible_atoms(_value, _ctx), do: :any

  defp union_atoms(values, ctx) do
    Enum.reduce_while(values, {:atoms, MapSet.new()}, fn value, {:atoms, acc} ->
      case possible_atoms(value, ctx) do
        :any -> {:halt, :any}
        {:atoms, atoms} -> {:cont, {:atoms, MapSet.union(acc, atoms)}}
      end
    end)
  end

  defp variable_atoms(name, %{depth: depth}) when depth > @max_depth or name == :_, do: :any

  defp variable_atoms(name, ctx) do
    param_bindings =
      for {param, position} <- Enum.with_index(ctx.params),
          binds?(param, name),
          do: {:param, position, param}

    case param_bindings ++ body_bindings(ctx.body, name) do
      [] -> :any
      bindings -> bindings |> Enum.map(&binding_atoms(&1, deeper(ctx))) |> union_results()
    end
  end

  defp union_results(results) do
    if :any in results,
      do: :any,
      else:
        {:atoms,
         Enum.reduce(results, MapSet.new(), fn {:atoms, atoms}, acc ->
           MapSet.union(acc, atoms)
         end)}
  end

  defp binding_atoms({:match, _pattern, value}, ctx), do: possible_atoms(value, ctx)
  defp binding_atoms({:element, _pattern, collection}, ctx), do: possible_atoms(collection, ctx)
  defp binding_atoms({:lambda, nil, _element?}, _ctx), do: :any
  defp binding_atoms({:lambda, collection, true}, ctx), do: possible_atoms(collection, ctx)
  defp binding_atoms({:lambda, _collection, false}, _ctx), do: :any

  defp binding_atoms({:param, position, _pattern}, %{kind: :defp, key: {name, arity}} = ctx) do
    sites =
      for {key, kind, clauses} <- ctx.definitions,
          {_meta, params, _guards, body} <- clauses,
          {^name, _meta, args} <- local_calls(body, name, arity),
          {arg, ^position} <- Enum.with_index(args),
          do:
            possible_atoms(arg, %{
              ctx
              | key: key,
                kind: kind,
                params: params,
                body: body
            })

    if sites == [], do: :any, else: union_results(sites)
  end

  defp binding_atoms({:param, _position, _pattern}, _ctx), do: :any

  ## Compiled modules

  defp callers_of(index, module, fun), do: Map.get(index.callers, {module, fun}, MapSet.new())

  # Read once per module and index: callers are shared by many actions.
  defp definitions(index, module) do
    cache = {__MODULE__, :definitions, index.key, module}

    case :persistent_term.get(cache, nil) do
      nil ->
        definitions = read_definitions(index, module)
        if index.key != nil, do: :persistent_term.put(cache, definitions)
        definitions

      definitions ->
        definitions
    end
  end

  defp read_definitions(index, module) do
    with beam when is_binary(beam) <- Map.get(index.beams, module),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(String.to_charlist(beam), [:debug_info]),
         {:ok, %{definitions: definitions}} <- backend.debug_info(:elixir_v1, module, data, []) do
      for {key, kind, _meta, clauses} <- definitions, do: {key, kind, clauses}
    else
      _ -> []
    end
  end

  defp remote_calls(ast, target?) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {{:., _, [module, fun]}, _, args} = node, acc
        when is_atom(module) and is_atom(fun) and is_list(args) ->
          {node, if(target?.({module, fun}), do: [node | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    found
  end
end
