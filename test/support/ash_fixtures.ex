defmodule SephiaCredo.Fixtures.StoredDataLayer do
  @moduledoc "Stands in for a database data layer, which is all the checks ask of a resource."
  use Spark.Dsl.Extension, sections: []
  @behaviour Ash.DataLayer

  @impl true
  def can?(_resource, _feature), do: true

  @impl true
  def resource_to_query(resource, _domain), do: resource
end

defmodule SephiaCredo.Fixtures.Note do
  @moduledoc "A resource kept in memory, whose code interfaces never reach a database."
  use Ash.Resource, domain: SephiaCredo.Fixtures.Domain

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read, update: []])
  end

  code_interface do
    define(:touch, action: :update)
  end
end

defmodule SephiaCredo.Fixtures.Label do
  @moduledoc "A resource with read, update, generic-action and calculation interfaces."
  use Ash.Resource,
    domain: SephiaCredo.Fixtures.Domain,
    data_layer: SephiaCredo.Fixtures.StoredDataLayer

  attributes do
    uuid_primary_key(:id)
    attribute(:code, :integer, public?: true)
    attribute(:zone_id, :uuid, public?: true)
  end

  relationships do
    belongs_to(:parent, __MODULE__, public?: true)
    belongs_to(:origin, __MODULE__, public?: true)
    belongs_to(:twin, __MODULE__, public?: true)
    belongs_to(:crate, SephiaCredo.Fixtures.Crate, public?: true)
    belongs_to(:bin, SephiaCredo.Fixtures.Bin, public?: true)
  end

  aggregates do
    count(:child_count, :parent)
  end

  actions do
    defaults([:read, :destroy])

    read :with_family do
      prepare(
        build(
          load: [:crate, :child_count, :origin, :twin, parent: [:origin, :twin, parent: [:bin]]]
        )
      )
    end

    read :by_code do
      argument(:code, :integer, allow_nil?: false)
      get?(true)
      filter(expr(code == ^arg(:code)))
    end

    update :set_zone do
      argument(:zone_id, :uuid)
      change(set_attribute(:zone_id, arg(:zone_id)))
    end

    update(:archive)

    action :ping, :boolean do
      run(fn _input, _context -> {:ok, true} end)
    end
  end

  calculations do
    calculate(:upcased, :integer, expr(code))
  end

  code_interface do
    define(:get_by_code, action: :by_code, args: [:code])
    define(:set_zone, args: [:zone_id])
    define(:ping)
    define_calculation(:upcased, args: [:_record])
  end
end

defmodule SephiaCredo.Fixtures.LogMutation do
  @moduledoc "Logs from an after_action hook that its atomic/3 leaves out, like Green's MutationLogger."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok
end

defmodule SephiaCredo.Fixtures.LogMutationAtomically do
  @moduledoc "Logs from the same after_action hook on both paths, its atomic/3 delegating to change/3."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

