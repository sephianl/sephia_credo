defmodule SephiaCredo.Checks.UnusedSetupKeysPerTestTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UnusedSetupKeysPerTest

  describe "consumption" do
    test "flags a test that consumes none of the in-scope keys" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "needs nothing" do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.trigger == "test"
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "a test consuming part of a shared fixture is not a defect" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2, admin: 3}
        end

        test "uses only company", %{company: c} do
          assert c
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "treats ctx.key access as consumption" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "via ctx", ctx do
          assert ctx.depot
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "treats a key a helper reads off the handed-over context as consumption" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "via a helper", ctx do
          assert analyze(ctx)
        end

        defp analyze(context), do: context.company
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "flags a test whose helper reads nothing off the context it was handed" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "via a helper", ctx do
          assert analyze(ctx)
        end

        defp analyze(_context), do: true
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "leaves a test alone when it hands the context to something unresolvable" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "via an imported helper", ctx do
          assert Support.Fixtures.analyze(ctx)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "underscore-prefixed bindings do not count as consumption" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "ignores both", %{company: _company, depot: _depot} do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "no issue when there is no setup in scope" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "stands alone" do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end
  end

  describe "scope" do
    test "in-scope keys are the union of module and describe setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        describe "with more" do
          setup do
            %{depot: 2}
          end

          test "needs nothing" do
            assert true
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "consuming a describe key is enough, even when the module key is untouched" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        describe "with more" do
          setup do
            %{depot: 2}
          end

          test "uses depot", %{depot: d} do
            assert d
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "a key the describe setup transformed is consumed through its replacement" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        describe "transforms the company" do
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
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "flags a module-level test that ignores the module setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        test "uses it", %{company: c} do
          assert c
        end

        test "does not" do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":company"
      end)
    end
  end

  describe "setup return patterns" do
    test "handles the {:ok, map} return" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          {:ok, %{company: 1, depot: 2}}
        end

        test "needs nothing" do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
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
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end
  end
end
