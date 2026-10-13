defmodule SephiaCredo.Checks.UniqueModuleNameTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UniqueModuleName

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    for {path, name} <- [
          {"lib/my_app/planner/resources/route.ex", "MyApp.Planner.Route"},
          {"lib/my_app/planner/solver/route.ex", "MyApp.Planner.Solver.Route"},
          {"lib/my_app/logistics/route.ex", "MyApp.Logistics.Route"}
        ] do
      file = Path.join(tmp_dir, path)
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "defmodule #{name} do\nend\n")
    end

    :ok
  end

  defp check(name, path, tmp_dir) do
    "defmodule #{name} do\nend\n"
    |> to_source_file(Path.join(tmp_dir, path))
    |> run_check(UniqueModuleName, included_paths: ["lib/my_app/planner/"])
  end

  test "flags a module ending in the same name as another, naming it", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Solver.Route"
    |> check("lib/my_app/planner/solver/route.ex", tmp_dir)
    |> assert_issue(fn issue ->
      assert issue.line_no == 1
      assert issue.message =~ "MyApp.Planner.Route"
      refute issue.message =~ "MyApp.Logistics.Route"
    end)
  end

  test "accepts a module whose last name is its own", %{tmp_dir: tmp_dir} do
    refute_issues(check("MyApp.Planner.Depot", "lib/my_app/planner/resources/depot.ex", tmp_dir))
  end

  test "ignores files outside the included paths", %{tmp_dir: tmp_dir} do
    refute_issues(check("MyApp.Logistics.Route", "lib/my_app/logistics/route.ex", tmp_dir))
  end
end
