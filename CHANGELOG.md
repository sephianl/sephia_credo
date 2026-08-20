# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-19

### Changed

- `UnusedSetupKeysInTests` and `UnusedSetupKeysPerTest` now resolve a context handed to a `def`/`defp` in the same file, following it through helper chains, pipes and `%{ctx | ...}` copies, and counting the keys that helper reads. A test that hands its context to something unresolvable — imported or remote — is treated as opaque and consumes every key in scope, so the checks stay quiet rather than report a live fixture as dead. Previously any test that passed `ctx` to a helper read as using nothing.
- `UnusedSetupKeysPerTest` now flags only a test that consumes **none** of the setup keys in scope for it. The previous rule — every test must consume every in-scope key — treated a shared fixture as a defect and was too noisy to enable: 1747 reports against 152 under the new rule, on the same 767-file suite. Its message and moduledoc now explain the cost being avoided (ExUnit has no lazy `let`), and document the case it cannot see: a `setup` whose inserted rows are queried without being named.

### Added

- `usage-rules.md`, consumed by [usage_rules](https://hexdocs.pm/usage_rules), documenting how to respond to each check — starting with the rule that a report is a suspicion to verify, not a licence to delete code.
- `SephiaCredo.TestContext`, the shared AST reading behind both setup-key checks.

## [0.2.0] - 2026-05-12

### Added

- `AshCodeInterfaceReadWithArgs` — flags `define :name, action: :read, args: [...]` inside `code_interface` blocks. Ash's generic `:read` action declares no inputs, so the resulting function raises `Ash.Error.Invalid.NoSuchInput` at runtime.
- `AssertWithoutAssertion` — flags `assert pattern = expr` in test files where the bound variables are never used afterwards. The match succeeds vacuously and tests nothing.
- `ProcessSleepInTests` — flags `Process.sleep/1` in `*_test.exs` files, including inside `setup` and `setup_all` blocks. Causes flakes and slows the suite.
- `RawRuntimeError` — flags `raise "msg"` and `raise RuntimeError, ...`. Both lower to `RuntimeError`, defeating error-tracker grouping (every message becomes its own issue).
- `SysGetStateWithoutTimeoutInPoll` *(opt-in)* — flags `:sys.get_state/1` inside a polling fn without a surrounding `try/catch :exit`. Configurable via `poll_functions:`. Not added by the installer; opt in manually.

### Changed

- `StructComparisonOperator` replaces `NoDateTimeOperatorCompare`. In addition to `Date`, `Time`, `DateTime`, and `NaiveDateTime`, it now covers `Decimal` and `Version`, and accepts an `extra_modules` config for any other struct that defines its own `compare/2`.
- `mix sephia_credo.install` registers the new default-on checks alongside the existing ones.

### Removed

- `NoDateTimeOperatorCompare` — superseded by `StructComparisonOperator`. See the "Upgrading from 0.1" section of the README for the one-line migration.

## [0.1.1] - 2026-04-17

- Igniter installer fixes.

## [0.1.0] - 2026-04-17

- Initial release with `AppendInLoop`, `NoDateTimeOperatorCompare`, `UnusedSetupKeysInTests`, `UnusedSetupKeysPerTest`.
