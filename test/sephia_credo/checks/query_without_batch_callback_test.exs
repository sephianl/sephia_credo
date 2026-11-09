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

    test "ignores a notifier that inserts a job for a unique worker" do
      """
      defmodule SyncDelegatedOrder do
        use Ash.Notifier

        alias SephiaCredo.Fixtures.UniqueJob

        def notify(%{data: data}), do: %{"id" => data.id} |> UniqueJob.new() |> Oban.insert()
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "flags the read a notifier makes after skipping a unique worker's insert" do
      """
      defmodule SyncDelegatedOrder do
        use Ash.Notifier

        alias SephiaCredo.Fixtures.Label
        alias SephiaCredo.Fixtures.UniqueJob

        def notify(%{data: %{delegated?: true} = data}), do: enqueue(data)

        def notify(%{data: data}) do
          case Label.get_by_code(data.code) do
            {:ok, _label} -> enqueue(data)
            {:error, _} -> :ok
          end
        end

        defp enqueue(data), do: %{"id" => data.id} |> UniqueJob.new() |> Oban.insert()
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue -> assert issue.message =~ "reaches `Label.get_by_code`" end)
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

    test "ignores a change whose transaction hooks do per-record work, even with an action hook that writes" do
      """
      defmodule ReorderStops do
        use Ash.Resource.Change

        alias Ash.Changeset

        @impl true
        def change(changeset, _opts, context) do
          changeset
          |> Changeset.before_transaction(&plan_chosen_stop(&1, context))
          |> Changeset.after_action(&apply_chosen_stop(&1, &2, context))
          |> Changeset.after_transaction(&recalculate(&1, &2, context))
        end

        defp plan_chosen_stop(changeset, context) do
          {:ok, route} = Ash.load(changeset.data, [:stops], actor: context.actor)
          Changeset.put_context(changeset, :plan, route.stops)
        end

        defp apply_chosen_stop(changeset, route, _context), do: Route.update(route, %{stops: changeset.context.plan})

        defp recalculate(_changeset, result, _context), do: result
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "ignores a query reached only through transaction hooks" do
      """
      defmodule CreateReorderedStopsConversation do
        use Ash.Resource.Change

        @impl true
        def change(changeset, _opts, context) do
          changeset
          |> Ash.Changeset.before_transaction(&remember_metrics/1)
          |> Ash.Changeset.after_transaction(fn _changeset, result -> post(result, context) end)
        end

        defp remember_metrics(changeset) do
          {:ok, route} = Ash.load(changeset.data, [:distance_m], authorize?: false)
          Ash.Changeset.put_context(changeset, :before, route.distance_m)
        end

        defp post({:ok, route} = result, context) do
          {:ok, _message} = Ash.create(Message, %{route_id: route.id}, actor: context.actor)
          result
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "still flags an action hook's query when the transaction hook does no work" do
      """
      defmodule LogsAfterCommit do
        use Ash.Resource.Change

        require Logger

        @impl true
        def change(changeset, _opts, context) do
          changeset
          |> Ash.Changeset.after_action(fn _changeset, record ->
            {:ok, _event} = Ash.create(Event, %{record_id: record.id}, actor: context.actor)
            {:ok, record}
          end)
          |> Ash.Changeset.after_transaction(fn _changeset, result ->
            Logger.info("done")
            result
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue(fn issue -> assert issue.message =~ "`change/3` reaches `Ash.create`" end)
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

    test "ignores a unique worker's insert in a hook" do
      """
      defmodule NotifyOnce do
        use Ash.Resource.Change

        alias SephiaCredo.Fixtures.UniqueJob

        def change(changeset, _opts, _context) do
          Ash.Changeset.after_action(changeset, fn _changeset, record ->
            {:ok, _job} = Oban.insert(UniqueJob.new(%{id: record.id}))
            {:ok, record}
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end
  end

  # `SephiaCredo.Fixtures.Pallet` lists these modules, and `PalletService` runs
  # its actions in bulk or one record at a time.
  describe "actions that run in bulk" do
    test "flags a change a resource lists in its global changes" do
      "Stamp" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> assert_issue()
    end

    test "flags a change on an action an Ash.bulk_update call names" do
      "Recount" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> assert_issue()
    end

    test "flags a change on an action whose code interface is handed a list" do
      "Seal" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> assert_issue()
    end

    test "flags a change on an action whose code interface is handed a public function's parameter" do
      "Shift" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> assert_issue()
    end

    test "ignores a change on an action whose caller takes the result as {:ok, record}" do
      "Weigh" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> refute_issues()
    end

    test "ignores a change on an action run on the one record a get interface found" do
      "Tag" |> pallet_change() |> run_check(QueryWithoutBatchCallback) |> refute_issues()
    end

    test "ignores a validation on an action that only runs on one record" do
      """
      defmodule SephiaCredo.Fixtures.Pallet.Validations.Fits do
        use Ash.Resource.Validation

        def validate(changeset, _opts, _context) do
          if Ash.exists?(Ledger), do: :ok, else: {:error, "no ledger"}
        end
      end
      """
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback)
      |> refute_issues()
    end

    test "still flags a module no compiled resource uses" do
      "NotOnAnyAction"
      |> pallet_change()
      |> run_check(QueryWithoutBatchCallback)
      |> assert_issue()
    end
  end

  describe "allow" do
    @lookup """
    defmodule Lookup do
      use Ash.Resource.Validation

      def validate(_changeset, _opts, _context), do: if(Ash.exists?(Ledger), do: :ok, else: {:error, "none"})
    end
    """

    test "leaves alone a callback an entry names" do
      @lookup
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback,
        allow: [{Lookup, :validate, "Bulk callers set skip_lookup in the context"}]
      )
      |> refute_issues()
    end

    test "still flags a callback no entry names" do
      @lookup
      |> to_source_file()
      |> run_check(QueryWithoutBatchCallback, allow: [{Lookup, :change, "Not this one"}])
      |> assert_issue()
    end

    test "refuses an entry without a reason" do
      assert_raise ArgumentError, ~r/reason/, fn ->
        @lookup
        |> to_source_file()
        |> run_check(QueryWithoutBatchCallback, allow: [{Lookup, :validate}])
      end
    end
  end

  defp pallet_change(name) do
    to_source_file("""
    defmodule SephiaCredo.Fixtures.Pallet.Changes.#{name} do
      use Ash.Resource.Change

      def change(changeset, _opts, _context) do
        Ash.Changeset.before_action(changeset, fn changeset ->
          _rows = Ash.read!(Ledger)
          changeset
        end)
      end
    end
    """)
  end
end
