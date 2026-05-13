defmodule SephiaCredo.Checks.StructComparisonOperatorTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.StructComparisonOperator

  describe "date/time sigils" do
    test "flags < with ~D sigil" do
      """
      defmodule Sample do
        def check(date) do
          date < ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue(fn issue ->
        assert issue.trigger == "<"
      end)
    end

    test "flags > with ~U sigil" do
      """
      defmodule Sample do
        def check(dt) do
          dt > ~U[2024-01-01 00:00:00Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags <= with ~N sigil" do
      """
      defmodule Sample do
        def check(ndt) do
          ndt <= ~N[2024-01-01 00:00:00]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags >= with ~T sigil" do
      """
      defmodule Sample do
        def check(time) do
          time >= ~T[12:00:00]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags when sigil is on the left" do
      """
      defmodule Sample do
        def check(date) do
          ~D[2024-01-01] < date
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end
  end

  describe "Decimal" do
    test "flags < with Decimal.new/1" do
      ~S"""
      defmodule Sample do
        def check(d) do
          d < Decimal.new("1.5")
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags > with two Decimal calls" do
      ~S"""
      defmodule Sample do
        def check do
          Decimal.new("2") > Decimal.new("1.5")
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags == with two Decimal struct literals" do
      ~S"""
      defmodule Sample do
        def check do
          %Decimal{sign: 1, coef: 10, exp: -1} == %Decimal{sign: 1, coef: 100, exp: -2}
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue(fn issue ->
        assert issue.trigger == "=="
      end)
    end

    test "does not flag == when only one side is a Decimal" do
      ~S"""
      defmodule Sample do
        def check(d) do
          d == Decimal.new("1.0")
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end
  end

  describe "Version" do
    test "flags < with Version.parse!/1" do
      ~S"""
      defmodule Sample do
        def check(v) do
          v < Version.parse!("1.0.0")
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags > with two %Version{} literals" do
      ~S"""
      defmodule Sample do
        def check do
          %Version{major: 1, minor: 10, patch: 0, pre: [], build: nil} >
            %Version{major: 1, minor: 9, patch: 0, pre: [], build: nil}
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end
  end

  describe "equality operator asymmetry" do
    test "flags == when both sides are datetime values" do
      ~S"""
      defmodule Sample do
        def check do
          %Date{year: 2024, month: 1, day: 1} == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue(fn issue ->
        assert issue.trigger == "=="
      end)
    end

    test "flags != when both sides are sigils" do
      """
      defmodule Sample do
        def check do
          ~U[2024-01-01 00:00:00Z] != ~U[2024-06-01 00:00:00Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "allows == with module call on one side (unknown return type)" do
      """
      defmodule Sample do
        def check do
          DateTime.utc_now() == ~U[2024-01-01 00:00:00Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows == with DateTime.to_date on one side" do
      """
      defmodule Sample do
        def check(dt) do
          DateTime.to_date(dt) == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows == with variable and sigil" do
      """
      defmodule Sample do
        def check(date) do
          date == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows == with field access and sigil" do
      """
      defmodule Sample do
        def check(result) do
          result.time == ~U[2025-01-01 14:00:00Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end
  end

  describe "struct literals" do
    test "flags < with %Date{}" do
      ~S"""
      defmodule Sample do
        def check(a) do
          a < %Date{year: 2024, month: 1, day: 1}
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags > with %DateTime{}" do
      ~S"""
      defmodule Sample do
        def check(a) do
          %DateTime{year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0} > a
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end
  end

  describe "module function calls" do
    test "flags < with Date.utc_today/0" do
      """
      defmodule Sample do
        def check(date) do
          date < Date.utc_today()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags > with DateTime.utc_now/0" do
      """
      defmodule Sample do
        def check(dt) do
          DateTime.utc_now() > dt
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags >= with Time.utc_now/0" do
      """
      defmodule Sample do
        def check(t) do
          Time.utc_now() >= t
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end

    test "flags <= with NaiveDateTime.local_now/0" do
      """
      defmodule Sample do
        def check(ndt) do
          ndt <= NaiveDateTime.local_now()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issue()
    end
  end

  describe "no false positives" do
    test "allows < with plain variables" do
      """
      defmodule Sample do
        def check(a, b) do
          a < b
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows < with integers" do
      """
      defmodule Sample do
        def check(a) do
          a < 10
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows == with plain variables" do
      """
      defmodule Sample do
        def check(a, b) do
          a == b
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows non-datetime module calls with <" do
      """
      defmodule Sample do
        def check(a) do
          a < String.length("hello")
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows Date.compare/2 == :lt" do
      """
      defmodule Sample do
        def check(a, b) do
          Date.compare(a, b) == :lt
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end

    test "allows Decimal.compare/2" do
      """
      defmodule Sample do
        def check(a, b) do
          Decimal.compare(a, b) == :lt
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end
  end

  describe "extra_modules parameter" do
    test "flags < with a custom module via atom shorthand" do
      """
      defmodule Sample do
        def check(a) do
          a < Timex.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator, extra_modules: [Timex])
      |> assert_issue()
    end

    test "flags struct literal with a custom module via list-of-atoms" do
      ~S"""
      defmodule Sample do
        def check(a) do
          a < %Money{amount: 1, currency: :USD}
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator, extra_modules: [[:Money]])
      |> assert_issue()
    end

    test "flags with a module given as a string" do
      """
      defmodule Sample do
        def check(a) do
          a < Timex.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator, extra_modules: ["Timex"])
      |> assert_issue()
    end

    test "does not flag custom module without the parameter" do
      """
      defmodule Sample do
        def check(a) do
          a < Timex.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> refute_issues()
    end
  end

  describe "multiple issues" do
    test "flags multiple comparisons in the same module" do
      """
      defmodule Sample do
        def check(a, b) do
          a < ~D[2024-01-01] and b > Date.utc_today()
        end
      end
      """
      |> to_source_file()
      |> run_check(StructComparisonOperator)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end
end
