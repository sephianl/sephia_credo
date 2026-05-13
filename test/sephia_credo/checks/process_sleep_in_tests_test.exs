defmodule SephiaCredo.Checks.ProcessSleepInTestsTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.ProcessSleepInTests

  describe "test files" do
    test "flags Process.sleep/1 in a test body" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "does a thing" do
          Process.sleep(100)
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Process.sleep"
      end)
    end

    test "flags Process.sleep inside a setup block" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          Process.sleep(50)
          :ok
        end

        test "noop", do: assert true
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issue()
    end

    test "flags Process.sleep inside a setup_all block" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup_all do
          Process.sleep(50)
          :ok
        end

        test "noop", do: assert true
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issue()
    end

    test "flags Process.sleep with a variable argument" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "wait" do
          ms = 100
          Process.sleep(ms)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issue()
    end

    test "flags multiple Process.sleep calls separately" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "wait" do
          Process.sleep(10)
          Process.sleep(20)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end

    test "flags Process.sleep inside a helper test path" do
      """
      defmodule MyApp.SomethingTest do
        use ExUnit.Case

        test "x" do
          Process.sleep(1)
          assert true
        end
      end
      """
      |> to_source_file("nested/path/something_test.exs")
      |> run_check(ProcessSleepInTests)
      |> assert_issue()
    end
  end

  describe "non-test files" do
    test "does not flag Process.sleep in a .ex source file" do
      """
      defmodule Sample do
        def wait do
          Process.sleep(100)
        end
      end
      """
      |> to_source_file("sample.ex")
      |> run_check(ProcessSleepInTests)
      |> refute_issues()
    end

    test "does not flag Process.sleep in test/support/ helpers" do
      """
      defmodule MyApp.TestSupport.Waiter do
        def wait do
          Process.sleep(100)
        end
      end
      """
      |> to_source_file("test/support/waiter.ex")
      |> run_check(ProcessSleepInTests)
      |> refute_issues()
    end
  end

  describe "no false positives" do
    test "does not flag :timer.sleep" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "wait" do
          :timer.sleep(100)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> refute_issues()
    end

    test "does not flag a custom MyModule.sleep" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        test "wait" do
          MyModule.sleep(100)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> refute_issues()
    end

    test "does not flag a local sleep/1 function" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        defp sleep(n), do: :timer.sleep(n)

        test "wait" do
          sleep(100)
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(ProcessSleepInTests)
      |> refute_issues()
    end
  end
end