defmodule SephiaCredo.Fixtures.LogMutationWhenPrinted do
  @moduledoc """
  Adds its hook through a helper only when the line will be printed, with atomic/3 delegating to
  change/3, like Zelo's MutationLogger.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context),
    do: log_after_action(changeset, Logger.compare_levels(:info, Logger.level()))

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp log_after_action(changeset, :lt), do: changeset

  defp log_after_action(changeset, _printed),
    do: Ash.Changeset.after_action(changeset, fn _changeset, record -> {:ok, record} end)
end

defmodule SephiaCredo.Fixtures.AskAbsentServer do
  @moduledoc "Asks a process that is not running from its atomic/3, like a feature-flag lookup."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(changeset, _opts, _context) do
    GenServer.call(:sephia_credo_absent_server, :flag)
    {:ok, changeset}
  end
end

defmodule SephiaCredo.Fixtures.Bin do
  @moduledoc "A resource with `require_atomic? false` actions, needed and not."
  use Ash.Resource, domain: SephiaCredo.Fixtures.Domain

  attributes do
    uuid_primary_key(:id)
    attribute(:zone_id, :uuid, public?: true)
  end

  actions do
    defaults([:read])

    update :set_zone do
      require_atomic?(false)
      argument(:zone_id, :uuid)
      change(set_attribute(:zone_id, arg(:zone_id)))
      validate(present(:zone_id))
    end

    update :with_hook do
      require_atomic?(false)
      change(fn changeset, _context -> changeset end)
    end

    destroy :purge do
      require_atomic?(false)
    end

    update :logged do
      require_atomic?(false)
      change(SephiaCredo.Fixtures.LogMutation)
    end

    update :flagged do
      require_atomic?(false)
      change(SephiaCredo.Fixtures.AskAbsentServer)
    end

    update :logged_atomically do
      require_atomic?(false)
      change(SephiaCredo.Fixtures.LogMutationAtomically)
    end

    update :logged_when_printed do
      require_atomic?(false)
      change(SephiaCredo.Fixtures.LogMutationWhenPrinted)
    end
  end
end

defmodule SephiaCredo.Fixtures.Shelf do
  @moduledoc "An archived resource, whose un-archive actions an atomic update cannot find the row for."
  use Ash.Resource, domain: SephiaCredo.Fixtures.Domain, extensions: [AshArchival.Resource]

  archive do
    exclude_read_actions([:archived])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end

  actions do
    defaults([:read])

    read :archived do
      filter(expr(not is_nil(archived_at)))
    end

    update :restore do
      require_atomic?(false)
      change(set_attribute(:archived_at, nil))
    end

    update :restore_through_archived do
      require_atomic?(false)
      atomic_upgrade_with(:archived)
      change(set_attribute(:archived_at, nil))
    end

    update :rename do
      require_atomic?(false)
      accept([:name])
    end
  end
end

defmodule SephiaCredo.Fixtures.Crate.Actions do
  @moduledoc "A fragment holding a resource's actions."
  use Spark.Dsl.Fragment, of: Ash.Resource

  actions do
    defaults([:read])

    update :relabel do
      require_atomic?(false)
      change(set_attribute(:label, "relabelled"))
    end
  end
end

defmodule SephiaCredo.Fixtures.Crate do
  @moduledoc "A resource whose actions come from a fragment."
  use Ash.Resource,
    domain: SephiaCredo.Fixtures.Domain,
    fragments: [SephiaCredo.Fixtures.Crate.Actions]

  attributes do
    uuid_primary_key(:id)
    attribute(:label, :string, public?: true)
  end
end

for name <- [:Stamp, :Recount, :Weigh, :Seal, :Tag, :Shift] do
  defmodule Module.concat(SephiaCredo.Fixtures.Pallet.Changes, name) do
    @moduledoc "A change on `SephiaCredo.Fixtures.Pallet`, whose source a test supplies."
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset
  end
end

defmodule SephiaCredo.Fixtures.Pallet.Validations.Fits do
  @moduledoc "A validation on `SephiaCredo.Fixtures.Pallet`, whose source a test supplies."
  use Ash.Resource.Validation

  @impl true
  def validate(_changeset, _opts, _context), do: :ok
end

defmodule SephiaCredo.Fixtures.Pallet do
  @moduledoc """
  A resource whose actions `SephiaCredo.Fixtures.PalletService` runs in bulk or one record at a
  time, for the checks that ask which.
  """
  use Ash.Resource,
    domain: SephiaCredo.Fixtures.Domain,
    data_layer: SephiaCredo.Fixtures.StoredDataLayer

  alias SephiaCredo.Fixtures.Pallet.Changes

  attributes do
    uuid_primary_key(:id)
    attribute(:weight, :integer, public?: true)
  end

  changes do
    change(Changes.Stamp, on: [:update])
  end

  actions do
    defaults([:read])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    update :recount do
      require_atomic?(false)
      change(Changes.Recount)
    end

    update :weigh do
      require_atomic?(false)
      change(Changes.Weigh)
      validate(SephiaCredo.Fixtures.Pallet.Validations.Fits)
    end

    update :seal do
      require_atomic?(false)
      change(Changes.Seal)
    end

    update :tag do
      require_atomic?(false)
      change(Changes.Tag)
    end

    update :shift do
      require_atomic?(false)
      change(Changes.Shift)
    end
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:weigh)
    define(:seal)
    define(:tag)
    define(:shift)
  end
end

defmodule SephiaCredo.Fixtures.PalletService do
  @moduledoc "Runs `SephiaCredo.Fixtures.Pallet`'s actions in bulk or one record at a time."
  alias SephiaCredo.Fixtures.Pallet

  def recount_all(query), do: Ash.bulk_update(query, :recount, %{})

  def weigh(pallet) do
    case Pallet.weigh(pallet) do
      {:ok, weighed} -> weighed
      {:error, error} -> raise error
    end
  end

  def seal_all, do: Pallet |> Ash.read!() |> Pallet.seal()

  def tag(id), do: id |> Pallet.get_by_id() |> tag_found()

  def shift(pallets), do: Pallet.shift(pallets)

  defp tag_found({:ok, pallet}), do: Pallet.tag(pallet)
  defp tag_found(error), do: error
end

defmodule SephiaCredo.Fixtures.EmailJob do
  @moduledoc "Stands in for an `Oban.Worker` that wraps its own insert."
  @compile {:no_warn_undefined, [Oban]}

  def new(args), do: args
  def perform(_job), do: :ok
  def enqueue(parcel), do: parcel |> args() |> new() |> Oban.insert()
  def args(parcel), do: %{id: parcel.id}
end

defmodule SephiaCredo.Fixtures.UniqueJob do
  @moduledoc "Stands in for an `Oban.Worker` with `unique` set."
  @compile {:no_warn_undefined, [Oban]}

  def __opts__, do: [queue: :default, unique: [period: 60]]
  def new(args), do: args
  def perform(_job), do: :ok
  def enqueue(args), do: Oban.insert(args)
end

defmodule SephiaCredo.Fixtures.DefaultArgJob do
  @moduledoc "Stands in for a worker whose `enqueue` takes optional options and whose `__opts__/0` is a map."
  @compile {:no_warn_undefined, [Oban]}

  def __opts__, do: %{queue: :default}
  def perform(_job), do: :ok
  def enqueue(args, opts \\ []), do: Oban.insert(args, opts)
end

defmodule SephiaCredo.Fixtures.Webhook do
  @moduledoc "Returns its entity sets from a module attribute, as a constant."
  @entity_sets ["items", "orders", "customers"]

  def entity_sets, do: @entity_sets
  def subscribed(company), do: company.entity_sets
end

defmodule SephiaCredo.Fixtures.Domain do
  @moduledoc "A domain whose resource and code interfaces the Ash-aware checks resolve in tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SephiaCredo.Fixtures.Label do
      define(:archive_label, action: :archive)
    end

    resource(SephiaCredo.Fixtures.Note)
    resource(SephiaCredo.Fixtures.Bin)
    resource(SephiaCredo.Fixtures.Shelf)
    resource(SephiaCredo.Fixtures.Crate)
    resource(SephiaCredo.Fixtures.Pallet)
  end
end
