defmodule SephiaCredo.Checks.TestLayoutTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.TestLayout

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(Path.join(lib, "my_app/planner/resources/route/changes"))

    File.write!(
      Path.join(lib, "my_app/planner/resources/route/changes/set_current_stop.ex"),
      "defmodule MyApp.Planner.Route.Changes.SetCurrentStop do\nend\n"
    )

    :ok
  end

  # Absolute paths under tmp_dir, as in credo diff's merge-base clone: lib is read from
  # the tree the test file is in, not the cwd.
  defp source_file(name, path, tmp_dir),
    do: to_source_file("defmodule #{name} do\n  use ExUnit.Case\nend\n", Path.join(tmp_dir, path))

  defp check(name, path, tmp_dir), do: name |> source_file(path, tmp_dir) |> run_check(TestLayout)

  test "accepts a test mirroring its module's file", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Route.Changes.SetCurrentStopTest"
    |> check("test/my_app/planner/resources/route/changes/set_current_stop_test.exs", tmp_dir)
    |> refute_issues()
  end

  test "accepts a split-off test file next to the main one", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Route.Changes.SetCurrentStopTest"
    |> check(
      "test/my_app/planner/resources/route/changes/set_current_stop_departure_test.exs",
      tmp_dir
    )
    |> refute_issues()
  end

  test "sees modules added since an earlier run", %{tmp_dir: tmp_dir} do
    source_file =
      source_file("MyApp.Planner.DepotTest", "test/my_app/planner/depot_test.exs", tmp_dir)

    refute_issues(run_check(source_file, TestLayout))

    File.write!(
      Path.join(tmp_dir, "lib/my_app/planner/resources/depot.ex"),
      "defmodule MyApp.Planner.Depot do\nend\n"
    )

    assert_issue(run_check(source_file, TestLayout))
  end

  test "flags a test left behind when its module moved", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Route.Changes.SetCurrentStopTest"
    |> check("test/my_app/planner/route/changes/set_current_stop_test.exs", tmp_dir)
    |> assert_issue(fn issue ->
      assert issue.trigger == "MyApp.Planner.Route.Changes.SetCurrentStopTest"

      assert issue.message =~
               "test/my_app/planner/resources/route/changes/set_current_stop_test.exs"
    end)
  end

  test "accepts a test not named after a module in lib that is named after its path", %{
    tmp_dir: tmp_dir
  } do
    "MyApp.Planner.RouteLifecycleTest"
    |> check("test/my_app/planner/route_lifecycle_test.exs", tmp_dir)
    |> refute_issues()
  end

  test "accepts a resources folder the name leaves out", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.RouteLifecycleTest"
    |> check("test/my_app/planner/resources/route_lifecycle_test.exs", tmp_dir)
    |> refute_issues()
  end

  test "accepts a folder named in name_free_folders that the name leaves out", %{
    tmp_dir: tmp_dir
  } do
    "defmodule MyAppWeb.Map.DeleteAllTest do\n  use ExUnit.Case\nend\n"
    |> to_source_file(Path.join(tmp_dir, "test/my_app_web/live/map/delete_all_test.exs"))
    |> run_check(TestLayout, name_free_folders: ["resources", "live"])
    |> refute_issues()
  end

  test "flags a folder left in the path when name_free_folders does not name it", %{
    tmp_dir: tmp_dir
  } do
    "MyAppWeb.Map.DeleteAllTest"
    |> check("test/my_app_web/live/map/delete_all_test.exs", tmp_dir)
    |> assert_issue(fn issue -> assert issue.message =~ "MyAppWeb.Live.Map.DeleteAllTest" end)
  end

  test "flags a test still named after a module that moved away", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Mutations.PlanBreaksTest"
    |> check("test/my_app/solver/plan_breaks_test.exs", tmp_dir)
    |> assert_issue(fn issue ->
      assert issue.trigger == "MyApp.Planner.Mutations.PlanBreaksTest"
      assert issue.message =~ "MyApp.Solver.PlanBreaksTest"
    end)
  end

  test "flags a test module without the Test suffix", %{tmp_dir: tmp_dir} do
    "MyApp.Solver.OutputProperties"
    |> check("test/my_app/solver/output_properties_test.exs", tmp_dir)
    |> assert_issue()
  end

  test "ignores files that are not tests", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Route.Changes.SetCurrentStopTest"
    |> check("test/support/set_current_stop_test.ex", tmp_dir)
    |> refute_issues()
  end

  test "ignores helpers under test/support", %{tmp_dir: tmp_dir} do
    "MyApp.DataCase"
    |> check("test/support/data_case_test.exs", tmp_dir)
    |> refute_issues()
  end
end
