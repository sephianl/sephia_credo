defmodule SephiaCredo.Checks.DeepLoadTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.DeepLoad

  test "counts the stored relationships of a read action's default load" do
    """
    defmodule SephiaCredo.Fixtures.Label do
      use Ash.Resource

      actions do
        read :with_family do
          prepare build(load: [:crate, :child_count, :origin, :twin, parent: [:origin, :twin, parent: [:bin]]])
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue ->
      assert issue.line_no == 6
      assert issue.message =~ "6 relationships of `SephiaCredo.Fixtures.Label` (max 4)"
      assert issue.message =~ "origin, twin, parent, parent.origin, parent.twin, parent.parent"
    end)
  end

  test "leaves out aggregates and relationships into resources kept in memory" do
    """
    defmodule Sample do
      def run, do: Ash.read(SephiaCredo.Fixtures.Label, load: [:crate, :bin, :child_count, :origin, :twin, :parent])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> refute_issues()
  end

  test "follows a module attribute passed to a code interface" do
    """
    defmodule Reconcile do
      alias SephiaCredo.Fixtures.Label

      @label_load [:origin, :twin, parent: [:origin, :twin]]

      def load_label(code), do: Label.get_by_code(code, load: @label_load)
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue -> assert issue.message =~ "5 relationships" end)
  end

  test "follows module attributes nested in the tree and joined with ++" do
    """
    defmodule Reconcile do
      alias SephiaCredo.Fixtures.Label

      @parent_load [:origin, :twin]
      @label_load [:origin, parent: @parent_load] ++ [:twin]

      def load_label(code), do: Label.get_by_code(code, load: @label_load)
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issue(fn issue ->
      assert issue.message =~ "5 relationships"
      assert issue.message =~ "parent.origin"
    end)
  end

  test "reads the resource from Ash.read and Ash.Query.load" do
    """
    defmodule Sample do
      alias SephiaCredo.Fixtures.Label

      def run do
        Ash.read(Label, load: [:origin, :twin, parent: [:origin, :twin]])

        Label
        |> Ash.Query.for_read(:read)
        |> Ash.Query.load([:origin, :twin, parent: [:origin, :twin, :parent]])
        |> Ash.read()
      end
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> assert_issues()
    |> then(&assert(length(&1) == 2))
  end

  test "ignores a load whose resource it cannot know" do
    """
    defmodule Sample do
      def run(records), do: Ash.load(records, [:origin, :twin, parent: [:origin, :twin, :parent]])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> refute_issues()
  end

  test "ignores a load within max_relationships" do
    """
    defmodule Sample do
      def run, do: Ash.read(SephiaCredo.Fixtures.Label, load: [:origin, parent: [:twin]])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad)
    |> refute_issues()
  end

  test "honours max_relationships" do
    """
    defmodule Sample do
      def run, do: Ash.read(SephiaCredo.Fixtures.Label, load: [:origin, parent: [:twin]])
    end
    """
    |> to_source_file()
    |> run_check(DeepLoad, max_relationships: 2)
    |> assert_issue()
  end
end
