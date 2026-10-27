defmodule SephiaCredo.Checks.QueryWithoutBatchCallbackTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.QueryWithoutBatchCallback

  describe "validations" do
    test "flags validate/3 that reads through a code interface" do
      """
      defmodule SuMatchesSampleClass do
        use Ash.Resource.Validation

        alias SephiaCredo.Fixtures.Label

        @impl true
        def validate(changeset, _opts, _context) do
          case Label.get_by_code(changeset.data.code) do
            {:ok, _label} -> :ok
            error -> error
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue ->
        assert issue.line_no == 7
        assert issue.trigger == "validate"
        assert issue.message =~ "`validate/3` reaches `Label.get_by_code`"
        assert issue.message =~ "Define `batch_validate/3`"
      end)
    end

    test "flags a query reached through a private helper" do
      """
      defmodule HasNoProducts do
        use Ash.Resource.Validation

        @impl true
        def validate(changeset, _opts, _context), do: check(changeset.data)

        defp check(unit) do
          if Ash.exists?(Product), do: {:error, field: :id, message: "has products"}, else: :ok
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue ->
        assert issue.message =~ "`check/1`, which reaches `Ash.exists?` (line 8)"
      end)
    end

    test "says an atomic bulk action goes through atomic/3 instead" do
      """
      defmodule OrderNotOnActiveRoute do
        use Ash.Resource.Validation

        def validate(changeset, _opts, _context), do: if(Ash.exists?(Route), do: {:error, "on route"}, else: :ok)
        def atomic(_changeset, _opts, _context), do: :ok
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue -> assert issue.message =~ "that does not run atomically" end)
    end

    test "ignores a validation that defines batch_validate/3" do
      """
      defmodule Batched do
        use Ash.Resource.Validation

        def validate(changeset, _opts, _context), do: check(Ash.read!(Thing), changeset)
        def batch_validate(changesets, _opts, _context), do: Enum.map(changesets, &check(Ash.read!(Thing), &1))
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "ignores a validation that does not query" do
      """
      defmodule Positive do
        use Ash.Resource.Validation

        def validate(changeset, _opts, _context) do
          if Ash.Changeset.get_attribute(changeset, :quantity) > 0, do: :ok, else: {:error, "negative"}
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end
  end

  describe "notifiers" do
    test "flags a read in notify/1 and points at load/2" do
      """
      defmodule SyncDelegatedOrder do
        use Ash.Notifier

        alias SephiaCredo.Fixtures.Label

        def notify(%{data: %{code: code}}) do
          case Label.get_by_code(code) do
            {:ok, _label} -> :ok
            {:error, _} -> :ok
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue ->
        assert issue.trigger == "notify"
        assert issue.message =~ "once per notification"
        assert issue.message =~ "`load/2`"
      end)
    end

    test "points a write in notify/1 at a signal" do
      """
      defmodule Audit do
        @behaviour Ash.Notifier

        def notify(notification), do: Ash.create(AuditEntry, %{id: notification.data.id})
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue -> assert issue.message =~ "Ash.Signals" end)
    end

    test "ignores a notifier that does not query" do
      """
      defmodule Broadcast do
        use Ash.Notifier

        def notify(notification), do: Phoenix.PubSub.broadcast(MyPubSub, "t", notification)
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end
  end

  describe "changes" do
    test "flags a query in an after_action hook" do
      """
      defmodule RecordBatchEvent do
        use Ash.Resource.Change

        @impl true
        def change(changeset, _opts, context) do
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            {:ok, _event} = Ash.create(Event, %{record_id: record.id}, actor: context.actor)
            {:ok, record}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue ->
        assert issue.message =~ "`change/3` reaches `Ash.create`"
        assert issue.message =~ "after_batch/3"
        assert issue.message =~ "Ash.Signals"
      end)
    end

    test "flags an Oban insert wrapped by a worker, in an after_action hook" do
      """
      defmodule EmailTrackAndTraceOnceReceived do
        use Ash.Resource.Change

        alias SephiaCredo.Fixtures.EmailJob

        def change(changeset, _opts, _context), do: Ash.Changeset.after_action(changeset, &enqueue/2)

        defp enqueue(_changeset, parcel) do
          with {:ok, _job} <- EmailJob.enqueue(parcel), do: {:ok, parcel}
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue -> assert issue.message =~ "reaches `EmailJob.enqueue`" end)
    end

    test "ignores building a worker's job without inserting it" do
      """
      defmodule BuildsJob do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          _job = SephiaCredo.Fixtures.EmailJob.new(%{id: changeset.data.id})
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "flags a query directly in change/3" do
      """
      defmodule EnrichStopId do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          order = Ash.get!(Order, Ash.Changeset.get_attribute(changeset, :order_id))
          Ash.Changeset.force_change_attribute(changeset, :stop_id, order.stop_id)
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue()
    end

    test "ignores a change that defines batch_change/3" do
      """
      defmodule EnrichStopId do
        use Ash.Resource.Change

        def change(changeset, opts, context), do: changeset |> List.wrap() |> batch_change(opts, context) |> hd()

        def batch_change(changesets, _opts, _context) do
          orders = Ash.read!(Order)
          Enum.map(changesets, &put_stop(&1, orders))
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "ignores a module that is not a change or validation" do
      """
      defmodule Helpers do
        def change(changeset, _opts, _context), do: Ash.update!(changeset)
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end
  end
end
