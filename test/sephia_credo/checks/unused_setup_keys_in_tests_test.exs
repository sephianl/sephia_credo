defmodule SephiaCredo.Checks.UnusedSetupKeysInTestsTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UnusedSetupKeysInTests

  describe "describe-local setup" do
    test "flags keys never used by any test in the describe" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "heavy setup" do
          setup do
            %{company: 1, depot: 2, admin: 3, route: 4}
          end

          test "uses company and admin", %{company: c, admin: a} do
            assert {c, a}
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":depot"
        assert issue.message =~ ":route"
        refute issue.message =~ ":company"
        refute issue.message =~ ":admin"
      end)
    end

    test "flags single unused key in a 2-key setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "small setup" do
          setup do
            %{admin: 1, company: 2}
          end

          test "uses one", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        refute issue.message =~ ":admin"
      end)
    end

    test "no issue when every key is used by some test" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "all keys covered" do
          setup do
            %{company: 1, depot: 2, admin: 3}
          end

          test "uses company and depot", %{company: c, depot: d} do
            assert {c, d}
          end

          test "uses admin", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end

    test "no issue when describe has no setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "no setup" do
          test "something" do
            assert true
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end
  end

  describe "module-level setup" do
    test "flags keys never used by any test in the module" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2, admin: 3, conversation: 4}
        end

        describe "uses one key" do
          test "uses admin", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
        assert issue.message =~ ":conversation"
        refute issue.message =~ ":admin"
      end)
    end

    test "considers tests across multiple describes when checking module-level setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        describe "first" do
          test "uses company", %{company: c} do
            assert c
          end
        end

        describe "second" do
          test "uses depot", %{depot: d} do
            assert d
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end

    test "counts describe-local setup destructures as use of module-level keys" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2, admin: 3}
        end

        describe "consumes company via inner setup" do
          setup %{company: company} do
            %{thing: company}
          end

          test "uses thing", %{thing: t} do
            assert t
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":depot"
        assert issue.message =~ ":admin"
        refute issue.message =~ ":company"
      end)
    end

    test "considers module-level tests outside any describe" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "uses company", %{company: c} do
          assert c
        end

        test "uses depot", %{depot: d} do
          assert d
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end
  end

  describe "context destructure" do
    test "underscore-prefixed bindings do not count as used" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "underscored" do
          setup do
            %{company: 1, admin: 2}
          end

          test "ignores company", %{company: _company, admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        refute issue.message =~ ":admin"
      end)
    end

    test "treats `context.key` access in test body as use" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "context access" do
          setup do
            %{company: 1, depot: 2, admin: 3}
          end

          test "uses context.company and context.admin", context do
            assert context.company
            assert context.admin
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":depot"
        refute issue.message =~ ":company"
        refute issue.message =~ ":admin"
      end)
    end

    test "treats `ctx.key` after `%{...} = ctx` match as use" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "destructure plus binding" do
          setup do
            %{company: 1, depot: 2, admin: 3}
          end

          test "uses admin via destructure and depot via ctx", %{admin: a} = ctx do
            assert a
            assert ctx.depot
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        refute issue.message =~ ":admin"
        refute issue.message =~ ":depot"
      end)
    end

    test "no false positive when whole context is bound but never accessed via dot" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "context bound" do
          setup do
            %{company: 1, depot: 2}
          end

          test "uses context as helper arg", context do
            assert helper(context)
          end

          defp helper(_), do: true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "counts keys a helper reads off the context it was handed" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "helper reads the context" do
          setup do
            %{model: 1, depot: 2}
          end

          test "hands the whole context to a helper", ctx do
            assert analyze(ctx)
          end

          defp analyze(context), do: context.model
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":depot"
        refute issue.message =~ ":model"
      end)
    end

    test "counts keys a helper destructures from its parameter" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "helper destructures" do
          setup do
            %{model: 1, depot: 2}
          end

          test "hands the whole context to a helper", ctx do
            assert analyze(ctx, :arg)
          end

          defp analyze(%{model: model}, _arg), do: model
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":depot"
        refute issue.message =~ ":model"
      end)
    end

    test "follows the context through a chain of helpers" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "helper chain" do
          setup do
            %{model: 1, depot: 2}
          end

          test "hands the whole context to a helper", ctx do
            assert analyze(ctx)
          end

          defp analyze(context), do: solve(context)
          defp solve(context), do: context.model
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":depot"
        refute issue.message =~ ":model"
      end)
    end

    test "follows a context piped into a helper" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "piped context" do
          setup do
            %{model: 1, depot: 2}
          end

          test "pipes the context into a helper", ctx do
            assert ctx |> analyze(:arg)
          end

          defp analyze(context, _arg), do: context.model
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":depot"
        refute issue.message =~ ":model"
      end)
    end

    test "follows a context copy built with the map update syntax" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "context copy" do
          setup do
            %{model: 1, depot: 2}
          end

          test "rewrites one key, then hands the copy to a helper", ctx do
            copy = %{ctx | depot: 3}

            assert analyze(copy)
          end

          defp analyze(context), do: context.model
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end

    test "a helper it cannot resolve consumes every key, rather than none" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "imported helper" do
          setup do
            %{model: 1, depot: 2}
          end

          test "hands the context to an imported helper", ctx do
            assert Support.Fixtures.analyze(ctx)
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end

    test "test without context match flags all keys as unused" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "no destructure" do
          setup do
            %{company: 1, admin: 2}
          end

          test "needs nothing" do
            assert true
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "setup"
        assert issue.message =~ ":company"
        assert issue.message =~ ":admin"
      end)
    end
  end

  describe "setup return patterns" do
    test "handles {:ok, map} tuple return" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "tuple return" do
          setup do
            {:ok, %{company: 1, depot: 2, admin: 3}}
          end

          test "uses one", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "handles setup with context pattern match argument" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        describe "context setup" do
          setup %{conn: conn} do
            %{conn: conn, company: 1, depot: 2, admin: 3}
          end

          test "uses one", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysInTests)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":conn"
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end
  end

  describe "non-test files" do
    test "ignores files that don't end in _test.exs" do
      """
      defmodule SampleModule do
        def foo, do: :ok
      end
      """
      |> to_source_file("sample.ex")
      |> run_check(UnusedSetupKeysInTests)
      |> refute_issues()
    end
  end
end
