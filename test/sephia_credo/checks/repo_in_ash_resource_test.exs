defmodule SephiaCredo.Checks.RepoInAshResourceTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.RepoInAshResource

  describe "flags raw Repo access" do
    test "flags Repo.query! running an UPDATE inside a change module" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Zelo.Repo.query!(
            \"\"\"
            UPDATE orders SET current_stop_id = $1 WHERE id = $2
            \"\"\",
            [stop_id, order_id]
          )

          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Zelo.Repo.query!"
        assert issue.line_no == 5
      end)
    end

    test "flags Repo.query! whose SQL is a variable" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.query!(sql, [geom, dist_m])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags Repo.query! whose SQL is interpolated" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.query!("UPDATE \#{table} SET flagged = true", [])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags Repo.insert_all inside a resource" do
      """
      defmodule Sample do
        use Ash.Resource

        def seed(rows) do
          MyApp.Repo.insert_all("orders", rows)
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue(fn issue ->
        assert issue.trigger == "MyApp.Repo.insert_all"
      end)
    end

    test "flags Repo.update_all inside a calculation" do
      """
      defmodule Sample do
        use Ash.Resource.Calculation

        def calculate(records, _opts, _context) do
          Repo.update_all(Order, set: [flagged: true])
          records
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags Repo.delete_all inside a preparation" do
      """
      defmodule Sample do
        use Ash.Resource.Preparation

        def prepare(query, _opts, _context) do
          Repo.delete_all(Stale)
          query
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags it inside a validation" do
      """
      defmodule Sample do
        use Ash.Resource.Validation

        def validate(_changeset, _opts, _context) do
          Repo.delete_all(Stale)
          :ok
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags it inside a generic action implementation" do
      """
      defmodule Sample do
        use Ash.Resource.Actions.Implementation

        def run(_input, _opts, _context) do
          Repo.delete_all(Stale)
          :ok
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue()
    end

    test "flags Ecto.Adapters.SQL.query! running an INSERT" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Ecto.Adapters.SQL.query!(MyApp.Repo, "INSERT INTO audits (id) VALUES ($1)", [id])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Ecto.Adapters.SQL.query!"
      end)
    end

    test "flags a resource module declared through extra_resource_modules" do
      """
      defmodule Sample do
        use MyApp.Resource

        def seed(rows) do
          Repo.insert_all("orders", rows)
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource, extra_resource_modules: ["MyApp.Resource"])
      |> assert_issue()
    end

    test "flags each call separately" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.delete_all(Stale)
          Repo.insert_all("orders", rows)
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> assert_issues(fn issues -> assert length(issues) == 2 end)
    end
  end

  describe "does not flag" do
    test "a literal SELECT through Repo.query!" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.query!("SELECT next_position($1)", [depot_id])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "a literal SELECT past leading whitespace and case" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.query!("\\n  select count(*) from orders\\n", [])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "a literal SELECT through Ecto.Adapters.SQL.query" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Ecto.Adapters.SQL.query(MyApp.Repo, "SELECT 1", [])
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "Repo reads that are not query-executing functions" do
      """
      defmodule Sample do
        use Ash.Resource.Calculation

        def calculate(_records, _opts, _context) do
          Repo.all(query) ++ [Repo.one(other), Repo.get(Order, id)]
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "transaction control" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.transaction(fn ->
            Repo.rollback(:nope)
          end)

          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "a module that is not an Ash resource" do
      """
      defmodule Sample do
        def seed(rows) do
          Repo.insert_all("orders", rows)
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "a module that uses an unrelated Ash module" do
      """
      defmodule Sample do
        use Ash.Domain

        def seed(rows) do
          Repo.insert_all("orders", rows)
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "a call in a sibling module that is not a resource" do
      """
      defmodule Resource do
        use Ash.Resource
      end

      defmodule Plain do
        def seed(rows) do
          Repo.insert_all("orders", rows)
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "an alias that does not end in Repo" do
      """
      defmodule Sample do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Client.insert_all("orders", rows)
          changeset
        end
      end
      """
      |> to_source_file()
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end

    test "test files" do
      """
      defmodule SampleTest do
        use Ash.Resource.Change

        def change(changeset, _opts, _context) do
          Repo.delete_all(Stale)
          changeset
        end
      end
      """
      |> to_source_file("test/sample_test.exs")
      |> run_check(RepoInAshResource)
      |> refute_issues()
    end
  end
end
