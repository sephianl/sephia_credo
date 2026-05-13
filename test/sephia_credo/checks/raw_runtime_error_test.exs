defmodule SephiaCredo.Checks.RawRuntimeErrorTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.RawRuntimeError

  describe "raise with a string" do
    test "flags raise with a bare string literal" do
      ~S"""
      defmodule Sample do
        def go do
          raise "boom"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue(fn issue ->
        assert issue.trigger == "raise"
      end)
    end

    test "flags raise with an interpolated string" do
      ~S"""
      defmodule Sample do
        def go(x) do
          raise "bad value: #{x}"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue()
    end

    test "flags raise with a heredoc string" do
      ~S'''
      defmodule Sample do
        def go do
          raise """
          something
          went wrong
          """
        end
      end
      '''
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue()
    end
  end

  describe "raise RuntimeError explicitly" do
    test "flags raise RuntimeError with a message" do
      ~S"""
      defmodule Sample do
        def go do
          raise RuntimeError, "boom"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue()
    end

    test "flags raise RuntimeError, message: ..." do
      ~S"""
      defmodule Sample do
        def go do
          raise RuntimeError, message: "boom"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue()
    end

    test "flags bare raise RuntimeError" do
      ~S"""
      defmodule Sample do
        def go do
          raise RuntimeError
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issue()
    end
  end

  describe "no false positives" do
    test "does not flag raising a custom exception module" do
      ~S"""
      defmodule Sample do
        def go do
          raise MyApp.BoomError, "boom"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag raising a custom exception with message keyword" do
      ~S"""
      defmodule Sample do
        def go do
          raise MyApp.BoomError, message: "boom"
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag raising a struct literal" do
      ~S"""
      defmodule Sample do
        def go do
          raise %MyApp.BoomError{reason: :timeout}
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag reraise" do
      ~S"""
      defmodule Sample do
        def go do
          try do
            do_thing()
          rescue
            e -> reraise e, __STACKTRACE__
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag raise with a plain variable" do
      ~S"""
      defmodule Sample do
        def go(err) do
          raise err
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag raise with a function call result" do
      ~S"""
      defmodule Sample do
        def go do
          raise build_error(:timeout)
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end

    test "does not flag a regular string in a non-raise context" do
      ~S"""
      defmodule Sample do
        def go do
          x = "boom"
          IO.puts(x)
        end
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> refute_issues()
    end
  end

  describe "multiple issues" do
    test "flags multiple raises in the same module" do
      ~S"""
      defmodule Sample do
        def a, do: raise "one"
        def b, do: raise RuntimeError, "two"
        def c, do: raise MyError, "three"
      end
      """
      |> to_source_file()
      |> run_check(RawRuntimeError)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end
end
