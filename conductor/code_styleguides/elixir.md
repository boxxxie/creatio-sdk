# Elixir Style & Library Conventions (`creatio-sdk`)

## Formatting & Linting
- Strictly conform to `mix format` (`.formatter.exs` covers `{mix,.formatter}.exs` and `{lib,test}/**/*.{ex,exs}`).
- Zero warnings under `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix dialyzer`.

## Public API & Type Safety
- Add `@moduledoc`, `@doc`, and `@spec` to every public module and function—including `defdelegate` entrypoints in `Creatio`.
- Mark internal accumulation fields or struct representations with `@opaque t()` when callers should not destructure them directly.
- Normalize Creatio facade arguments consistently (`client, target, opts` and `target, client, opts`) without duplicating core request logic.
- Extract shared logic into pure helpers (`Creatio.Util`, `@moduledoc false`) rather than duplicating parameter or pagination code across `OData` and `OData3`.

## Error Handling & Safety
- Never rescue broad exceptions silently or return untyped `{:error, string}` tuples from public functions; normalize HTTP/network failures into `%Creatio.Error{}`.
- Guard every mutation path against `client.read_only` both before issuing requests and inside `Client`'s `read_only_guard` request step.
- Do not call `String.to_atom/1` on untrusted network/JSON input; validate finite option values explicitly.

## Testing (4-Layer ATDD + Unit/Regression)
- Prefer 4-layer ATDD specs in `test/features/` using `Creatio.FeatureScenario`, `Creatio.TestDSL.*`, and `Creatio.TestDrivers.*` (`Plug`/`Req` HTTP stubs) so test assertions stay decoupled from HTTP wire wiring.
- Keep fast unit/regression suites in `test/creatio/` and tag any real-instance integration tests with `@moduletag :live` / `@tag :live` so `mix test` stays hermetic and offline by default.
- Maintain `mix test --cover` well above the configured `84%` minimum threshold.
