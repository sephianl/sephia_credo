if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.SephiaCredo.Install do
    @shortdoc "Installs SephiaCredo checks into your .credo.exs"

    @moduledoc """
    #{@shortdoc}

    Adds all SephiaCredo checks to your Credo config with default settings.

    ## Example

        mix igniter.install sephia_credo --only dev,test
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.List
    alias Igniter.Code.Map

    @checks [
      {SephiaCredo.Checks.AppendInLoop, []},
      {SephiaCredo.Checks.NoDateTimeOperatorCompare, []},
      {SephiaCredo.Checks.UnusedSetupKeysInTests, []},
      {SephiaCredo.Checks.UnusedSetupKeysPerTest, []}
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :sephia_credo,
        only: [:dev, :test],
        dep_opts: [runtime: false],
        example: "mix igniter.install sephia_credo --only dev,test"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      Igniter.create_or_update_elixir_file(
        igniter,
        ".credo.exs",
        default_credo_config(),
        &update_credo_config/1
      )
    end

    defp update_credo_config(zipper) do
      with {:ok, configs_zipper} <-
             Common.move_to_cursor(zipper, "%{configs: __cursor__()}"),
           {:ok, first_config} <-
             List.move_to_list_item(configs_zipper, fn _ -> true end) do
        checks_list = Sourceror.parse_string!(inspect(@checks))

        Map.put_in_map(
          first_config,
          [:checks],
          checks_list,
          &append_checks/1
        )
      end
    end

    defp append_checks(checks_zipper) do
      eq_pred = fn existing_zipper, new_node ->
        Sourceror.to_string(Sourceror.Zipper.node(existing_zipper)) ==
          Sourceror.to_string(new_node)
      end

      Enum.reduce_while(@checks, {:ok, checks_zipper}, fn check_tuple, {:ok, z} ->
        node = Sourceror.parse_string!(inspect(check_tuple))

        case List.prepend_new_to_list(z, node, eq_pred) do
          {:ok, z} -> {:cont, {:ok, z}}
          other -> {:halt, other}
        end
      end)
    end

    defp default_credo_config do
      """
      %{
        configs: [
          %{
            name: "default",
            checks: [
              {SephiaCredo.Checks.AppendInLoop, []},
              {SephiaCredo.Checks.NoDateTimeOperatorCompare, []},
              {SephiaCredo.Checks.UnusedSetupKeysInTests, []},
              {SephiaCredo.Checks.UnusedSetupKeysPerTest, []}
            ]
          }
        ]
      }
      """
    end
  end
else
  defmodule Mix.Tasks.SephiaCredo.Install do
    @shortdoc "Installs SephiaCredo checks | Install `igniter` to use"

    @moduledoc """
    #{@shortdoc}

    This task requires the `igniter` package to be installed.
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'sephia_credo.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
