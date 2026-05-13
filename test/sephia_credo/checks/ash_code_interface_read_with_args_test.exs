defmodule SephiaCredo.Checks.AshCodeInterfaceReadWithArgsTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.AshCodeInterfaceReadWithArgs

  describe "flags read action with args" do
    test "flags define with action: :read and args: [_]" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :search, action: :read, args: [:query]
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> assert_issue(fn issue ->
        assert issue.trigger == "define"
      end)
    end

    test "flags define with multiple args" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :search, action: :read, args: [:query, :limit]
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> assert_issue()
    end

    test "flags define when args: precedes action:" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :search, args: [:query], action: :read
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> assert_issue()
    end

    test "flags multiple offending defines" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :find_by_email, action: :read, args: [:email]
          define :find_by_name, action: :read, args: [:name]
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end

  describe "no false positives" do
    test "does not flag a custom (non-:read) action with args" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :find_by_email, action: :find_by_email, args: [:email]
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end

    test "does not flag :read action with empty args list" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :list, action: :read, args: []
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end

    test "does not flag :read action without args key" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :list, action: :read
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end

    test "does not flag define without options at all" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :list
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end

    test "does not flag define call outside code_interface block" do
      ~S"""
      defmodule MyApp.Helper do
        def define(opts) do
          # not the Ash macro
          opts
        end

        def go do
          define(action: :read, args: [:query])
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end

    test "does not flag define inside a different DSL block" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        actions do
          define :read, action: :read, args: [:q]
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> refute_issues()
    end
  end

  describe "mixed defines" do
    test "flags only the offending define when mixed with valid ones" do
      ~S"""
      defmodule MyApp.User do
        use Ash.Resource

        code_interface do
          define :list, action: :read
          define :search, action: :read, args: [:query]
          define :create, action: :create
        end
      end
      """
      |> to_source_file()
      |> run_check(AshCodeInterfaceReadWithArgs)
      |> assert_issue()
    end
  end
end
