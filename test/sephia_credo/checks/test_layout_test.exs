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
    source_file = source_file("MyApp.Planner.DepotTest", "test/my_app/depot_test.exs", tmp_dir)

    refute_issues(run_check(source_file, TestLayout))

    File.write!(
      Path.join(tmp_dir, "lib/my_app/planner/depot.ex"),
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

  test "ignores tests not named after a module in lib", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.RouteLifecycleTest"
    |> check("test/my_app/planner/route_lifecycle_test.exs", tmp_dir)
    |> refute_issues()
  end

  test "ignores files that are not tests", %{tmp_dir: tmp_dir} do
    "MyApp.Planner.Route.Changes.SetCurrentStopTest"
    |> check("test/support/set_current_stop_test.ex", tmp_dir)
    |> refute_issues()
  end
end
