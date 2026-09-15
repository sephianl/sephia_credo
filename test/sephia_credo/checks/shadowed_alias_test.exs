defmodule SephiaCredo.Checks.ShadowedAliasTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.ShadowedAlias

  describe "two aliases sharing a final segment" do
    test "flags them" do
      ~S"""
      defmodule Sample do
        alias Zelo.Planner.Route.Delete
        alias Zelo.Planner.Stop.Delete

        def go(routes), do: Delete.delete_routes(routes)
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Delete"
        assert issue.message =~ "Zelo.Planner.Route.Delete and Zelo.Planner.Stop.Delete"
      end)
    end

    test "names the alias that actually wins" do
      ~S"""
      defmodule Sample do
        alias A.Supervisor
        alias B.Supervisor
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue ->
        assert issue.message =~ "reaches B.Supervisor"
      end)
    end

    test "reports on the line of the shadowing alias" do
      ~S"""
      defmodule Sample do
        alias A.Delete
        alias B.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue -> assert issue.line_no == 3 end)
    end

    test "flags three colliding aliases once" do
      ~S"""
      defmodule Sample do
        alias A.Delete
        alias B.Delete
        alias C.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue()
    end

    test "flags a collision introduced through a multi-alias" do
      ~S"""
      defmodule Sample do
        alias A.Delete
        alias B.{Create, Delete}
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue -> assert issue.trigger == "Delete" end)
    end

    test "flags two collisions in one module separately" do
      ~S"""
      defmodule Sample do
        alias A.Delete
        alias B.Delete
        alias A.Create
        alias B.Create
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "aliases that do not collide" do
    test "accepts distinct final segments" do
      ~S"""
      defmodule Sample do
        alias Zelo.Planner.Route.Delete
        alias Zelo.Planner.Stop.Renumber
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts the same module aliased twice" do
      ~S"""
      defmodule Sample do
        alias A.Delete
        alias A.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts a collision resolved with :as" do
      ~S"""
      defmodule Sample do
        alias Zelo.Planner.Route.Delete, as: DeleteRoute
        alias Zelo.Planner.Stop.Delete, as: DeleteStop
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts a collision where only one side carries :as" do
      ~S"""
      defmodule Sample do
        alias Zelo.Planner.Route.Delete
        alias Zelo.Planner.Stop.Delete, as: DeleteStop
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts a multi-alias with no collision" do
      ~S"""
      defmodule Sample do
        alias A.{Create, Delete}
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end
  end

  describe "scoping" do
    test "accepts the same final segment aliased in two sibling modules" do
      ~S"""
      defmodule Sample.One do
        alias A.Delete

        def go, do: Delete.call()
      end

      defmodule Sample.Two do
        alias B.Delete

        def go, do: Delete.call()
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts an alias in a nested module shadowing nothing in its parent" do
      ~S"""
      defmodule Sample do
        alias A.Delete

        defmodule Inner do
          alias B.Delete

          def go, do: Delete.call()
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "flags a collision inside a nested module" do
      ~S"""
      defmodule Sample do
        defmodule Inner do
          alias A.Delete
          alias B.Delete
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue -> assert issue.trigger == "Delete" end)
    end
  end

  describe "files with nothing to say" do
    test "accepts a module with no aliases" do
      ~S"""
      defmodule Sample do
        def go, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts a single-segment alias" do
      ~S"""
      defmodule Sample do
        alias Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end
  end

  describe "scopes narrower than the module" do
    test "accepts the same final segment aliased in two function bodies" do
      ~S"""
      defmodule Sample do
        def a do
          alias A.Delete
          Delete.go()
        end

        def b do
          alias B.Delete
          Delete.go()
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts an alias inside quote shadowing one in the defining module" do
      ~S"""
      defmodule Sample do
        alias A.Delete

        defmacro __using__(_opts) do
          quote do
            alias B.Delete
          end
        end

        def go, do: Delete.go()
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts the same final segment aliased in two defimpl blocks" do
      ~S"""
      defmodule Sample do
        defimpl Inspect, for: A do
          alias A.Delete
          def inspect(_term, _opts), do: Delete.label()
        end

        defimpl Inspect, for: B do
          alias B.Delete
          def inspect(_term, _opts), do: Delete.label()
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "accepts the same final segment aliased in two case branches" do
      ~S"""
      defmodule Sample do
        def go(x) do
          case x do
            :a ->
              alias A.Delete
              Delete.go()

            :b ->
              alias B.Delete
              Delete.go()
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end

    test "flags a collision inside one function body" do
      ~S"""
      defmodule Sample do
        def go do
          alias A.Delete
          alias B.Delete
          Delete.go()
        end
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Delete"
        assert issue.message =~ "A.Delete and B.Delete"
      end)
    end
  end

  describe "aliases carrying options" do
    test "flags a collision where one side carries warn: false" do
      ~S"""
      defmodule Sample do
        alias A.Delete, warn: false
        alias B.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Delete"
        assert issue.message =~ "A.Delete and B.Delete"
      end)
    end

    test "flags a collision introduced through a multi-alias carrying warn: false" do
      ~S"""
      defmodule Sample do
        alias A.{Create, Delete}, warn: false
        alias B.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> assert_issue(fn issue -> assert issue.trigger == "Delete" end)
    end

    test "accepts a collision resolved with :as alongside another option" do
      ~S"""
      defmodule Sample do
        alias A.Delete, as: DeleteA, warn: false
        alias B.Delete
      end
      """
      |> to_source_file()
      |> run_check(ShadowedAlias)
      |> refute_issues()
    end
  end
end
