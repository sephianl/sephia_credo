defmodule SephiaCredo.Checks.MultiStepMutationWithoutTransactionTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.MultiStepMutationWithoutTransaction

  describe "flags 2+ Repo writes in a function" do
    test "two Repo.insert calls in the same function" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.insert(a)
          Repo.insert(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "run/2"
      end)
    end

    test "mixed Repo.insert + Repo.update + Repo.delete" do
      """
      defmodule Sample do
        def run(a, b, c) do
          Repo.insert(a)
          Repo.update(b)
          Repo.delete(c)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "bang variants (insert!, update!, delete!) count" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.insert!(a)
          Repo.update!(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "insert_all / update_all / delete_all count" do
      """
      defmodule Sample do
        def run do
          Repo.insert_all(User, [%{name: "a"}])
          Repo.delete_all(OldThing)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "fully qualified MyApp.Repo.* counts" do
      """
      defmodule Sample do
        def run(a, b) do
          MyApp.Repo.insert(a)
          MyApp.Repo.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "with-statement two writes still counts" do
      """
      defmodule Sample do
        def run(a, b) do
          with {:ok, x} <- Repo.insert(a),
               {:ok, y} <- Repo.insert(b) do
            {:ok, {x, y}}
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end
  end

  describe "does not flag" do
    test "single Repo write" do
      """
      defmodule Sample do
        def run(a) do
          Repo.insert(a)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "writes wrapped in Repo.transaction/1" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.transaction(fn ->
            Repo.insert(a)
            Repo.insert(b)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "writes wrapped in MyApp.Repo.transaction/1" do
      """
      defmodule Sample do
        def run(a, b) do
          MyApp.Repo.transaction(fn ->
            MyApp.Repo.insert(a)
            MyApp.Repo.insert(b)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "Ecto.Multi-based code (no Repo.* writes in body)" do
      """
      defmodule Sample do
        def run(a, b) do
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:a, a)
          |> Ecto.Multi.insert(:b, b)
          |> Repo.transaction()
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "reads only (all, get, one) are not writes" do
      """
      defmodule Sample do
        def run(id) do
          Repo.all(Post)
          Repo.get(User, id)
          Repo.one(Account)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "writes spread across separate functions do not combine" do
      """
      defmodule Sample do
        def a(x), do: Repo.insert(x)
        def b(x), do: Repo.update(x)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end
  end

  describe "excluded_functions param" do
    test "skips functions listed in excluded_functions" do
      """
      defmodule Sample do
        def best_effort_cleanup(a, b) do
          Repo.delete(a)
          Repo.delete(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        excluded_functions: [:best_effort_cleanup]
      )
      |> refute_issues()
    end

    test "still flags non-excluded functions in the same module" do
      """
      defmodule Sample do
        def best_effort_cleanup(a, b) do
          Repo.delete(a)
          Repo.delete(b)
        end

        def main(a, b) do
          Repo.insert(a)
          Repo.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        excluded_functions: [:best_effort_cleanup]
      )
      |> assert_issue(fn issue ->
        assert issue.trigger == "main/2"
      end)
    end
  end

  describe "mixed transaction / non-transaction" do
    test "flags writes outside the transaction even if some are inside" do
      """
      defmodule Sample do
        def run(a, b, c) do
          Repo.transaction(fn ->
            Repo.insert(a)
            Repo.insert(b)
          end)

          Repo.insert(c)
          Repo.update(c)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end
  end

  describe "direct Ash.* mutations" do
    test "flags Ash.create + Ash.update" do
      """
      defmodule Sample do
        def run(a, b) do
          Ash.create(a)
          Ash.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "flags bang variants Ash.create! + Ash.destroy!" do
      """
      defmodule Sample do
        def run(a, b) do
          Ash.create!(a)
          Ash.destroy!(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "flags Ash bulk operations" do
      """
      defmodule Sample do
        def run(records) do
          Ash.bulk_create(records, Resource, :create)
          Ash.bulk_destroy(records, :destroy, %{})
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "mixes Repo + Ash for the 2-count threshold" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.insert(a)
          Ash.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "does not flag Ash.read (not a mutation)" do
      """
      defmodule Sample do
        def run(query1, query2) do
          Ash.read(query1)
          Ash.read(query2)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag mutations wrapped in Ash.transaction/2" do
      """
      defmodule Sample do
        def run(a, b) do
          Ash.transaction([Resource], fn ->
            Ash.create(a)
            Ash.update(b)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end
  end

  describe "ash_resources param (code interface mutations)" do
    test "flags Resource.delete + Resource.update when listed in ash_resources" do
      """
      defmodule Sample do
        def run(stop, route) do
          Stop.delete(stop)
          Route.update(route, %{})
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop, Route]
      )
      |> assert_issue()
    end

    test "matches fully-qualified resource module names too" do
      """
      defmodule Sample do
        def run(stop, route) do
          Zelo.Planner.Stop.delete(stop)
          Zelo.Planner.Route.update(route, %{})
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop, Route]
      )
      |> assert_issue()
    end

    test "flags bang and bulk variants on configured resources" do
      """
      defmodule Sample do
        def run(stops, routes) do
          Stop.bulk_destroy(stops)
          Route.update!(routes)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop, Route]
      )
      |> assert_issue()
    end

    test "does not flag if module is not in ash_resources" do
      """
      defmodule Sample do
        def run(a, b) do
          NotAResource.delete(a)
          NotAResource.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop, Route]
      )
      |> refute_issues()
    end

    test "single resource mutation does not flag" do
      """
      defmodule Sample do
        def run(stop) do
          Stop.delete(stop)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop]
      )
      |> refute_issues()
    end

    test "resource mutations inside Ash.transaction do not flag" do
      """
      defmodule Sample do
        def run(stop, route) do
          Ash.transaction([Stop, Route], fn ->
            Stop.delete(stop)
            Route.update(route, %{})
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [Stop, Route]
      )
      |> refute_issues()
    end
  end

  describe "within-file call graph" do
    test "public orchestrator that delegates to two private helpers, each mutating once" do
      """
      defmodule Sample do
        def run(x, y) do
          do_a(x)
          do_b(y)
        end

        defp do_a(x), do: Repo.insert(x)
        defp do_b(y), do: Repo.insert(y)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "run/2"
      end)
    end

    test "transitive: orchestrator calls helper that calls leaf mutator" do
      """
      defmodule Sample do
        def run(x, y) do
          step_one(x)
          step_two(y)
        end

        defp step_one(x), do: leaf_insert(x)
        defp step_two(y), do: leaf_insert(y)
        defp leaf_insert(thing), do: Repo.insert(thing)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "run/2"
      end)
    end

    test "delete_stops shape: public calls private chain reaching Ash code interface mutations" do
      """
      defmodule Sample do
        def delete_stops(stops, current_user) do
          with :ok <- remove_stop(stops, current_user) do
            update_route(stops, current_user)
          end
        end

        defp remove_stop(stops, _user), do: Stop.delete(stops)
        defp update_route(stops, _user), do: Route.update(stops, %{})
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction, ash_resources: [Stop, Route])
      |> assert_issue(fn issue ->
        assert issue.trigger == "delete_stops/2"
      end)
    end

    test "helper called inside Repo.transaction is not counted" do
      """
      defmodule Sample do
        def run(x, y) do
          Repo.transaction(fn ->
            do_a(x)
            do_b(y)
          end)
        end

        defp do_a(x), do: Repo.insert(x)
        defp do_b(y), do: Repo.insert(y)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "single helper called (no other mutations) does not flag the caller" do
      """
      defmodule Sample do
        def run(x), do: do_a(x)
        defp do_a(x), do: Repo.insert(x)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "calls to functions defined elsewhere are not counted" do
      """
      defmodule Sample do
        def run(x, y) do
          unknown_a(x)
          unknown_b(y)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "non-mutating helper does not propagate" do
      """
      defmodule Sample do
        def run(x, y) do
          format(x)
          format(y)
        end

        defp format(t), do: to_string(t)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "mix of direct mutation and mutating helper sums to threshold" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.insert(a)
          do_b(b)
        end

        defp do_b(b), do: Repo.update(b)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "run/2"
      end)
    end

    test "excluded_functions still suppresses orchestrator" do
      """
      defmodule Sample do
        def run(x, y) do
          do_a(x)
          do_b(y)
        end

        defp do_a(x), do: Repo.insert(x)
        defp do_b(y), do: Repo.insert(y)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction, excluded_functions: [:run])
      |> refute_issues()
    end
  end

  describe "mutually exclusive branches" do
    test "does not flag two mutations in separate case branches" do
      """
      defmodule Sample do
        def run(a, b, flag) do
          case flag do
            :a -> Repo.insert(a)
            :b -> Repo.update(b)
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag a case that dispatches to two mutating helpers" do
      """
      defmodule Sample do
        def fix(blocker, level, opts) do
          case level do
            :analyze -> :skip
            :safe -> fix_safe(blocker, opts)
            :override -> fix_override(blocker, opts)
            :force -> :skip
          end
        end

        defp fix_safe(blocker, opts), do: Repo.update(blocker, opts)
        defp fix_override(blocker, opts), do: Repo.delete(blocker, opts)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag two mutations across if/else" do
      """
      defmodule Sample do
        def run(a, b, flag) do
          if flag do
            Repo.insert(a)
          else
            Repo.update(b)
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag two mutations across fn clauses" do
      """
      defmodule Sample do
        def run(a, b) do
          handler = fn
            {:ok, x} -> Repo.insert(x)
            {:error, x} -> Repo.delete(x)
          end

          handler.({:ok, a})
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag multiple mutations in a test file" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        defp wipe! do
          Repo.delete_all(Stop)
          Repo.delete_all(Route)
          Repo.delete_all(Depot)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag a rescue that compensates for the body" do
      """
      defmodule Sample do
        def run(job, input) do
          try do
            do_work(job, input)
          rescue
            error -> record_failure(job, error)
          end
        end

        defp do_work(job, input), do: Repo.insert(%{job: job, input: input})
        defp record_failure(job, error), do: Repo.update(%{job: job, error: error})
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "still flags two mutations inside a try body" do
      """
      defmodule Sample do
        def run(a, b) do
          try do
            Repo.insert(a)
            Repo.update(b)
          rescue
            _ -> :error
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "reads a function-level rescue the same way as an explicit try" do
      """
      defmodule Sample do
        def run(job) do
          do_work(job)
        rescue
          error -> record_failure(job, error)
        end

        defp do_work(job), do: Repo.insert(job)
        defp record_failure(job, error), do: Repo.update(%{job: job, error: error})
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "counts a function-level after, which runs on top of the body" do
      """
      defmodule Sample do
        def run(a, b) do
          Repo.insert(a)
        after
          Repo.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "still flags two mutations sequentially inside one branch" do
      """
      defmodule Sample do
        def run(a, b, flag) do
          case flag do
            :a ->
              Repo.insert(a)
              Repo.update(b)

            :b ->
              :noop
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "still flags a mutation before a branching mutation" do
      """
      defmodule Sample do
        def run(a, b, flag) do
          Repo.insert(a)

          case flag do
            :a -> Repo.update(b)
            :b -> :noop
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "still flags sequential mutations inside a with body" do
      """
      defmodule Sample do
        def run(a, b) do
          with {:ok, x} <- fetch(a) do
            Repo.insert(x)
            Repo.update(b)
          end
        end

        defp fetch(a), do: {:ok, a}
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "does not flag a with whose do and else each mutate once" do
      """
      defmodule Sample do
        def run(a, b) do
          with {:ok, x} <- fetch(a) do
            Repo.insert(x)
          else
            _ -> Repo.update(b)
          end
        end

        defp fetch(a), do: {:ok, a}
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end
  end

  describe "piped calls" do
    test "does not flag a fn piped into Repo.transaction" do
      """
      defmodule Sample do
        def run(a, b) do
          fn ->
            Repo.insert(a)
            Repo.update(b)
          end
          |> Repo.transaction()
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "does not flag a fn piped into MyApp.Repo.transaction" do
      """
      defmodule Sample do
        def run(a, b) do
          fn ->
            Repo.insert(a)
            Repo.update(b)
          end
          |> MyApp.Repo.transaction(timeout: 5_000)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "still flags two piped Repo writes" do
      """
      defmodule Sample do
        def run(a, b) do
          a |> build() |> Repo.insert()
          b |> build() |> Repo.update()
        end

        defp build(x), do: x
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "follows a local mutating helper called through a pipe" do
      """
      defmodule Sample do
        def run(a, b) do
          a |> save()
          b |> save()
        end

        defp save(x), do: Repo.insert(x)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end
  end

  describe "a transaction body bound to a variable" do
    test "does not flag a fn bound to a variable and then transacted" do
      """
      defmodule Sample do
        def run(a, b) do
          fun = fn ->
            Repo.insert(a)
            Repo.update(b)
          end

          Repo.transaction(fun, timeout: 5_000)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "still flags a fn bound to a variable that is never transacted" do
      """
      defmodule Sample do
        def run(a, b) do
          fun = fn ->
            Repo.insert(a)
            Repo.update(b)
          end

          fun.()
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "does not leak the exemption into another function" do
      """
      defmodule Sample do
        def transacted(a, b) do
          fun = fn ->
            Repo.insert(a)
            Repo.update(b)
          end

          Repo.transaction(fun)
        end

        def bare(a, b) do
          fun = fn ->
            Repo.insert(a)
            Repo.update(b)
          end

          fun.()
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "bare/2"
      end)
    end
  end

  describe "local helper arity" do
    test "does not treat a same-named clause of a different arity as mutating" do
      """
      defmodule Sample do
        def run(a, b) do
          save(a, b)
          save(a)
        end

        defp save(x, _y), do: Repo.insert(x)
        defp save(x), do: x
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> refute_issues()
    end

    test "still flags two calls to the same mutating arity" do
      """
      defmodule Sample do
        def run(a, b) do
          save(a, b)
          save(b, a)
        end

        defp save(x, _y), do: Repo.insert(x)
        defp save(x), do: x
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end

    test "counts a helper called at an arity its default arguments cover" do
      """
      defmodule Sample do
        def run(a, b) do
          save(a)
          save(b, force: true)
        end

        defp save(x, _opts \\\\ []), do: Repo.insert(x)
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction)
      |> assert_issue()
    end
  end

  describe "ash_resources param" do
    test "matches resources given as module aliases" do
      """
      defmodule Sample do
        def run(a, b) do
          Stop.destroy(a)
          Route.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction,
        ash_resources: [MyApp.Planner.Stop, MyApp.Planner.Route]
      )
      |> assert_issue()
    end

    test "matches resources given as strings" do
      """
      defmodule Sample do
        def run(a, b) do
          Stop.destroy(a)
          Stop.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction, ash_resources: ["MyApp.Planner.Stop"])
      |> assert_issue()
    end

    test "does not crash on a non-Elixir atom" do
      """
      defmodule Sample do
        def run(a, b) do
          Stop.destroy(a)
          Stop.update(b)
        end
      end
      """
      |> to_source_file()
      |> run_check(MultiStepMutationWithoutTransaction, ash_resources: [:Stop, :stop])
      |> assert_issue()
    end
  end
end
