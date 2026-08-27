defmodule SephiaCredo.Checks.EnumAtInLoopTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.EnumAtInLoop

  describe "flags a computed index inside a loop" do
    test "flags Enum.at inside Enum.map" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn i -> Enum.at(rows, i) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Enum.at"
        assert issue.line_no == 3
      end)
    end

    test "flags Enum.at inside Enum.with_index/map destructure" do
      """
      defmodule Sample do
        def run(rows, cols) do
          rows
          |> Enum.with_index()
          |> Enum.map(fn {_row, i} -> Enum.at(cols, i) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags Enum.at inside a for comprehension" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          for i <- indexes, do: Enum.at(rows, i)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags Enum.at inside a capture" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, &Enum.at(rows, &1))
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags Enum.at/3 with a default" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.each(indexes, fn i -> Enum.at(rows, i, nil) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags an arithmetic index" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn i -> Enum.at(rows, i + 1) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags each call site separately" do
      """
      defmodule Sample do
        def run(indexes, rows, cols) do
          Enum.map(indexes, fn i ->
            {Enum.at(rows, i), Enum.at(cols, i)}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "does not flag" do
    test "an integer literal index" do
      """
      defmodule Sample do
        def run(rows) do
          Enum.map(rows, fn r -> Enum.at(r, 0) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "a larger integer literal index" do
      """
      defmodule Sample do
        def run(rows) do
          Enum.map(rows, fn r -> Enum.at(r, 3) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "Enum.at outside any loop" do
      """
      defmodule Sample do
        def run(rows, i) do
          Enum.at(rows, i)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "Enum.at in the collection a loop iterates over" do
      """
      defmodule Sample do
        def run(rows, i) do
          Enum.map(Enum.at(rows, i), fn r -> r.id end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "Enum.at in a for comprehension's generator source" do
      """
      defmodule Sample do
        def run(rows, i) do
          for r <- Enum.at(rows, i), do: r.id
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "a different Enum function inside a loop" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn i -> Enum.find(rows, &(&1.id == i)) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end

    test "a non-Enum module's at/2" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn i -> Grid.at(rows, i) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end
  end

  describe "negative literal index" do
    test "flags a negative literal index, which is not bounded by the literal" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn _i -> Enum.at(rows, -1) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Enum.at"
        assert issue.message =~ "before the loop"
      end)
    end

    test "a non-negative literal index is still exempt" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Enum.map(indexes, fn _i -> Enum.at(rows, 3) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> refute_issues()
    end
  end

  describe "Stream and Task iteration" do
    test "flags Enum.at inside Stream.map" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          indexes
          |> Stream.map(fn i -> Enum.at(rows, i) end)
          |> Enum.to_list()
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end

    test "flags Enum.at inside Task.async_stream" do
      """
      defmodule Sample do
        def run(indexes, rows) do
          Task.async_stream(indexes, fn i -> Enum.at(rows, i) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(EnumAtInLoop)
      |> assert_issue()
    end
  end
end
