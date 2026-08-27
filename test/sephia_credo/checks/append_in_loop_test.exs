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

  describe "accumulator on the right (no issues)" do
    test "does not flag prepending a bounded list onto the accumulator" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
            case build(item) do
              {:ok, finalized} -> {:cont, {:ok, finalized ++ acc}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag a loop-invariant list built for a call" do
      """
      defmodule Sample do
        def run(stops, opts) do
          Enum.reduce(stops, [], fn stop, acc ->
            unassign(stop, opts ++ [authorize?: false])
            [stop | acc]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag a function result concatenated onto the accumulator" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn item, acc ->
            List.wrap(item) ++ acc
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag a divide-and-conquer join in a recursive function" do
      """
      defmodule Sample do
        def simplify(points, a, b, eps) do
          {imax, dmax} = farthest(points, a, b)

          if dmax > eps and imax do
            right_pts = Enum.drop(points, imax)
            split = hd(right_pts)
            left = points |> Enum.take(imax + 1) |> simplify(a, split, eps)
            right = simplify(right_pts, split, b, eps)
            left ++ tl(right)
          else
            [a, b]
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag a fold that feeds the accumulator back in" do
      """
      defmodule Sample do
        def run(checks, route) do
          Enum.reduce(checks, [], fn check, acc ->
            acc ++ check.analyze(route, acc, [])
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag a guarded reducer clause appending a non-accumulator" do
      """
      defmodule Sample do
        def run(statements) do
          Enum.reduce(statements, [], fn
            {kind, _, [head | _rest]}, pairs when kind in [:def, :defp] ->
              pair(head) ++ pairs

            _statement, pairs ->
              pairs
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "still flags a guarded reducer clause appending to the accumulator" do
      """
      defmodule Sample do
        def run(items) do
          Enum.reduce(items, [], fn item, acc when is_binary(item) ->
            acc ++ [item]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "does not flag a variable destructured out of a recursive parameter" do
      """
      defmodule Sample do
        defp generate([{:label, t, _} | parsecs], mod, acc) do
          generate(t ++ parsecs, mod, acc)
        end

        defp generate([], _mod, acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "still flags a whole recursive parameter that grows" do
      """
      defmodule Sample do
        defp walk([h | t], acc), do: walk(t, acc ++ [h])
        defp walk([], acc), do: acc
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
    end

    test "does not flag the bounded half of a destructured reducer result" do
      """
      defmodule Sample do
        def run(results, stats) do
          Enum.reduce(results, {[], stats}, fn result, {works, acc} ->
            {work, acc} = collect(result, acc)
            {work ++ works, acc}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end
  end

  describe "capture accumulators" do
    test "does not flag a capture that never receives the accumulator" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], fn group, acc ->
            [Enum.map(group, &(&1 ++ [:tag])) | acc]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "does not flag `&1 ++ &2` in a reducer capture, where `&1` is the element" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, [], &(&1 ++ &2))
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> refute_issues()
    end

    test "flags `&1 ++ [item]` inside a loop" do
      """
      defmodule Sample do
        def run(list) do
          Enum.reduce(list, %{}, fn {key, item}, acc ->
            Map.update(acc, key, [item], &(&1 ++ [item]))
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(AppendInLoop)
      |> assert_issue()
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
