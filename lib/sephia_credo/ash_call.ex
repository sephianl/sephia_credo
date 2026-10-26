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

  @compile {:no_warn_undefined, [Ash.Resource.Info, Ash.Domain.Info, Spark.Dsl]}

  @ash_reads ~w(read read! read_one read_one! read_first read_first! get get! count count!
                exists exists? aggregate aggregate! sum sum! max max! min min! avg avg!
                first first! list list! calculate calculate! load load! stream!)a
  @ash_writes ~w(create create! update update! destroy destroy! bulk_create bulk_create!
                 bulk_update bulk_update! bulk_destroy bulk_destroy! run_action run_action!)a
  @repo_reads ~w(get get! get_by get_by! one one! all exists? aggregate preload stream
                 query query!)a
  @repo_writes ~w(insert insert! update update! delete delete! insert_or_update
                  insert_or_update! insert_all update_all delete_all)a
  @oban_inserts ~w(insert insert! insert_all)a
  @worker_callbacks ~w(new perform backoff timeout __opts__ module_info)a

  defmodule Call do
    @moduledoc "A call that costs a round trip: what it reads as, where it is, and what it does."
    defstruct [:label, :line, :column, :kind, via: nil]
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
      do: classify(expand(mod, module, aliases), mod, fun, meta)

  def remote_call({{:., _, [mod, fun]}, meta, args}, module, aliases)
      when is_atom(fun) and is_list(args),
      do: classify(expand(mod, module, aliases), mod, fun, meta)

  def remote_call(_node, _module, _aliases), do: nil

  defp classify([:Ash], _mod, fun, meta) do
    cond do
      fun in @ash_reads -> call("Ash.#{fun}", meta, :read)
      fun in @ash_writes -> call("Ash.#{fun}", meta, :write)
      true -> nil
    end
  end

  defp classify([:Oban], _mod, fun, meta) when fun in @oban_inserts,
    do: call("Oban.#{fun}", meta, :write)

  defp classify([_ | _] = segments, mod, fun, meta) do
    if List.last(segments) == :Repo,
      do: classify_repo(fun, meta, written(mod)),
      else: classify_interface(Module.concat(segments), fun, meta, written(mod))
  end

  defp classify(_segments, _mod, _fun, _meta), do: nil

  defp classify_repo(fun, meta, name) do
    cond do
      fun in @repo_reads -> call("#{name}.#{fun}", meta, :read)
      fun in @repo_writes -> call("#{name}.#{fun}", meta, :write)
      true -> nil
    end
  end

  defp classify_interface(module, fun, meta, name) do
    case interface_kind(module, fun) || worker_kind(module, fun) do
      nil -> nil
      kind -> call("#{name}.#{fun}", meta, kind)
    end
  end

  # A worker's own functions besides building and running its job are how a
  # project wraps `Oban.insert/2`, so calling one inserts a job.
  defp worker_kind(module, fun) do
    if fun not in @worker_callbacks and Code.ensure_loaded?(module) and
         function_exported?(module, :__opts__, 0) and function_exported?(module, :perform, 1),
       do: :write
  end

  defp written({:__aliases__, _, segments}), do: Enum.map_join(segments, ".", &written_segment/1)
  defp written(_mod), do: "__MODULE__"

  defp written_segment({:__MODULE__, _, _}), do: "__MODULE__"
  defp written_segment(segment), do: Atom.to_string(segment)

  defp call(label, meta, kind),
    do: %Call{label: label, line: meta[:line], column: meta[:column], kind: kind}

  @doc """
  What calling `fun` on `module` does when it is a code interface: `:read`,
  `:write` or `:calculation`; `nil` when it is not one or the module is not
  compiled.
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
      nil -> calculation_interface_kind(resource, fun)
      interface -> action_kind(resource, interface.action || interface.name)
    end
  end

  defp calculation_interface_kind(resource, fun) do
    if Enum.any?(Ash.Resource.Info.calculation_interfaces(resource), &interface_named?(&1, fun)),
      do: :calculation
  end

  defp domain_interface_kind(domain, fun) do
    domain
    |> Ash.Domain.Info.resource_references()
    |> Enum.find_value(fn reference ->
      case Enum.find(reference.definitions, &interface_named?(&1, fun)) do
        %{__struct__: Ash.Resource.Interface} = interface ->
          action_kind(reference.resource, interface.action || interface.name)

        %{__struct__: Ash.Resource.CalculationInterface} ->
          :calculation

        nil ->
          nil
      end
    end)
  end

  defp interface_named?(%{name: name}, fun), do: fun == name or fun == :"#{name}!"

  defp action_kind(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{type: :read} -> :read
      %{type: :action} -> :action
      _write -> :write
    end
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
    defs = definitions(body)

    direct =
      Map.new(defs, fn {key, clauses} ->
        {key, clauses |> calls_in(module, aliases) |> List.first()}
      end)

    reach(defs, direct)
  end

  defp reach(defs, known) do
    next =
      Map.new(defs, fn {key, clauses} ->
        case known[key] do
          nil -> {key, clauses |> local_calls(defs) |> Enum.find_value(&through(&1, known))}
          call -> {key, call}
        end
      end)

    if next == known, do: known, else: reach(defs, next)
  end

  defp through({key, meta}, known) do
    case known[key] do
      nil -> nil
      call -> %{call | via: {key, meta[:line]}}
    end
  end

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

  @doc "The calls to the module's own functions in `ast`, as `{{name, arity}, meta}`."
  def local_calls(ast, defs) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [{name, meta, context}, arity]}]} = node, acc
        when is_atom(name) and is_atom(context) and is_integer(arity) ->
          {node, add_local({name, arity}, meta, defs, acc)}

        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          {node, add_local({name, length(args)}, meta, defs, acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp add_local(key, meta, defs, acc),
    do: if(Map.has_key?(defs, key), do: [{key, meta} | acc], else: acc)

  @doc "Whether a module body `use`s `module`, given as segments."
  def uses?(body, segments) do
    body
    |> statements()
    |> Enum.any?(&match?({:use, _, [{:__aliases__, _, ^segments} | _]}, &1))
  end

  @doc "How a call reads in a message: the call, and the local function it goes through."
  def describe(%Call{label: label, via: nil}), do: "`#{label}`"

  def describe(%Call{label: label, line: line, via: {{name, arity}, _line}}),
    do: "`#{name}/#{arity}`, which reaches `#{label}` (line #{line}),"
end
