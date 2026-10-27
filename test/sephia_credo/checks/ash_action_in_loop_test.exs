defmodule SephiaCredo.Checks.AshActionInLoopTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.AshActionInLoop

  describe "code interfaces" do
    test "flags a resource's update interface inside Enum.each" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels, zone_id) do
          Enum.each(labels, &Label.set_zone(&1, zone_id))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Label.set_zone"
        assert issue.message =~ "Ash.bulk_update"
      end)
    end

    test "flags a read interface inside Enum.reduce_while" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(codes) do
          Enum.reduce_while(codes, {:ok, []}, fn code, {:ok, acc} ->
            case Label.get_by_code(code) do
              {:ok, label} -> {:cont, {:ok, [label | acc]}}
              error -> {:halt, error}
            end
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Label.get_by_code"
        assert issue.message =~ "one query"
      end)
    end

    test "flags the bang variant inside a for comprehension" do
      """
      defmodule Sample do
        def run(codes) do
          for code <- codes, do: SephiaCredo.Fixtures.Label.get_by_code!(code)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a domain interface" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Domain

        def run(labels), do: Enum.map(labels, &Domain.archive_label/1)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.trigger == "Domain.archive_label" end)
    end

    test "recommends update_many for an update with its own input per element" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels), do: Enum.each(labels, &Label.set_zone(&1, &1.zone_id))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.message =~ "`Ash.update_many/4`" end)
    end

    test "ignores calculation and generic action interfaces, which may never query" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels) do
          Enum.map(labels, &Label.upcased(&1))
          Enum.map(labels, fn _label -> Label.ping() end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores an interface on a resource kept in memory" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Note

        def run(notes), do: Enum.map(notes, &Note.touch/1)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "resolves a grouped alias" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.{Domain, Label}

        def run(labels), do: Enum.map(labels, &Label.set_zone(&1, nil))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "ignores a resource function that is not a code interface" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels), do: Enum.map(labels, &Label.spark_dsl_config/0)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores a same-named function on a module that is not a resource" do
      """
      defmodule Sample do
        def run(labels), do: Enum.map(labels, &Helpers.set_zone(&1, nil))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end
  end

  describe "the Ash API and repos" do
    test "flags Ash.update inside Enum.map" do
      """
      defmodule Sample do
        def run(changesets), do: Enum.map(changesets, fn cs -> Ash.update(cs) end)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.trigger == "Ash.update" end)
    end

    test "flags Repo.get inside Stream.map" do
      """
      defmodule Sample do
        def run(ids), do: Stream.map(ids, &MyApp.Repo.get(User, &1))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.trigger == "MyApp.Repo.get" end)
    end

    test "leaves a direct Ash.load or Repo.preload to PreloadInLoop" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, &Ash.load(&1, :posts))
          Enum.map(users, &Repo.preload(&1, :posts))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores the collection a loop iterates over" do
      """
      defmodule Sample do
        def run(query), do: Enum.map(Ash.read!(query), & &1.id)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores a loop over a list literal or module attribute" do
      """
      defmodule Sample do
        @locks [:orders, :stops]

        def run(ids) do
          Enum.each(@locks, &Repo.query!("SELECT pg_advisory_xact_lock($1)", [&1]))
          Enum.map([&actuals/1, &forecasts/1], &Repo.all(&1.(ids)))
          for table <- [:a, :b], do: Repo.one(table)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags Oban.insert inside a loop" do
      """
      defmodule Sample do
        def run(orders), do: Enum.each(orders, &Oban.insert(Job.new(%{id: &1.id})))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.trigger == "Oban.insert" end)
    end

    test "ignores a load once per group" do
      """
      defmodule Sample do
        def run(notifications) do
          notifications
          |> Enum.group_by(& &1.resource)
          |> Enum.flat_map(fn {_resource, group} -> load_group(group) end)
        end

        defp load_group(group), do: Ash.load!(Enum.map(group, & &1.data), :notifier_data)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores loops over fixed collections" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Webhook

        @max_passes 5
        @zones %{a: 1, b: 2}

        def run(ids) do
          Enum.each(1..@max_passes, fn _ -> Ash.read(Thing) end)
          Enum.each(Map.values(@zones), &Ash.get(Zone, &1))
          Enum.each(Webhook.entity_sets(), &Ash.read(Subscription, filter: [set: &1]))
          steps = [:pick, :load, :ship]
          Enum.each(steps, &Ash.update(Step, %{name: &1}))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags a loop over what a function returns from data" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Webhook

        def run(company), do: Enum.each(Webhook.subscribed(company), &Ash.read(Subscription, filter: [set: &1]))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a loop over a variable another function binds to a list literal" do
      """
      defmodule Sample do
        def empty, do: (labels = []; labels)
        def run(labels), do: Enum.each(labels, &Ash.update!(&1, %{}))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a loop over a variable rebound to what a query returns" do
      """
      defmodule Sample do
        def run(query) do
          labels = []
          labels = Ash.read!(query)
          Enum.each(labels, &Ash.update!(&1, %{}))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a loop over a list built with a tail" do
      """
      defmodule Sample do
        def run(first, rest) do
          Enum.each([first | rest], &Ash.update!(&1, %{}))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "counts only the function of Stream.resource that produces elements" do
      """
      defmodule Sample do
        def run(query) do
          Stream.resource(
            fn -> Ash.read!(query) end,
            fn rows -> {Enum.map(rows, & &1.id), Ash.read!(query)} end,
            fn _rows -> Repo.query!("SELECT 1") end
          )
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.line_no == 5 end)
    end

    test "ignores an element that carries its own query" do
      """
      defmodule Sample do
        def count_all(specs, opts) do
          Task.async_stream(specs, fn {key, query_fun} -> {key, Ash.count(query_fun.(), opts)} end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores a lazy load, which only queries for what is missing" do
      """
      defmodule Sample do
        def run(routes), do: Enum.map(routes, &step(&1))

        defp step(route), do: Ash.load(route, :stops, lazy?: true)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores a code interface run as a bulk action per group" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(levels, opts) do
          Enum.each(levels, fn level ->
            Label.set_zone(level, nil, [bulk_options: [batch_size: 100]] ++ opts)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags a worker function with a default argument, called without it" do
      """
      defmodule Sample do
        def run(parcels), do: Enum.each(parcels, &SephiaCredo.Fixtures.DefaultArgJob.enqueue(&1))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.message =~ "Oban.insert_all" end)
    end

    test "ignores one insert per job for a worker that sets unique" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.UniqueJob

        def run(ids) do
          Enum.each(ids, &UniqueJob.enqueue(%{id: &1}))
          Enum.each(ids, &Oban.insert(UniqueJob.new(%{id: &1})))
          for id <- ids, do: %{id: id} |> UniqueJob.new() |> Oban.insert!()
          Enum.each(ids, &enqueue/1)
        end

        defp enqueue(id), do: Oban.insert(UniqueJob.new(%{id: id}))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags one insert per job for a worker without unique" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.{DefaultArgJob, EmailJob}

        def run(ids) do
          Enum.each(ids, &Oban.insert(EmailJob.new(%{id: &1})))
          Enum.each(ids, &Oban.insert(DefaultArgJob.new(%{id: &1})))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
        assert Enum.all?(issues, &(&1.message =~ "`Oban.insert_all/2`"))
      end)
    end

    test "recommends one statement for raw SQL" do
      """
      defmodule Sample do
        def run(ways), do: Enum.map(ways, &Repo.query!("SELECT crossings($1)", [&1]))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.message =~ "`= ANY($1)`" end)
    end

    test "ignores one bulk call per chunk" do
      """
      defmodule Sample do
        def run(rows) do
          rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(Row, &1))
          rows |> Enum.chunk_every(500) |> Enum.each(&Ash.bulk_create(&1, Row, :create))
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores a call outside any loop" do
      """
      defmodule Sample do
        def run(changesets), do: Ash.bulk_update(changesets, :archive, %{})
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end
  end

  describe "local functions" do
    test "flags a private function that writes, called once per element" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels, opts), do: Enum.each(labels, &mark_missing(&1, opts))

        defp mark_missing(label, opts) do
          case Label.set_zone(label, nil, opts) do
            {:ok, _} -> :ok
            error -> error
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue ->
        assert issue.line_no == 4
        assert issue.trigger == "mark_missing"
        assert issue.message =~ "`mark_missing/2` reaches `Label.set_zone` (line 7)"
      end)
    end

    test "follows a chain of local functions" do
      """
      defmodule Sample do
        def run(ids), do: Enum.map(ids, fn id -> outer(id) end)

        defp outer(id), do: id |> inner()
        defp inner(id), do: Ash.get(Thing, id)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue ->
        assert issue.message =~ "`outer/1` reaches `Ash.get` (line 5)"
      end)
    end

    test "flags a captured local function" do
      """
      defmodule Sample do
        def run(ids), do: Enum.map(ids, &fetch/1)

        defp fetch(id), do: Ash.get(Thing, id)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a lambda handed to a local function that calls it per element" do
      """
      defmodule Reconcile do
        alias SephiaCredo.Fixtures.Label

        defp set_zones(labels, zone_id) do
          reduce_ok(labels, fn label ->
            with {:ok, _} <- Label.set_zone(label, zone_id), do: :ok
          end)
        end

        defp reduce_ok(enumerable, fun) do
          Enum.reduce_while(enumerable, :ok, fn element, :ok ->
            case fun.(element) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.line_no == 6 end)
    end

    test "ignores a lambda handed to a local function that calls it once" do
      """
      defmodule Sample do
        def run(label), do: once(fn -> Ash.update(label) end)

        defp once(fun), do: fun.()
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "only follows the clauses a literal argument can match" do
      """
      defmodule ListRoutes do
        def collapse_others(socket, expanded, keep_id) do
          Enum.reduce(expanded, socket, fn
            ^keep_id, acc -> acc
            other_id, acc -> toggle(acc, other_id, true)
          end)
        end

        defp toggle(socket, id, true), do: Map.delete(socket, id)
        defp toggle(socket, id, false), do: Ash.load(socket.route, :stops) && Map.put(socket, id, true)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "reports a helper's loop once, at the helper" do
      """
      defmodule Sample do
        def run(orders), do: Enum.each(orders, &create_expected(&1.codes))

        defp create_expected(codes), do: Enum.each(codes, &Ash.create(Expected, %{code: &1}))
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue(fn issue -> assert issue.line_no == 4 end)
    end

    test "ignores a private function that does not reach a query" do
      """
      defmodule Sample do
        def run(labels), do: Enum.map(labels, &code/1)

        defp code(label), do: label.code
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "reports a call in nested loops once" do
      """
      defmodule Sample do
        def run(groups) do
          Enum.each(groups, fn group -> Enum.each(group, &Ash.destroy!/1) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end
  end

  describe "comprehensions that define code" do
    test "ignores a comprehension that generates a test per element" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        alias SephiaCredo.Fixtures.Label

        @writers [:admin]

        for role <- actor_roles() -- @writers do
          @tag role: role
          test "rejects \#{role}", %{label: label} do
            actor = create_actor(unquote(role))
            assert {:error, _} = Label.set_zone(label, nil, actor: actor)
          end
        end

        describe "per role" do
          for role <- actor_roles() do
            test "reads as \#{role}", %{label: label} do
              assert {:ok, _} = Label.get_by_code(label.code, actor: unquote(role))
            end
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(AshActionInLoop, include_tests: true)
      |> refute_issues()
    end

    test "ignores a comprehension that generates a function per element" do
      """
      defmodule Sample do
        for table <- tables() do
          def unquote(:"count_\#{table}")(), do: Repo.aggregate(unquote(table), :count)
        end
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags a loop inside a generated test" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        alias SephiaCredo.Fixtures.Label

        for role <- actor_roles() do
          test "moves every label as \#{role}", %{labels: labels} do
            Enum.each(labels, &Label.set_zone(&1, nil, actor: unquote(role)))
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(AshActionInLoop, include_tests: true)
      |> assert_issue(fn issue -> assert issue.trigger == "Label.set_zone" end)
    end

    test "flags a comprehension calling a function that shares a definition's name" do
      """
      defmodule Sample do
        alias SephiaCredo.Fixtures.Label

        def run(labels, actor) do
          for label <- labels do
            test(label, actor)
          end
        end

        defp test(label, actor), do: Label.set_zone(label, nil, actor: actor)
      end
      """
      |> to_source_file()
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end
  end

  describe "test code" do
    @fixture_loop """
    defmodule SampleTest do
      alias SephiaCredo.Fixtures.Label

      setup %{labels: labels} do
        Enum.each(labels, &Label.set_zone(&1, nil))
        :ok
      end
    end
    """

    test "ignores a test file" do
      @fixture_loop
      |> to_source_file("test/my_app/sample_test.exs")
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "ignores test support code" do
      @fixture_loop
      |> to_source_file("test/support/factory.ex")
      |> run_check(AshActionInLoop)
      |> refute_issues()
    end

    test "flags the same loop in lib" do
      @fixture_loop
      |> to_source_file("lib/my_app/sample.ex")
      |> run_check(AshActionInLoop)
      |> assert_issue()
    end

    test "flags a test file with include_tests" do
      @fixture_loop
      |> to_source_file("test/my_app/sample_test.exs")
      |> run_check(AshActionInLoop, include_tests: true)
      |> assert_issue()
    end
  end
end
