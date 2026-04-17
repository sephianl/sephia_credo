[
  tools: [
    {:compiler, "mix compile --warnings-as-errors"},
    {:formatter, false},
    {:unused_deps, "mix deps.unlock --check-unused"},
    {:ex_unit, "mix test"},
    {:credo, "mix credo --strict"},
    {:ex_doc, "mix docs"}
  ]
]
