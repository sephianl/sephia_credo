defmodule SephiaCredo.Checks.AssertWithoutAssertionTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.AssertWithoutAssertion

  describe "flags vacuous bindings" do
    test "flags `assert x = expr` when x is unused" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert x = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue(fn issue ->
        assert issue.trigger == "assert"
      end)
    end

    test "flags `assert {:ok, val} = expr` when val is unused" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, val} = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue()
    end

    test "flags `assert %{a: x} = expr` when x is unused" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert %{a: x} = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue()
    end

    test "flags `assert [head | _] = expr` when head is unused" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert [head | _] = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue()
    end

    test "flags vacuous binding inside a setup block" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        setup do
          assert x = some_call()
          :ok
        end

        test "noop", do: assert true
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue()
    end
  end

  describe "no false positives" do
    test "does not flag when bound variable is referenced afterward" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, val} = some_call()
          assert val == 42
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag bare assert with no `=`" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag literal-only pattern" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, 42} = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag pinned-only pattern" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing", %{expected: expected} do
          assert {:ok, ^expected} = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag underscore-prefixed binding" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, _val} = some_call()
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag partial usage (some bound vars used)" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, %{a: x, b: _y}} = some_call()
          assert x == 1
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end

    test "does not flag when variable is used in an interpolation" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "thing" do
          assert {:ok, val} = some_call()
          IO.puts("got: #{val}")
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end
  end

  describe "scope boundary" do
    test "does not count references in other test functions" do
      ~S"""
      defmodule Sample.MyTest do
        use ExUnit.Case

        test "one" do
          assert val = some_call()
        end

        test "two" do
          IO.puts(val)
        end
      end
      """
      |> to_source_file("my_test.exs")
      |> run_check(AssertWithoutAssertion)
      |> assert_issue()
    end
  end

  describe "non-test files" do
    test "does not flag in a .ex source file" do
      ~S"""
      defmodule Sample do
        def go do
          assert x = some_call()
        end
      end
      """
      |> to_source_file("sample.ex")
      |> run_check(AssertWithoutAssertion)
      |> refute_issues()
    end
  end
end
