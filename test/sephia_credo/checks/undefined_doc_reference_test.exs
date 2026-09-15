defmodule SephiaCredo.Checks.UndefinedDocReferenceTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UndefinedDocReference

  describe "flags a reference that names no module" do
    test "a moduledoc pointing at a module that was renamed away" do
      """
      defmodule Zelo.Planner.DockAssigner do
        @moduledoc \"\"\"
        Callers (e.g. `RouteConversion`) must pre-fetch the docks.
        \"\"\"
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issue(fn issue ->
        assert issue.trigger == "RouteConversion"
        assert issue.message =~ "names no module"
      end)
    end

    test "a reference carrying a function and arity" do
      """
      defmodule Zelo.Planner.Snapshot do
        @moduledoc \"\"\"
        See `RouteDiagnostic.Helpers.snapshot_valid?/2` for validity.
        \"\"\"
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issue(fn issue -> assert issue.trigger == "RouteDiagnostic.Helpers" end)
    end

    test "a name inside a raise message" do
      """
      defmodule Zelo.Planner.Builder do
        def build(nil), do: raise(ArgumentError, "`InsertionSolver` requires a depot")
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issue(fn issue -> assert issue.trigger == "InsertionSolver" end)
    end

    test "each distinct name on its own line" do
      """
      defmodule Zelo.Planner.Docs do
        @moduledoc \"\"\"
        Handled by `BulkUpsert` and then `ReorderDiff`.
        \"\"\"
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end

    test "a bare single word carrying an arity, which is unambiguous" do
      """
      defmodule Zelo.Planner.Docs do
        @moduledoc "Taken by `Lock.acquire/2` before the build."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issue(fn issue -> assert issue.trigger == "Lock" end)
    end
  end

  describe "accepts a reference that resolves" do
    test "the full name of a module defined in the project" do
      """
      defmodule Zelo.Planner.Converter do
        @moduledoc "Runs after `Zelo.Planner.Loader`."
      end

      defmodule Zelo.Planner.Loader do
        @moduledoc false
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a suffix of a module defined in the project, the way an alias reads it" do
      """
      defmodule Zelo.Planner.Exvrp.ModelBuilder.Clients do
        @moduledoc false
      end

      defmodule Zelo.Planner.PlanInput.OrderGroups do
        @moduledoc "Shared with `ModelBuilder.Clients`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a module nested inside another, under its full name" do
      """
      defmodule Zelo.Planner.Solver do
        defmodule Params do
          defstruct [:seed]
        end

        @moduledoc "Configured through `Solver.Params`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a mock created by Mox" do
      """
      defmodule Zelo.Support.Mocks do
        Mox.defmock(InsertionSolverMock, for: Zelo.Planner.Mutations.InsertionSolver)

        @moduledoc "Stubs `InsertionSolverMock` against the real implementation."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a mock whose defmock name resolves through an alias in scope" do
      """
      defmodule Zelo.Support.Mocks do
        alias Zelo.Planner.Mutations.InsertionSolverMock

        Mox.defmock(InsertionSolverMock, for: Zelo.Planner.Mutations.InsertionSolver)

        @moduledoc "Swapped in for `Zelo.Planner.Mutations.InsertionSolverMock`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a single bare word, which cannot be told from prose" do
      """
      defmodule Zelo.Planner.Exvrp.Money do
        @moduledoc "`Cost`, `Distance` and `Duration` are all `int64_t` in ex_vrp."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "an all-capitals keyword" do
      """
      defmodule Zelo.Planner.Route do
        @moduledoc "Built from `SUM`s over a `LATERAL` join."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a name with an underscore, which is no alias segment" do
      """
      defmodule Zelo.Planner.Split do
        @moduledoc "A runner with a `DB_POOL_SIZE` of 2 to 5."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a name listed in ignore" do
      """
      defmodule Zelo.Planner.Broadcaster do
        @moduledoc "Broadcasts through `Zelo.TaskSupervisor`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, ignore: ["Zelo.TaskSupervisor"])
      |> refute_issues()
    end

    test "an unquoted module name in prose" do
      """
      defmodule Zelo.Planner.Notes do
        @moduledoc "RouteConversion used to own this, long ago."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a module from a dependency" do
      """
      defmodule Zelo.Planner.Changes do
        @moduledoc "Built with `Credo.Check.Params`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end
  end
end
