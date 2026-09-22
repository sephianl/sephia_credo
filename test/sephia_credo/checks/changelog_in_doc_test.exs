defmodule SephiaCredo.Checks.ChangelogInDocTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.ChangelogInDoc

  describe "docs that narrate the code's history" do
    test "flags a moduledoc describing the shape it replaced" do
      """
      defmodule Sample do
        @moduledoc \"""
        Options for the demo order form, where the form used to carry two
        mutually exclusive booleans that disabled each other.
        \"""

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "used to"
        assert issue.message =~ "`@moduledoc`"
      end)
    end

    test "flags a doc narrating a default it no longer applies" do
      """
      defmodule Sample do
        @doc \"""
        Serialises a plan. It also used to default a missing unit to `:centimeter`.
        \"""
        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "used to"
        assert issue.message =~ "`@doc`"
      end)
    end

    test "flags a shortdoc" do
      """
      defmodule Mix.Tasks.Sample do
        @shortdoc "Replays a benchmark, formerly captured by the deleted capture task."

        def run(_argv), do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "formerly"
      end)
    end

    test "flags a typedoc" do
      """
      defmodule Sample do
        @typedoc "A result. We renamed this from `outcome`."
        @type t :: :ok | :error
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "we renamed"
      end)
    end

    test "matches regardless of case" do
      """
      defmodule Sample do
        @moduledoc "Historically this held both halves."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issue(fn issue ->
        assert issue.trigger == "historically"
      end)
    end

    test "flags the same note copied into two modules" do
      """
      defmodule First do
        @moduledoc "The form used to carry two booleans."

        def run, do: :ok
      end

      defmodule Second do
        @moduledoc "The form used to carry two booleans."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "docs that describe what is" do
    test "does not flag prose without a history marker" do
      """
      defmodule Sample do
        @moduledoc \"""
        Refuses an action naming an order this company delegated away — the
        partner plans its own copy, so planning the parent puts two companies
        on one address.
        \"""

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag @moduledoc false" do
      """
      defmodule Sample do
        @moduledoc false

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag the passive participle after a copula" do
      """
      defmodule Sample do
        @moduledoc "These credentials are never used to log in."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag the passive participle opening a sentence" do
      """
      defmodule Sample do
        @moduledoc \"""
        Stop-time helpers.

        Used to prevent N+1 updates when processing parcels on one stop.
        \"""

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag the passive participle after a comma" do
      """
      defmodule Sample do
        @moduledoc "Each vehicle's last-known position, used to draw markers on the map."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag domain vocabulary that is not in the defaults" do
      """
      defmodule Sample do
        @moduledoc "Items that do not fit are returned in `:leftover` as `%Leftover{}` values."

        def run, do: :ok
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end

    test "does not flag the phrase in code or a comment" do
      """
      defmodule Sample do
        def run do
          used_to = "used to"
          used_to
        end
      end
      """
      |> to_source_file()
      |> run_check(ChangelogInDoc)
      |> refute_issues()
    end
  end

  describe "indicators" do
    test "a custom list replaces the default" do
      source =
        """
        defmodule Sample do
          @moduledoc "Previously this held both halves."

          def run, do: :ok
        end
        """
        |> to_source_file()

      source |> run_check(ChangelogInDoc) |> refute_issues()

      source
      |> run_check(ChangelogInDoc, indicators: ["previously"])
      |> assert_issue(fn issue -> assert issue.trigger == "previously" end)
    end
  end
end
