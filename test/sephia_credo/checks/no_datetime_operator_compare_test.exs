defmodule SephiaCredo.Checks.NoDateTimeOperatorCompareTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.NoDateTimeOperatorCompare

  describe "sigils" do
    test "flags < with ~D sigil" do
      """
      defmodule Sample do
        def check(date) do
          date < ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue(fn issue ->
        assert issue.trigger == ">"
      end)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue(fn issue ->
        assert issue.trigger == "<="
      end)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue(fn issue ->
        assert issue.trigger == ">="
      end)
    end

    test "flags when sigil is on the left side" do
      """
      defmodule Sample do
        def check(date) do
          ~D[2024-01-01] < date
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue()
    end
  end

  describe "equality operators" do
    test "flags == when both sides are datetime values" do
      ~S"""
      defmodule Sample do
        def check do
          %Date{year: 2024, month: 1, day: 1} == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue(fn issue ->
        assert issue.trigger == "!="
      end)
    end

    test "allows == with module call (unknown return type)" do
      """
      defmodule Sample do
        def check do
          DateTime.utc_now() == ~U[2024-01-01 00:00:00Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> refute_issues()
    end

    test "allows == with DateTime.to_date (returns Date, not DateTime)" do
      """
      defmodule Sample do
        def check(dt) do
          DateTime.to_date(dt) == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> refute_issues()
    end

    test "allows == with only one datetime side (variable == sigil)" do
      """
      defmodule Sample do
        def check(date) do
          date == ~D[2024-01-01]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> refute_issues()
    end

    test "allows == with DateTime.diff (returns integer)" do
      """
      defmodule Sample do
        def check(route) do
          DateTime.diff(route.planned_end_time, route.planned_departure_time) ==
            route.projected_duration_s
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> refute_issues()
    end

    test "allows == with field access and sigil in assertions" do
      """
      defmodule Sample do
        def check(result) do
          result.time_window_start == ~U[2025-01-01 14:00:00.000000Z]
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue()
    end
  end

  describe "module function calls" do
    test "flags < with Date.utc_today()" do
      """
      defmodule Sample do
        def check(date) do
          date < Date.utc_today()
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue()
    end

    test "flags > with DateTime.utc_now()" do
      """
      defmodule Sample do
        def check(dt) do
          DateTime.utc_now() > dt
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue()
    end

    test "flags <= with NaiveDateTime.local_now()" do
      """
      defmodule Sample do
        def check(ndt) do
          ndt <= NaiveDateTime.local_now()
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issue()
    end

    test "flags >= with Time.utc_now()" do
      """
      defmodule Sample do
        def check(time) do
          Time.utc_now() >= time
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> refute_issues()
    end
  end

  describe "extra_modules parameter" do
    test "flags comparison with a custom module" do
      """
      defmodule Sample do
        def check(a) do
          a < Timex.now()
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare, extra_modules: [[:Timex]])
      |> assert_issue()
    end

    test "flags struct literal with a custom module" do
      ~S"""
      defmodule Sample do
        def check(a) do
          a < %Timex{field: "value"}
        end
      end
      """
      |> to_source_file()
      |> run_check(NoDateTimeOperatorCompare, extra_modules: [[:Timex]])
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
      |> run_check(NoDateTimeOperatorCompare)
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
      |> run_check(NoDateTimeOperatorCompare)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end
end
