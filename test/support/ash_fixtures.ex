defmodule SephiaCredo.Fixtures.Label do
  @moduledoc "A resource with read, update, generic-action and calculation interfaces."
  use Ash.Resource, domain: SephiaCredo.Fixtures.Domain

  attributes do
    uuid_primary_key(:id)
    attribute(:code, :integer, public?: true)
    attribute(:zone_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, :destroy])

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

defmodule SephiaCredo.Fixtures.EmailJob do
  @moduledoc "Stands in for an `Oban.Worker` that wraps its own insert."
  def __opts__, do: [queue: :default]
  def new(args), do: args
  def perform(_job), do: :ok
  def enqueue(parcel), do: {:ok, parcel}
end

defmodule SephiaCredo.Fixtures.Domain do
  @moduledoc "A domain whose resource and code interfaces the Ash-aware checks resolve in tests."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SephiaCredo.Fixtures.Label do
      define(:archive_label, action: :archive)
    end

    resource(SephiaCredo.Fixtures.Bin)
    resource(SephiaCredo.Fixtures.Crate)
  end
end
