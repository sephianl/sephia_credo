defmodule SephiaCredo.Checks.DisproportionateModuleDocTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.DisproportionateModuleDoc

  describe "a moduledoc that outweighs its module" do
    test "is flagged" do
      """
      defmodule Sample do
        @moduledoc \"""
        Shared ceiling for jobs that answer transient failures with a snooze.

        Oban increments `max_attempts` on every snooze, so `attempt <
        max_attempts` stays true forever and a job that keeps snoozing retries
        without bound.

        Callers that hand the result straight back must convert exhaustion into
        a terminal state rather than re-raising, because the earlier snoozes
        already inflated the ceiling.
        \"""

        @max_attempts 5

        def should_snooze?(attempt), do: attempt < @max_attempts
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "@moduledoc"
        assert issue.line_no == 2
      end)
    end

    test "is reported without line counts, so an edit elsewhere does not re-report it" do
      """
      defmodule Sample do
        @moduledoc \"""
        One
        Two
        Three
        Four
        Five
        Six
        Seven
        Eight
        Nine
        Ten
        \"""

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> assert_issue(fn issue ->
        refute issue.message =~ ~r/\d/
      end)
    end
  end

  describe "a moduledoc in proportion to its module" do
    test "is not flagged when the module is long" do
      body = String.duplicate("  def run(x), do: x\n", 80)

      """
      defmodule Sample do
        @moduledoc \"""
        Wraps the solver.

        Durations are seconds; the solver rejects milliseconds silently.
        Callers pass depot-local times, not UTC.
        \"""

      #{body}
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end

    test "is not flagged when the doc is under min_doc_lines, however small the module" do
      """
      defmodule Sample do
        @moduledoc \"""
        Counts orders.

        Must agree with OrderSearch or count and load disagree.
        \"""

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end

    test "is not flagged for a one-line moduledoc" do
      """
      defmodule Sample do
        @moduledoc "Counts orders."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end
  end

  describe "modules with no prose to weigh" do
    test "does not flag @moduledoc false" do
      """
      defmodule Sample do
        @moduledoc false

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end

    test "does not flag a module without a moduledoc" do
      """
      defmodule Sample do
        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end

    test "does not flag an interpolated moduledoc it cannot measure" do
      ~S|defmodule Sample do
        @moduledoc """
        Version #{@version}.
        One
        Two
        Three
        Four
        Five
        Six
        """

        def run, do: :ok
      end|
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> refute_issues()
    end
  end

  describe "params" do
    test "max_ratio raises the bar" do
      source =
        """
        defmodule Sample do
          @moduledoc \"""
          One
          Two
          Three
          Four
          Five
          Six
          Seven
          Eight
          Nine
          Ten
          \"""

          def run, do: :ok
        end
        """
        |> to_source_file()

      source |> run_check(DisproportionateModuleDoc) |> assert_issue()
      source |> run_check(DisproportionateModuleDoc, max_ratio: 0.95) |> refute_issues()
    end

    test "min_doc_lines exempts short docs on short modules" do
      source =
        """
        defmodule Sample do
          @moduledoc \"""
          One
          Two
          Three
          Four
          Five
          Six
          Seven
          Eight
          Nine
          Ten
          \"""

          def run, do: :ok
        end
        """
        |> to_source_file()

      source |> run_check(DisproportionateModuleDoc) |> assert_issue()
      source |> run_check(DisproportionateModuleDoc, min_doc_lines: 20) |> refute_issues()
    end
  end

  describe "several modules in one file" do
    test "are weighed separately" do
      """
      defmodule Bloated do
        @moduledoc \"""
        One
        Two
        Three
        Four
        Five
        Six
        Seven
        Eight
        Nine
        Ten
        \"""

        def run, do: :ok
      end

      defmodule Lean do
        @moduledoc "Does one thing."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(DisproportionateModuleDoc)
      |> assert_issue(fn issue ->
        assert issue.line_no == 2
      end)
    end
  end
end
