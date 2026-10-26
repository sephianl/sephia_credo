defmodule SephiaCredo.Checks.DeepLoadTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.DeepLoad

  test "flags a module attribute tree passed as load:" do
    """
    defmodule Reconcile do
      @si_load [products: [:batch, item: [default_uom_factor: [:uom]]], storage_unit: [:load_bearer]]

      def load_scan(code, opts) do
        StorageItem.get_by_code(code, Keyword.merge(opts, load: @si_load))
      end
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue ->
      assert issue.line_no == 5
      assert issue.message =~ "7 nodes (max 6)"
    end)
  end

  test "flags a literal tree passed to Ash.load" do
    """
    defmodule Sample do
      def run(units) do
        units
        |> Ash.load!(storage_items: [products: [:batch, :item]], storage_unit_items: [:item, :batch, :uom])
      end
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue -> assert issue.message =~ "8 nodes" end)
  end

  test "flags a read action's default load" do
    """
    defmodule Route do
      actions do
        read :by_id do
          prepare build(load: [stops: [orders: [:parcels, :client]], vehicle: [:type], driver: [:user]])
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue -> assert issue.line_no == 4 end)
  end

  test "ignores a small tree" do
    """
    defmodule Sample do
      def run(units), do: Ash.load(units, [:item, batch: [:lot]])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> refute_issues()
  end

  test "honours max_nodes" do
    """
    defmodule Sample do
      def run(units), do: Ash.load(units, [:item, batch: [:lot]])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad, max_nodes: 2)
    |> assert_issue()
  end
end
