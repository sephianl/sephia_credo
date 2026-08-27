defmodule SephiaCredo.Checks.KeywordBagParameterTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.KeywordBagParameter

  describe "flags a parameter used as a bag of keys" do
    test "three distinct keys read off one parameter" do
      """
      defmodule Sample do
        def create_order(opts) do
          customer = Keyword.fetch!(opts, :customer)
          address = Keyword.fetch!(opts, :address)
          priority = Keyword.get(opts, :priority, :normal)
          {customer, address, priority}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue(fn issue ->
        assert issue.trigger == "opts"
        assert issue.message =~ ":customer, :address, :priority"
        assert issue.message =~ "create_order(customer, address, priority)"
      end)
    end

    test "detection is by shape, so renaming the parameter changes nothing" do
      """
      defmodule Sample do
        def create_order(settings) do
          {Keyword.fetch!(settings, :a), Keyword.fetch!(settings, :b),
           Keyword.fetch!(settings, :c)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue(fn issue -> assert issue.trigger == "settings" end)
    end

    test "keys read through a pipe count" do
      """
      defmodule Sample do
        def run(opts) do
          a = opts |> Keyword.get(:a)
          b = opts |> Keyword.get(:b)
          c = opts |> Keyword.get(:c)
          {a, b, c}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue()
    end

    test "Keyword.take counts every key it lists" do
      """
      defmodule Sample do
        def run(opts), do: Keyword.take(opts, [:a, :b, :c])
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue()
    end

    test "keys read in a rescue clause count" do
      """
      defmodule Sample do
        def run(opts) do
          Keyword.fetch!(opts, :a)
        rescue
          _ -> {Keyword.get(opts, :b), Keyword.get(opts, :c)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue()
    end

    test "a parameter with a default is still a bag" do
      """
      defmodule Sample do
        def run(id, opts \\\\ []) do
          {id, Keyword.get(opts, :a), Keyword.get(opts, :b), Keyword.get(opts, :c)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> assert_issue()
    end
  end

  describe "does not flag" do
    test "a keyword list that is only forwarded" do
      """
      defmodule Sample do
        def all(query, opts), do: Repo.all(query, opts)
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "fewer distinct keys than min_keys" do
      """
      defmodule Sample do
        def run(opts), do: {Keyword.get(opts, :a), Keyword.get(opts, :b)}
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "the same key read repeatedly" do
      """
      defmodule Sample do
        def run(opts) do
          if Keyword.has_key?(opts, :a), do: Keyword.get(opts, :a), else: Keyword.fetch!(opts, :a)
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "conventionally forwarded keys" do
      """
      defmodule Sample do
        def run(opts) do
          {Keyword.get(opts, :actor), Keyword.get(opts, :authorize?), Keyword.get(opts, :tenant)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "a callback marked @impl, whose arity belongs to the behaviour" do
      """
      defmodule Sample do
        use GenServer

        @impl true
        def init(opts) do
          {:ok, {Keyword.fetch!(opts, :total), Keyword.fetch!(opts, :label),
                 Keyword.get(opts, :timer)}}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "a parameter the body also passes on whole" do
      """
      defmodule Sample do
        def call(opts) do
          a = Keyword.get(opts, :a)
          b = Keyword.get(opts, :b)
          c = Keyword.get(opts, :c)
          Other.run(opts, a, b, c)
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end

    test "Keyword calls on something that is not a parameter" do
      """
      defmodule Sample do
        def run(config) do
          opts = build(config)
          {Keyword.get(opts, :a), Keyword.get(opts, :b), Keyword.get(opts, :c)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter)
      |> refute_issues()
    end
  end

  describe "params" do
    test "min_keys lowers the threshold" do
      """
      defmodule Sample do
        def run(opts), do: {Keyword.get(opts, :a), Keyword.get(opts, :b)}
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter, min_keys: 2)
      |> assert_issue()
    end

    test "ignored_keys removes keys from the count" do
      """
      defmodule Sample do
        def run(opts) do
          {Keyword.get(opts, :a), Keyword.get(opts, :b), Keyword.get(opts, :skip_me)}
        end
      end
      """
      |> to_source_file()
      |> run_check(KeywordBagParameter, ignored_keys: [:skip_me])
      |> refute_issues()
    end
  end
end
