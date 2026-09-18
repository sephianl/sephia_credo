defmodule SephiaCredo.Checks.UtcCalendarDateTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UtcCalendarDate

  describe "Date.utc_today" do
    test "flags a bare call" do
      """
      defmodule Sample do
        def run, do: Date.utc_today()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Date.utc_today"
      end)
    end

    test "flags the explicit-calendar arity" do
      """
      defmodule Sample do
        def run, do: Date.utc_today(Calendar.ISO)
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue()
    end

    test "flags each call site separately" do
      """
      defmodule Sample do
        def from, do: Date.utc_today()
        def to, do: Date.utc_today()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "collapsing a UTC instant to a date" do
    test "flags the piped spelling" do
      """
      defmodule Sample do
        def run, do: DateTime.utc_now() |> DateTime.to_date()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue(fn issue ->
        assert issue.trigger == "DateTime.to_date"
      end)
    end

    test "flags the directly-nested spelling" do
      """
      defmodule Sample do
        def run, do: DateTime.to_date(DateTime.utc_now())
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue()
    end

    test "flags the NaiveDateTime spelling" do
      """
      defmodule Sample do
        def run, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_date()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue(fn issue ->
        assert issue.trigger == "NaiveDateTime.to_date"
      end)
    end
  end

  describe "values that commit to no day boundary" do
    test "does not flag a bare DateTime.utc_now" do
      """
      defmodule Sample do
        def run, do: DateTime.utc_now()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> refute_issues()
    end

    test "does not flag a bare NaiveDateTime.utc_now" do
      """
      defmodule Sample do
        def run, do: NaiveDateTime.utc_now()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> refute_issues()
    end

    test "does not flag to_date on a local now" do
      """
      defmodule Sample do
        def run, do: TimezoneHelpers.now() |> DateTime.to_date()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> refute_issues()
    end

    test "does not flag to_date on a stored value" do
      """
      defmodule Sample do
        def run(order), do: DateTime.to_date(order.inserted_at)
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> refute_issues()
    end

    test "does not flag a date built from a local datetime" do
      """
      defmodule Sample do
        def run, do: DateTime.now!("Europe/Amsterdam") |> DateTime.to_date()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> refute_issues()
    end
  end

  describe "test files" do
    test "are checked, not exempt" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "today" do
          assert Date.utc_today() == Date.utc_today()
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UtcCalendarDate)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "local_date_call" do
    test "names the replacement in the message when set" do
      """
      defmodule Sample do
        def run, do: Date.utc_today()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate, local_date_call: "LocalTime.today()")
      |> assert_issue(fn issue ->
        assert issue.message =~ "Use `LocalTime.today()` instead."
      end)
    end

    test "falls back to generic advice when unset" do
      """
      defmodule Sample do
        def run, do: Date.utc_today()
      end
      """
      |> to_source_file()
      |> run_check(UtcCalendarDate)
      |> assert_issue(fn issue ->
        assert issue.message =~ "operating timezone"
      end)
    end
  end
end
