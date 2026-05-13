defmodule SephiaCredo.Checks.SysGetStateWithoutTimeoutInPollTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.SysGetStateWithoutTimeoutInPoll

  describe "default poll function (wait_until)" do
    test "flags :sys.get_state/1 inside a wait_until fn" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn ->
            :sys.get_state(pid)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> assert_issue(fn issue ->
        assert issue.trigger == ":sys.get_state"
      end)
    end

    test "does not flag :sys.get_state/2 (with timeout)" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn ->
            :sys.get_state(pid, 100)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end

    test "does not flag when wrapped in try/catch :exit" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn ->
            try do
              :sys.get_state(pid)
            catch
              :exit, _ -> false
            end
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end
  end

  describe "outside a poll function" do
    test "does not flag :sys.get_state/1 at top level of a test" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          :sys.get_state(pid)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end

    test "does not flag inside Task.async fn (not a poll function)" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          Task.async(fn ->
            :sys.get_state(pid)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end

    test "does not flag in a fn assigned to a variable" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          f = fn -> :sys.get_state(pid) end
          f.()
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end
  end

  describe "configurable poll_functions" do
    test "flags inside eventually/1 when configured" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          eventually(fn ->
            :sys.get_state(pid)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll, poll_functions: [:eventually])
      |> assert_issue()
    end

    test "does not flag inside wait_until when only eventually is configured" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn ->
            :sys.get_state(pid)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll, poll_functions: [:eventually])
      |> refute_issues()
    end

    test "flags inside any configured function name" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          poll(fn ->
            :sys.get_state(pid)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll, poll_functions: [:poll, :wait_until])
      |> assert_issue()
    end
  end

  describe "multiple issues" do
    test "flags each offending call separately" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn -> :sys.get_state(a) end)
          wait_until(fn -> :sys.get_state(b) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end

  describe "no false positives" do
    test "does not flag :sys.get_state/1 inside wait_until's caller arg" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          # the unsafe call is *not* inside the polling fn
          state = :sys.get_state(pid)
          wait_until(fn -> something(state) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end

    test "does not flag a different :sys function" do
      ~S"""
      defmodule SampleTest do
        use ExUnit.Case

        test "x" do
          wait_until(fn ->
            :sys.statistics(pid, true)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(SysGetStateWithoutTimeoutInPoll)
      |> refute_issues()
    end
  end
end
