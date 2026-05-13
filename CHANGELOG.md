# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
