# Tech Stack: `creatio` (`creatio-sdk`)

## Language & Runtime
- **Elixir:** `~> 1.15` (CI runs Elixir `1.15` / OTP `26` via `.github/workflows/ci.yml`)
- **OTP:** Standard Erlang/OTP paired with Elixir 1.15+

## Runtime Dependencies (`mix.exs`)
- **HTTP Client:** `req` (`~> 0.5` for `Req.Request` struct compatibility)
- **JSON Codec:** `jason ~> 1.4`
- **Telemetry:** `telemetry ~> 1.2` (HTTP request hooks plus full domain-level `:telemetry.span/3` events across `OData`, `OData3`, `DataService`, `Auth`, and `Batch`)

## Development & Test Tooling
- **HTTP Stubbing:** `plug ~> 1.15` (`only: :test`, powers `Req` test plugs in `test/support/drivers/`)
- **Static Analysis & Style:**
  - `mix format --check-formatted` (`.formatter.exs`)
  - `mix compile --warnings-as-errors`
  - `credo ~> 1.7` (`mix credo --strict`, configured in `.credo.exs`)
  - `dialyxir ~> 1.4` (`mix dialyzer`, 0 errors / 0 skips)
- **Documentation:** `ex_doc ~> 0.31` (`mix docs`)
- **Test Architecture:** ExUnit (`test_helper.exs` excludes `:live` by default)
  - Layer 1–4 ATDD suite under `test/features/` and `test/support/{dsl,drivers}/` (`Creatio.FeatureScenario`, `Creatio.TestDSL.*`, `Creatio.TestDrivers.*`)
  - Unit & regression specs under `test/creatio/`
  - Coverage gate: `mix test --cover` minimum threshold `84%` (configured in `mix.exs`)

## CI & Distribution
- **CI:** `.github/workflows/ci.yml` (`mix test`, `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`)
- **Package Registry:** Hex.pm (`creatio`) + HexDocs (`creatio.hexdocs.pm`)
- **Versioning:** Semantic Versioning (`v0.4.0` current, targeting `v1.0.0`)
