defmodule SephiaCredo.Checks.AppendInLoopTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.AppendInLoop

  describe "Enum.reduce" do
    test "flags ++ inside reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            acc ++ [item]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "++"
      end)
    end

    test "flags [a | b] ++ rest inside reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            [item | acc] ++ [trailing()]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "allows [item | acc] prepend inside reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            [item | acc]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows [item] ++ list (single-element prepend) inside reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            [item] ++ acc
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end
  end

  describe "Enum.reduce_while" do
    test "flags ++ inside reduce_while" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce_while(list, [], fn item, acc ->
            {:cont, acc ++ [item]}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "Enum.map_reduce" do
    test "flags ++ inside map_reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.map_reduce(list, [], fn item, acc ->
            {item, acc ++ [item]}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "Enum.scan" do
    test "flags ++ inside scan" do
      """
      defmodule Sample do
        def run(list) do
          Enum.scan(list, [], fn item, acc ->
            acc ++ [item]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "Enum.flat_map_reduce" do
    test "flags ++ inside flat_map_reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.flat_map_reduce(list, [], fn item, acc ->
            {[item], acc ++ [item]}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "List.foldl/foldr" do
    test "flags ++ inside List.foldl" do
      """
      defmodule Sample do
        def run(list) do
          List.foldl(list, [], fn item, acc ->
            acc ++ [item]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "flags ++ inside List.foldr" do
      """
      defmodule Sample do
        def run(list) do
          List.foldr(list, [], fn item, acc ->
            acc ++ [item]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "for/reduce comprehension" do
    test "flags ++ inside for/reduce" do
      """
      defmodule Sample do
        def run(list) do
          for item <- list, reduce: [] do
            acc -> acc ++ [item]
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "recursive functions" do
    test "flags ++ inside a recursive function" do
      """
      defmodule Sample do
        def collect([head | tail], acc) do
          collect(tail, acc ++ [head])
        end

        def collect([], acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "flags ++ inside a recursive function with guard" do
      """
      defmodule Sample do
        defp do_work(items, acc) when items != [] do
          [head | tail] = items
          do_work(tail, acc ++ [head])
        end

        defp do_work([], acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "does not flag same-name different-arity function" do
      """
      defmodule Sample do
        def process(list) do
          process(list, [])
        end

        def process([head | tail], acc) do
          process(tail, [head | acc])
        end

        def process([], acc), do: acc

        def transform(items) do
          items ++ extra()
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "flags only the recursive arity, not a different arity with same name" do
      """
      defmodule Sample do
        def collect(list) do
          list ++ [extra()]
        end

        def collect([head | tail], acc) do
          collect(tail, acc ++ [head])
        end

        def collect([], acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "++"
        assert issue.line_no == 7
      end)
    end

    test "flags ++ inside a recursive defp" do
      """
      defmodule Sample do
        defp build([head | tail], acc) do
          build(tail, acc ++ [head])
        end

        defp build([], acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end
  end

  describe "non-loop contexts (no issues)" do
    test "allows ++ outside of any loop" do
      """
      defmodule Sample do
        def run(a, b) do
          a ++ b
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows ++ in Enum.map (not a reduce)" do
      """
      defmodule Sample do
        def run(list) do
          Enum.map(list, fn item -> [item] ++ other() end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows ++ in a non-recursive function" do
      """
      defmodule Sample do
        def process(list) do
          list ++ [extra()]
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows for comprehension without reduce" do
      """
      defmodule Sample do
        def run(list) do
          for item <- list do
            [item] ++ other()
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows ++ in Enum.flat_map (not a reduce)" do
      """
      defmodule Sample do
        def run(list) do
          Enum.flat_map(list, fn item -> item ++ other() end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "allows ++ in a function that only calls a different-arity overload" do
      """
      defmodule Sample do
        def flatten(list) do
          list ++ extras()
        end

        def flatten(list, opts) do
          flatten(filter(list, opts))
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end
  end

  describe "multiple issues" do
    test "flags multiple ++ in the same reduce" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            result = acc ++ [item]
            result ++ extra()
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end
end
