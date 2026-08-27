defmodule SephiaCredo.Checks.PatternMatchInFunctionHeadTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.PatternMatchInFunctionHead

  describe "flags a single clause dispatching on its own parameter" do
    test "case on a parameter as the whole body" do
      """
      defmodule Sample do
        defp handle(result) do
          case result do
            {:ok, value} -> value
            {:error, reason} -> log(reason)
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> assert_issue(fn issue ->
        assert issue.trigger == "handle"
        assert issue.message =~ "case` on `result`"
      end)
    end

    test "public functions too" do
      """
      defmodule Sample do
        def fix(level) do
          case level do
            :low -> :ignore
            :high -> :escalate
            _ -> :review
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> assert_issue()
    end

    test "dispatching on a later parameter" do
      """
      defmodule Sample do
        def apply_to(record, action) do
          case action do
            :create -> insert(record)
            :delete -> remove(record)
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> assert_issue()
    end
  end

  describe "does not flag" do
    test "a case on a computed value" do
      """
      defmodule Sample do
        def run(record) do
          case classify(record) do
            :a -> 1
            :b -> 2
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a case that is only part of the body" do
      """
      defmodule Sample do
        def run(value) do
          Logger.info("starting")

          case value do
            :a -> 1
            :b -> 2
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a function that already has multiple clauses" do
      """
      defmodule Sample do
        def run(nil), do: :none

        def run(value) do
          case value do
            :a -> 1
            :b -> 2
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a head carrying a guard" do
      """
      defmodule Sample do
        def run(value) when is_atom(value) do
          case value do
            :a -> 1
            :b -> 2
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a single-clause case, which is not a dispatch" do
      """
      defmodule Sample do
        def run(value) do
          case value do
            %{id: id} -> id
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a case on a variable bound inside the body" do
      """
      defmodule Sample do
        def run(record) do
          value = normalize(record)

          case value do
            :a -> 1
            :b -> 2
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a function that also carries a rescue clause" do
      """
      defmodule Sample do
        def run(value) do
          case value do
            :a -> parse!(value)
            :b -> :skip
          end
        rescue
          _ -> :error
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end

    test "a cond, which has no patterns to move" do
      """
      defmodule Sample do
        def run(value) do
          cond do
            value > 10 -> :big
            true -> :small
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PatternMatchInFunctionHead)
      |> refute_issues()
    end
  end
end
