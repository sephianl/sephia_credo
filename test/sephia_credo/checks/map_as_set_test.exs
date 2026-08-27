defmodule SephiaCredo.Checks.MapAsSetTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.MapAsSet

  describe "flags membership against Map.keys" do
    test "flags Enum.member?(Map.keys(m), k)" do
      """
      defmodule Sample do
        def run(map, key) do
          Enum.member?(Map.keys(map), key)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Map.keys"
        assert issue.line_no == 3
      end)
    end

    test "flags the pipe form" do
      """
      defmodule Sample do
        def run(map, key) do
          map
          |> Map.keys()
          |> Enum.member?(key)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> assert_issue()
    end

    test "flags `key in Map.keys(map)`" do
      """
      defmodule Sample do
        def run(map, key) do
          key in Map.keys(map)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> assert_issue()
    end

    test "flags it inside a loop too" do
      """
      defmodule Sample do
        def run(keys, map) do
          Enum.filter(keys, fn k -> k in Map.keys(map) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> assert_issue()
    end

    test "flags each call site separately" do
      """
      defmodule Sample do
        def run(map, a, b) do
          Enum.member?(Map.keys(map), a) and b in Map.keys(map)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "does not flag" do
    test "Map.has_key?/2" do
      """
      defmodule Sample do
        def run(map, key) do
          Map.has_key?(map, key)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "Map.keys used for anything other than membership" do
      """
      defmodule Sample do
        def run(map) do
          map |> Map.keys() |> Enum.sort()
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "membership against Map.values" do
      """
      defmodule Sample do
        def run(map, value) do
          Enum.member?(Map.values(map), value)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "membership against a plain list" do
      """
      defmodule Sample do
        def run(list, key) do
          key in list
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "membership against a literal list" do
      """
      defmodule Sample do
        def run(key) do
          key in [:a, :b, :c]
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "MapSet.member?/2" do
      """
      defmodule Sample do
        def run(set, key) do
          MapSet.member?(set, key)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end

    test "a non-Map module's keys/1" do
      """
      defmodule Sample do
        def run(thing, key) do
          Enum.member?(Config.keys(thing), key)
        end
      end
      """
      |> to_source_file()
      |> run_check(MapAsSet)
      |> refute_issues()
    end
  end
end
