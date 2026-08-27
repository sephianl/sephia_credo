defmodule SephiaCredo.Checks.PreloadInLoopTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.PreloadInLoop

  describe "Enum iteration" do
    test "flags Repo.preload inside Enum.map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, fn user ->
            Repo.preload(user, :posts)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Repo.preload"
      end)
    end

    test "flags Repo.preload inside Enum.each" do
      """
      defmodule Sample do
        def run(users) do
          Enum.each(users, fn user -> Repo.preload(user, :posts) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags Repo.preload inside Enum.reduce" do
      """
      defmodule Sample do
        def run(users) do
          Enum.reduce(users, [], fn user, acc ->
            [Repo.preload(user, :posts) | acc]
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags Repo.preload inside Enum.flat_map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.flat_map(users, fn user -> Repo.preload(user, :posts).posts end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags capture form &Repo.preload(&1, :assoc) inside Enum.map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, &Repo.preload(&1, :posts))
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags pipe form inside Enum.map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, fn user ->
            user |> Repo.preload(:posts)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end
  end

  describe "fully-qualified Repo aliases" do
    test "flags MyApp.Repo.preload inside Enum.map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, fn user ->
            MyApp.Repo.preload(user, :posts)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags Accounts.Repo.preload inside Enum.each" do
      """
      defmodule Sample do
        def run(users) do
          Enum.each(users, fn user ->
            Accounts.Repo.preload(user, :profile)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end
  end

  describe "for comprehensions" do
    test "flags Repo.preload inside for comprehension" do
      """
      defmodule Sample do
        def run(users) do
          for user <- users do
            Repo.preload(user, :posts)
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags Repo.preload inside for/reduce comprehension" do
      """
      defmodule Sample do
        def run(users) do
          for user <- users, reduce: [] do
            acc -> [Repo.preload(user, :posts) | acc]
          end
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end
  end

  describe "non-loop / non-preload (no issues)" do
    test "allows the batched preload that feeds a loop" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(Repo.preload(users, :posts), fn u -> u.posts end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "allows a batched preload in the for comprehension's generator" do
      """
      defmodule Sample do
        def run(users) do
          for u <- Repo.preload(users, :posts), do: u.posts
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "flags Ash.load inside Enum.map" do
      """
      defmodule Sample do
        def run(records) do
          Enum.map(records, fn r -> Ash.load(r, :items) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue(fn issue -> assert issue.trigger == "Ash.load" end)
    end

    test "allows the batched Ash.load that feeds a loop" do
      """
      defmodule Sample do
        def run(records) do
          records
          |> Ash.load(:items)
          |> Enum.map(fn r -> r.items end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "allows Repo.preload outside of any loop" do
      """
      defmodule Sample do
        def run(users) do
          Repo.preload(users, :posts)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "allows Repo.preload in a pipeline (no enclosing loop)" do
      """
      defmodule Sample do
        def run(users) do
          users
          |> Repo.preload(:posts)
          |> Enum.map(& &1.name)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "allows Repo.all inside Enum.map (only preload is flagged)" do
      """
      defmodule Sample do
        def run(ids) do
          Enum.map(ids, fn id -> Repo.all(from u in User, where: u.id == ^id) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end

    test "allows non-Repo module's preload inside Enum.map" do
      """
      defmodule Sample do
        def run(items) do
          Enum.map(items, fn item -> Cache.preload(item, :assoc) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end
  end

  describe "multiple issues" do
    test "flags multiple Repo.preload calls in the same Enum.map" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, fn user ->
            user = Repo.preload(user, :posts)
            Repo.preload(user, :comments)
          end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end

    test "flags two Repo.preload calls that share a line" do
      """
      defmodule Sample do
        def run(users) do
          Enum.map(users, fn user -> {Repo.preload(user, :posts), Repo.preload(user, :tags)} end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issues(fn issues ->
        assert length(issues) == 2
      end)
    end
  end

  describe "Stream and Task iteration" do
    test "flags Repo.preload inside Stream.map" do
      """
      defmodule Sample do
        def run(users) do
          users
          |> Stream.map(fn user -> Repo.preload(user, :posts) end)
          |> Enum.to_list()
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "flags Ash.load inside Stream.flat_map" do
      """
      defmodule Sample do
        def run(records) do
          Stream.flat_map(records, fn record -> Ash.load(record, :items) end)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue(fn issue ->
        assert issue.trigger == "Ash.load"
      end)
    end

    test "flags Repo.preload inside Task.async_stream" do
      """
      defmodule Sample do
        def run(users) do
          Task.async_stream(users, fn user -> Repo.preload(user, :posts) end, max_concurrency: 4)
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> assert_issue()
    end

    test "does not flag the collection a Stream iterates over" do
      """
      defmodule Sample do
        def run(users) do
          users
          |> Repo.preload(:posts)
          |> Stream.map(fn user -> user.posts end)
          |> Enum.to_list()
        end
      end
      """
      |> to_source_file()
      |> run_check(PreloadInLoop)
      |> refute_issues()
    end
  end
end
