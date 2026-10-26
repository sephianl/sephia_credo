defmodule SephiaCredo.Checks.RollbackOnSuccessTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.RollbackOnSuccess

  test "flags a rollback on the {:ok, _} branch" do
    """
    defmodule Reconcile do
      defp dry_run(load_bearer, actionable, opts) do
        Repo.transaction(fn ->
          case run(load_bearer, actionable, opts) do
            {:ok, stats} -> Repo.rollback({:planned, stats})
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test "flags a rollback as the transaction's last expression" do
    """
    defmodule Preview do
      def run(changes) do
        MyApp.Repo.transaction(fn ->
          Enum.each(changes, &apply_change/1)
          MyApp.Repo.rollback(:preview)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> assert_issue(fn issue -> assert issue.line_no == 5 end)
  end

  test "flags a rollback on a guarded ok branch inside a piped function" do
    """
    defmodule Preview do
      def run(x) do
        x
        |> build()
        |> then(fn built ->
          Repo.transaction(fn ->
            case write(built) do
              {:ok, result, _notifications} when is_map(result) -> Repo.rollback(result)
              error -> Repo.rollback(error)
            end
          end)
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> assert_issue(fn issue -> assert issue.line_no == 8 end)
  end

  test "ignores a rollback on the error path" do
    """
    defmodule Commit do
      def run(load_bearer, scans) do
        Repo.transaction(fn ->
          case write(load_bearer, scans) do
            {:ok, stats} -> stats
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> refute_issues()
  end

  test "ignores a rollback on a read that found nothing" do
    """
    defmodule Flush do
      def commit_cart(ctx, opts) do
        Repo.transaction(fn ->
          with {:ok, order} when order != nil <- ProductionOrder.get_by_id(ctx.order_id, opts),
               {:ok, updated} <- ProductionOrder.record_cart_commit(order, opts) do
            updated
          else
            {:ok, nil} -> Repo.rollback(:order_not_found)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> refute_issues()
  end

  test "ignores a rollback outside a transaction function" do
    """
    defmodule Helper do
      def abort({:ok, value}), do: Repo.rollback(value)
    end
    """
    |> to_source_file()
    |> run_check(RollbackOnSuccess)
    |> refute_issues()
  end
end
