defmodule SephiaCredo.Checks.UnneededRequireAtomicFalseTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UnneededRequireAtomicFalse

  @source """
  defmodule SephiaCredo.Fixtures.Bin do
    use Ash.Resource, domain: SephiaCredo.Fixtures.Domain

    actions do
      update :set_zone do
        require_atomic? false
        argument :zone_id, :uuid
        change set_attribute(:zone_id, arg(:zone_id))
        validate present(:zone_id)
      end

      update :with_hook do
        require_atomic? false
        change fn changeset, _context -> changeset end
      end

      destroy :purge do
        require_atomic? false
      end
    end
  end
  """

  test "flags actions whose changes and validations are all atomic" do
    issues =
      @source
      |> to_source_file()
      |> run_check(UnneededRequireAtomicFalse)
      |> assert_issues()

    assert issues |> Enum.map(& &1.line_no) |> Enum.sort() == [6, 18]
    assert Enum.any?(issues, &(&1.message =~ "`update :set_zone` sets `require_atomic? false`"))
  end

  test "ignores an action with an anonymous change" do
    @source
    |> to_source_file()
    |> run_check(UnneededRequireAtomicFalse)
    |> Enum.each(&refute(&1.line_no == 14))
  end

  test "reads a fragment's actions from the resource that includes it" do
    """
    defmodule SephiaCredo.Fixtures.Crate.Actions do
      use Spark.Dsl.Fragment, of: Ash.Resource

      actions do
        update :relabel do
          require_atomic? false
          change set_attribute(:label, "relabelled")
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(UnneededRequireAtomicFalse)
    |> assert_issue(fn issue -> assert issue.line_no == 6 end)
  end

  test "ignores a module that is not a compiled resource" do
    """
    defmodule NotCompiled do
      use Ash.Resource

      actions do
        update :set_zone do
          require_atomic? false
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(UnneededRequireAtomicFalse)
    |> refute_issues()
  end
end
