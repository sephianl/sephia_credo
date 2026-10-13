defmodule SephiaCredo.Checks.ProjectImportTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.ProjectImport

  @params [project_modules: ["MyApp", "MyAppWeb"]]

  defp check(source, path, params \\ @params) do
    source
    |> to_source_file(path)
    |> run_check(ProjectImport, params)
  end

  test "flags importing a project module" do
    """
    defmodule MyAppWeb.Routes.Page do
      import MyAppWeb.Routes.ListRoutesHelpers
    end
    """
    |> check("lib/my_app_web/live/routes/page.ex")
    |> assert_issue(fn issue ->
      assert issue.line_no == 2
      assert issue.message =~ "Alias MyAppWeb.Routes.ListRoutesHelpers"
    end)
  end

  test "flags a project module imported with only:" do
    """
    defmodule MyApp.Planner.Thing do
      import MyApp.Planner.OrderGroupMapper, only: [route_key: 1]
    end
    """
    |> check("lib/my_app/planner/thing.ex")
    |> assert_issue()
  end

  test "leaves dependency imports alone, including ones sharing the project's prefix" do
    """
    defmodule MyAppWeb.Routes.Page do
      import Phoenix.Component, only: [sigil_H: 2]
      import Ecto.Query
      import MyAppExtra.Helpers
    end
    """
    |> check("lib/my_app_web/live/routes/page.ex")
    |> refute_issues()
  end

  test "allows the modules listed in allowed" do
    """
    defmodule MyAppWeb.Routes.Page do
      import MyApp.TimeExpressions
      import MyAppWeb.CoreComponents
      import MyAppWeb.Routes.ListRoutesHelpers
    end
    """
    |> check(
      "lib/my_app_web/live/routes/page.ex",
      @params ++ [allowed: ["MyApp.TimeExpressions", "MyAppWeb.CoreComponents"]]
    )
    |> assert_issue(fn issue -> assert issue.message =~ "ListRoutesHelpers" end)
  end

  test "leaves an import inside a quote alone, as use MyAppWeb hands it out" do
    """
    defmodule MyAppWeb do
      def html do
        quote do
          import MyAppWeb.CoreComponents
        end
      end
    end
    """
    |> check("lib/my_app_web.ex")
    |> refute_issues()
  end

  test "exempts test files and their support modules" do
    source = """
    defmodule Anything do
      import MyAppWeb.Routes.ListRoutesHelpers
    end
    """

    for path <- ["test/my_app_web/live/routes/page_test.exs", "test/support/conn_case.ex"] do
      source |> check(path) |> refute_issues()
    end
  end

  test "checks lib code whose path has a test folder in it" do
    """
    defmodule MyApp.Test.Clock do
      import MyApp.Helpers
    end
    """
    |> check("/home/me/test/my_app/lib/my_app/test/clock.ex")
    |> assert_issue()
  end

  test "resolves an import of __MODULE__.Child" do
    """
    defmodule MyApp.Planner do
      import __MODULE__.Helpers
      import unquote(Module.concat([MyApp, Other]))
      import unquote(base).Child
    end
    """
    |> check("lib/my_app/planner.ex")
    |> assert_issue(fn issue -> assert issue.message =~ "Alias MyApp.Planner.Helpers" end)
  end

  describe "an import supplying a function plug, as phx.gen.auth's router has" do
    setup do
      user_auth =
        """
        defmodule MyAppWeb.UserAuth do
          def fetch_current_scope_for_user(conn, _opts), do: conn
          def require_authenticated_user(conn, _opts) when is_map(conn), do: conn
        end
        """
        |> to_source_file("lib/my_app_web/user_auth.ex")

      %{user_auth: user_auth}
    end

    test "is left alone, whether used by plug or pipe_through", %{user_auth: user_auth} do
      for usage <- [
            "plug :fetch_current_scope_for_user",
            "pipe_through [:browser, :require_authenticated_user]"
          ] do
        router =
          """
          defmodule MyAppWeb.Router do
            import MyAppWeb.UserAuth
            import MyAppWeb.RouteHelpers

            pipeline :browser do
              #{usage}
            end
          end
          """
          |> to_source_file("lib/my_app_web/router.ex")

        [router, user_auth]
        |> run_check(ProjectImport, @params)
        |> assert_issue(fn issue -> assert issue.message =~ "RouteHelpers" end)
      end
    end
  end

  test "defaults project_modules to the Mix app and its Web module" do
    """
    defmodule SephiaCredoWeb.Page do
      import SephiaCredo.Helpers
      import SephiaCredoWeb.Helpers
    end
    """
    |> check("lib/sephia_credo_web/page.ex", [])
    |> assert_issues(fn issues -> assert length(issues) == 2 end)
  end
end
