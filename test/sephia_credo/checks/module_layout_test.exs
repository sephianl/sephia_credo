defmodule SephiaCredo.Checks.ModuleLayoutTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.ModuleLayout

  defp check(name, path, use_line \\ "use GenServer") do
    """
    defmodule #{name} do
      #{use_line}
    end
    """
    |> to_source_file(path)
    |> run_check(ModuleLayout, included_paths: ["lib/my_app/"])
  end

  describe "accepts" do
    test "a module at the path its name spells" do
      refute_issues(
        check("MyApp.Planner.Solver.ModelBuilder", "lib/my_app/planner/solver/model_builder.ex")
      )
    end

    test "a domain module in its own folder" do
      refute_issues(check("MyApp.Geography", "lib/my_app/geography/geography.ex"))
    end

    test "a plain module inside resources" do
      refute_issues(
        check("MyApp.Planner.Route.Worker", "lib/my_app/planner/resources/route/worker.ex")
      )
    end

    test "acronyms that underscore differently from their file" do
      refute_issues(check("MyApp.PostHogLogs", "lib/my_app/posthog_logs.ex"))
    end

    test "Ash resource code" do
      refute_issues(
        check("MyApp.Planner.Route", "lib/my_app/planner/route.ex", "use Ash.Resource")
      )
    end

    test "files outside the included paths" do
      refute_issues(check("MyAppWeb.OrderLive", "lib/my_app_web/live/orders/list_orders.ex"))
    end
  end

  describe "flags" do
    test "a module whose file does not spell its name, pointing at the nearest place it fits" do
      "MyApp.Planner.RouteTimeCalculator"
      |> check("lib/my_app/planner/resources/change/route_time_calculator.ex")
      |> assert_issue(fn issue ->
        assert issue.trigger == "MyApp.Planner.RouteTimeCalculator"
        assert issue.line_no == 1
        assert issue.message =~ "lib/my_app/planner/resources/route_time_calculator.ex"
      end)
    end

    test "a module outside resources, keeping it outside" do
      "MyApp.Labels.Generator"
      |> check("lib/my_app/labels/label_generator.ex")
      |> assert_issue(fn issue -> assert issue.message =~ "lib/my_app/labels/generator.ex" end)
    end
  end
end
