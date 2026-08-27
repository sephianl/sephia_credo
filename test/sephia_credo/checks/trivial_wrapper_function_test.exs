defmodule SephiaCredo.Checks.TrivialWrapperFunctionTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.TrivialWrapperFunction

  describe "flags a pure passthrough" do
    test "single-argument delegation" do
      """
      defmodule Sample do
        defp unpipe(ast), do: SephiaCredo.Ast.unpipe(ast)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> assert_issue(fn issue ->
        assert issue.trigger == "unpipe"
        assert issue.message =~ "SephiaCredo.Ast.unpipe"
      end)
    end

    test "multi-argument delegation in the same order" do
      """
      defmodule Sample do
        defp keep_every_n(list, n), do: Enum.take_every(list, n)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> assert_issue()
    end

    test "a do-block body that is still one call" do
      """
      defmodule Sample do
        defp destroy_temp_file(path) do
          File.rm(path)
        end
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> assert_issue()
    end
  end

  describe "does not flag a wrapper that does something" do
    test "supplies an extra argument" do
      """
      defmodule Sample do
        defp fetch(id), do: Repo.get(Thing, id)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "supplies an option" do
      """
      defmodule Sample do
        defp save(x), do: Repo.insert(x, returning: true)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "reorders the arguments" do
      """
      defmodule Sample do
        defp swap(a, b), do: Mod.call(b, a)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "transforms an argument" do
      """
      defmodule Sample do
        defp shout(text), do: Mod.emit(String.upcase(text))
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "matches a pattern in the head" do
      """
      defmodule Sample do
        defp name(%User{} = user), do: Accounts.name(user)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "carries a guard" do
      """
      defmodule Sample do
        defp count(list) when is_list(list), do: Enum.count(list)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "carries a default argument" do
      """
      defmodule Sample do
        defp take(list, n \\\\ 5), do: Enum.take(list, n)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "has more than one clause" do
      """
      defmodule Sample do
        defp render(nil), do: ""
        defp render(value), do: String.trim(value)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "has a second clause carrying a guard" do
      """
      defmodule Sample do
        defp size(list) when is_list(list), do: length(list)
        defp size(value), do: Kernel.byte_size(value)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "takes no arguments" do
      """
      defmodule Sample do
        defp now, do: DateTime.utc_now()
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "delegates to a local function rather than another module" do
      """
      defmodule Sample do
        defp shorter_name(x), do: some_longer_local_name(x)
        defp some_longer_local_name(x), do: String.trim(x, "-")
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "is public — that is what defdelegate is for" do
      """
      defmodule Sample do
        def radius(zone), do: Neighbourhood.radius_m(zone)
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "carries a rescue clause" do
      """
      defmodule Sample do
        defp safe_range(node) do
          Sourceror.get_range(node)
        rescue
          _ -> nil
        end
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "carries an after clause" do
      """
      defmodule Sample do
        defp close(pid) do
          StringIO.close(pid)
        after
          Process.unregister(:capture)
        end
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end

    test "body is a pipeline rather than a single call" do
      """
      defmodule Sample do
        defp clean(text), do: text |> String.trim() |> String.downcase()
      end
      """
      |> to_source_file()
      |> run_check(TrivialWrapperFunction)
      |> refute_issues()
    end
  end
end
