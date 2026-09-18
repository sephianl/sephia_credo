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

    test "a name listed in ignore as an unquoted module" do
      """
      defmodule Zelo.Planner.Broadcaster do
        @moduledoc "Broadcasts through `Zelo.TaskSupervisor`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, ignore: [Zelo.TaskSupervisor])
      |> refute_issues()
    end

    test "a proper noun whose capitals spell an acronym" do
      """
      defmodule Zelo.Planner.Store do
        @moduledoc "Backed by `PostgreSQL`, described by `OpenAPI`, queried over `GraphQL`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a camel-cased proper noun with no structural tell" do
      """
      defmodule Zelo.Planner.Notes do
        @moduledoc "Hosted on `GitHub`, typed with `TypeScript`, built on `JavaScript`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
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

  describe "accepts a name registered in a supervision tree" do
    test "a name given to a child spec in the same file" do
      """
      defmodule Zelo.Application do
        @moduledoc "Broadcasts through `Zelo.PubSub`."

        def children do
          [{Phoenix.PubSub, name: Zelo.PubSub}]
        end
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a name registered in one file and referenced from another" do
      [
        """
        defmodule Zelo.WorkersSupervisor do
          def children do
            [{Registry, keys: :unique, name: Zelo.Planner.StopDeletionRegistry}]
          end
        end
        """,
        """
        defmodule Zelo.Planner.StopDeletion.Supervisor do
          @moduledoc "Workers register in `Zelo.Planner.StopDeletionRegistry`."
        end
        """
      ]
      |> Enum.map(&to_source_file/1)
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "a name sharing a child spec with other options" do
      """
      defmodule Zelo.Application do
        @moduledoc "Pooled by `Zelo.Finch`."

        def children do
          [{Finch, name: Zelo.Finch, pools: %{default: [size: 100]}}]
        end
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> refute_issues()
    end

    test "but not a name that is merely described, never registered" do
      """
      defmodule Zelo.Application do
        @moduledoc "Broadcasts through `Zelo.PubSub`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference)
      |> assert_issue(fn issue -> assert issue.trigger == "Zelo.PubSub" end)
    end
  end

  describe "accepts a name defined in a file named by extra_name_paths" do
    @tag :tmp_dir
    test "an Elixir module outside the scanned tree", %{tmp_dir: tmp_dir} do
      migration = Path.join(tmp_dir, "20260914162059_hash_mcp_oauth_secrets.exs")

      File.write!(migration, """
      defmodule Zelo.Repo.Migrations.HashMcpOauthSecrets do
        use Ecto.Migration
      end
      """)

      """
      defmodule Zelo.Mcp.OAuth.OpaqueToken do
        @moduledoc "Backfilled by `Zelo.Repo.Migrations.HashMcpOauthSecrets`."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, extra_name_paths: [Path.join(tmp_dir, "*.exs")])
      |> refute_issues()
    end

    @tag :tmp_dir
    test "a name in a file that is not Elixir at all", %{tmp_dir: tmp_dir} do
      hooks = Path.join(tmp_dir, "hooks.ts")

      File.write!(hooks, """
      import RouteMapHook from "./route_map";

      const hooks = { RouteMapHook };

      export default hooks;
      """)

      """
      defmodule ZeloWeb.Routes.RoutePolylines do
        @moduledoc "Shaped for the `RouteMapHook` rendered by the map."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, extra_name_paths: [hooks])
      |> refute_issues()
    end

    @tag :tmp_dir
    test "but not a name absent from those files", %{tmp_dir: tmp_dir} do
      hooks = Path.join(tmp_dir, "hooks.ts")
      File.write!(hooks, "const hooks = { RouteMapHook };\n")

      """
      defmodule ZeloWeb.Routes.RoutePolylines do
        @moduledoc "Shaped for the `RenamedMapHook` rendered by the map."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, extra_name_paths: [hooks])
      |> assert_issue(fn issue -> assert issue.trigger == "RenamedMapHook" end)
    end

    test "a path that matches nothing is not an error" do
      """
      defmodule ZeloWeb.Routes.RoutePolylines do
        @moduledoc "Shaped for the `RouteMapHook` rendered by the map."
      end
      """
      |> to_source_file()
      |> run_check(UndefinedDocReference, extra_name_paths: ["no/such/dir/*.ts"])
      |> assert_issue(fn issue -> assert issue.trigger == "RouteMapHook" end)
    end
  end
end
