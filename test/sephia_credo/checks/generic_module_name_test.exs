defmodule SephiaCredo.Checks.GenericModuleNameTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.GenericModuleName

  describe "flags a name that says nothing where it is used" do
    test "a nested Result module" do
      """
      defmodule Zelo.Planner.Mutations.ReorderStopsSolver.Result do
        defstruct [:route, :saving]
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Result"
        assert issue.message =~ "alias Zelo.Planner.Mutations.ReorderStopsSolver.Result"
      end)
    end

    test "a nested Input module" do
      """
      defmodule Zelo.Planner.Mutations.ReorderStopsSolver.Input do
        defstruct [:stops]
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issue(fn issue -> assert issue.trigger == "Input" end)
    end

    test "a behaviour implementation named by its behaviour" do
      """
      defmodule Zelo.Planner.Mutations.InsertionSolverImplementation do
        @behaviour Zelo.Planner.Mutations.InsertionSolver
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issue(fn issue ->
        assert issue.trigger == "InsertionSolverImplementation"
        assert issue.message =~ "Implementation"
      end)
    end

    test "a Helpers grab bag" do
      """
      defmodule Zelo.Planner.Helpers do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issue(fn issue -> assert issue.trigger == "Helpers" end)
    end

    test "a module nested inside another module body" do
      """
      defmodule Zelo.Planner.Solver do
        defmodule Result do
          defstruct [:routes]
        end
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issue(fn issue -> assert issue.trigger == "Result" end)
    end

    test "every generic module in a file" do
      """
      defmodule Zelo.Planner.Solver.Input do
      end

      defmodule Zelo.Planner.Solver.Output do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issues(fn issues -> assert Enum.count(issues) == 2 end)
    end
  end

  describe "does not flag" do
    test "a name that stands alone" do
      """
      defmodule Zelo.Planner.ReorderedRoute do
        defstruct [:route, :saving]
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end

    test "framework names, where the convention carries the meaning" do
      """
      defmodule MyApp.Application do
      end

      defmodule MyApp.Repo do
      end

      defmodule MyAppWeb.Endpoint do
      end

      defmodule MyAppWeb.Router do
      end

      defmodule MyAppWeb.CoreComponents do
      end

      defmodule MyApp.Telemetry do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end

    test "a longer word that merely contains a denylisted one in lower case" do
      """
      defmodule MyApp.Database do
      end

      defmodule MyApp.Metadata do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end

    test "a denylisted word that is not the final segment" do
      """
      defmodule Zelo.Planner.Result.ReorderedRoute do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end

    test "a module named with something other than an alias" do
      """
      defmodule :zelo_planner_result do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end
  end

  describe "params" do
    test "denylist replaces the default list" do
      """
      defmodule Zelo.Planner.Solver.Result do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName, denylist: ["Tracker"])
      |> refute_issues()
    end

    test "a replaced denylist reports its own words" do
      """
      defmodule Zelo.Planner.Tracker do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName, denylist: ["Tracker"])
      |> assert_issue(fn issue -> assert issue.trigger == "Tracker" end)
    end

    test "extra_denylist adds without restating the default" do
      """
      defmodule Zelo.Planner.Wrapper do
      end

      defmodule Zelo.Planner.Solver.Result do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName, extra_denylist: ["Wrapper"])
      |> assert_issues(fn issues ->
        assert Enum.map(issues, & &1.trigger) == ["Wrapper", "Result"]
      end)
    end

    test "a qualifier in front of a denylisted word rescues the name" do
      """
      defmodule Zelo.Planner.ScanResult do
      end

      defmodule Zelo.Planner.PlanJobInput do
      end

      defmodule Zelo.Planner.ZoneData do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> refute_issues()
    end

    test "suffix_denylist matches the end of the segment where denylist does not" do
      """
      defmodule Zelo.Routing.RoutingImplementation do
      end

      defmodule Zelo.Planner.RetrieveRouteImpl do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName)
      |> assert_issues(fn issues ->
        assert Enum.map(issues, & &1.trigger) == ["RoutingImplementation", "RetrieveRouteImpl"]
      end)
    end

    test "a replaced suffix_denylist reports only its own suffixes" do
      """
      defmodule Zelo.Routing.RoutingImplementation do
      end

      defmodule Zelo.Routing.RoutingAdapter do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName, suffix_denylist: ["Adapter"])
      |> assert_issue(fn issue -> assert issue.trigger == "RoutingAdapter" end)
    end

    test "framework names stay exempt even when a denylist names one" do
      """
      defmodule MyAppWeb.Router do
      end
      """
      |> to_source_file()
      |> run_check(GenericModuleName, extra_denylist: ["Router"])
      |> refute_issues()
    end
  end
end
