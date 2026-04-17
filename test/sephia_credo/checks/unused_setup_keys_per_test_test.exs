defmodule SephiaCredo.Checks.UnusedSetupKeysPerTestTest do
  use Credo.Test.Case, async: true

  alias SephiaCredo.Checks.UnusedSetupKeysPerTest

  describe "module-level setup" do
    test "flags a test that does not consume some setup keys" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2, search_address: 3}
        end

        test "uses only company", %{company: c} do
          assert c
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.trigger == "test"
        assert issue.message =~ ":depot"
        assert issue.message =~ ":search_address"
        refute issue.message =~ ":company"
      end)
    end

    test "no issue when a test consumes every in-scope key" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "uses both", %{company: c, depot: d} do
          assert {c, d}
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "treats ctx.key access as consumption" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "via ctx", ctx do
          assert ctx.company
          assert ctx.depot
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "test without context match flags every in-scope key" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "needs nothing" do
          assert true
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.trigger == "test"
        assert issue.message =~ ":company"
        assert issue.message =~ ":depot"
      end)
    end

    test "underscore-prefixed bindings do not count as consumption" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        test "ignores depot", %{company: c, depot: _depot} do
          assert c
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":depot"
        refute issue.message =~ ":company"
      end)
    end
  end

  describe "describe-local setup" do
    test "in-scope keys are union of module + describe setup" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        describe "extra" do
          setup do
            %{depot: 2}
          end

          test "uses only depot", %{depot: d} do
            assert d
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.trigger == "test"
        assert issue.message =~ ":company"
        refute issue.message =~ ":depot"
      end)
    end

    test "describe setup destructure counts as consumption for tests in the describe" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1, depot: 2}
        end

        describe "consumes company via inner setup" do
          setup %{company: company} do
            %{thing: company}
          end

          test "uses thing", %{thing: t} do
            assert t
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.trigger == "test"
        assert issue.message =~ ":depot"
        refute issue.message =~ ":company"
        refute issue.message =~ ":thing"
      end)
    end

    test "no issue when test in describe consumes every in-scope key" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          %{company: 1}
        end

        describe "extra" do
          setup do
            %{depot: 2}
          end

          test "uses both", %{company: c, depot: d} do
            assert {c, d}
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end
  end

  describe "dependency tracking" do
    test "key used to construct another consumed key is transitively consumed" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          admin = create_admin(company)
          route = insert_route(company, admin)
          %{company: company, admin: admin, route: route}
        end

        test "uses only route", %{route: r} do
          assert r
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "key NOT used to construct any consumed key is still flagged" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          admin = create_admin(company)
          unrelated = create_unrelated()
          route = insert_route(company, admin)
          %{company: company, admin: admin, unrelated: unrelated, route: route}
        end

        test "uses only route", %{route: r} do
          assert r
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> assert_issue(fn issue ->
        assert issue.message =~ ":unrelated"
        refute issue.message =~ ":company"
        refute issue.message =~ ":admin"
        refute issue.message =~ ":route"
      end)
    end

    test "transitive dependencies through multiple levels" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          depot = create_depot(company)
          admin = create_admin(depot)
          route = insert_route(admin)
          %{company: company, depot: depot, admin: admin, route: route}
        end

        test "uses only route", %{route: r} do
          assert r
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "describe-level setup deps include module-level keys" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          depot = create_depot(company)
          %{company: company, depot: depot}
        end

        describe "with admin" do
          setup %{company: company, depot: depot} do
            admin = create_admin(company, depot)
            %{admin: admin}
          end

          test "uses only admin", %{admin: a} do
            assert a
          end
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "reassigned variable accumulates dependencies" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          admin = create_admin(company)
          route = insert_route(company)
          route = update_route(route, admin)
          %{company: company, admin: admin, route: route}
        end

        test "uses only route", %{route: r} do
          assert r
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end

    test "ok-tuple return pattern with dependencies" do
      """
      defmodule SampleTest do
        use ExUnit.Case

        setup do
          company = create_company()
          admin = create_admin(company)
          {:ok, %{company: company, admin: admin}}
        end

        test "uses only admin", %{admin: a} do
          assert a
        end
      end
      """
      |> to_source_file("sample_test.exs")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end
  end

  describe "non-test files" do
    test "ignores files that don't end in _test.exs" do
      """
      defmodule SampleModule do
        def foo, do: :ok
      end
      """
      |> to_source_file("sample.ex")
      |> run_check(UnusedSetupKeysPerTest)
      |> refute_issues()
    end
  end
end
