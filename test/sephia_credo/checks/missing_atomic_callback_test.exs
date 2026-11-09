defmodule SephiaCredo.Checks.MissingAtomicCallbackTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.MissingAtomicCallback

  defp change_module(name, callbacks) do
    """
    defmodule SephiaCredo.Fixtures.Pallet.Changes.#{name} do
      use Ash.Resource.Change

      #{callbacks}
    end
    """
  end

  @change "def change(changeset, _opts, _context), do: changeset"

  test "flags a change an update runs, and says to try making it atomic" do
    [issue] =
      "Recount"
      |> change_module(@change)
      |> to_source_file()
      |> run_check(MissingAtomicCallback)
      |> assert_issue()

    assert issue.line_no == 4
    assert issue.trigger == "change"
    assert issue.message =~ "`change/3` has no `atomic/3`"
    assert issue.message =~ "Try to make it atomic"
    assert issue.message =~ "{:not_atomic, \"the reason\"}"
  end

  test "flags a global change that runs on updates" do
    "Stamp"
    |> change_module(@change)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> assert_issue()
  end

  test "flags a validation, with the validation form of atomic/3" do
    [issue] =
      """
      defmodule SephiaCredo.Fixtures.Pallet.Validations.Fits do
        use Ash.Resource.Validation

        def validate(_changeset, _opts, _context), do: :ok
      end
      """
      |> to_source_file()
      |> run_check(MissingAtomicCallback)
      |> assert_issue()

    assert issue.message =~ "`validate/3` has no `atomic/3`"
    assert issue.message =~ "expr(error(...))"
  end

  test "flags a module no compiled resource uses" do
    "NotOnAnyResource"
    |> change_module(@change)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> assert_issue()
  end

  test "reports a module with change/3 and batch_change/3 once" do
    "Weigh"
    |> change_module("""
    def change(changeset, _opts, _context), do: changeset
      def batch_change(changesets, _opts, _context), do: changesets
    """)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> assert_issue()
  end

  test "flags a change that only defines batch_change/3" do
    [issue] =
      "Seal"
      |> change_module("def batch_change(changesets, _opts, _context), do: changesets")
      |> to_source_file()
      |> run_check(MissingAtomicCallback)
      |> assert_issue()

    assert issue.trigger == "batch_change"
  end

  test "accepts a change that says why it is not atomic" do
    "Recount"
    |> change_module("""
    def change(changeset, _opts, _context), do: changeset
      def atomic(_changeset, _opts, _context), do: {:not_atomic, "needs the row as it was"}
    """)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> refute_issues()
  end

  test "accepts a change that is atomic" do
    "Recount"
    |> change_module("""
    def change(changeset, _opts, _context), do: changeset
      def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
    """)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> refute_issues()
  end

  test "leaves alone a change only a create action runs, since atomic/3 is never called" do
    "Receive"
    |> change_module(@change)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> refute_issues()
  end

  test "leaves alone a global change scoped to creates" do
    "Number"
    |> change_module(@change)
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> refute_issues()
  end

  test "leaves alone a module that only happens to define change/3" do
    """
    defmodule SephiaCredo.Fixtures.NotAnAshChange do
      def change(changeset, _opts, _context), do: changeset
    end
    """
    |> to_source_file()
    |> run_check(MissingAtomicCallback)
    |> refute_issues()
  end
end
