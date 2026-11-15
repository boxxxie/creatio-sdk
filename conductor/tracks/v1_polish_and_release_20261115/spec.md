# Track Specification: 1.0 Polish, Telemetry & Release Readiness

## Overview
With live wire behavior verified (Track 1) and public SemVer contracts locked (Track 2), this final track adds production observability (`:telemetry`), resolves minor option/coverage gaps (`get_field_value/5` options, `Creatio.Util` coverage), ships LLM/contributor `usage-rules.md`, documents the `0.4 -> 1.0` upgrade path, and completes all pre-release gates for `v1.0.0`.

## Functional Requirements
1. **`:telemetry` Instrumentation:**
   - Add `{:telemetry, "~> 1.2"}` to `mix.exs` and emit `:telemetry` events via a lightweight internal step/helper (or `Req` response/error hooks in `Creatio.Client`) without requiring runtime GenServers.
   - Emit events for:
     - HTTP requests: `[:creatio, :request, :start | :stop | :exception]` with duration, HTTP method, path, status, and sanitized metadata (never emitting `auth_token`, `client_secret`, `cookie`, `bpmcsrf`, or passwords).
     - Authentication transitions: `[:creatio, :auth, :stop | :exception]` (`:oauth` / `:forms`).
     - Batch executions: `[:creatio, :batch, :stop]` (format, operation count, status).
   - Document all emitted events and measurements in module docs / `README.md`.
2. **`get_field_value/5` Option Forwarding:**
   - Update `OData.get_field_value/5` (`lib/creatio/odata.ex`) and `OData3.get_field_value/5` (`lib/creatio/odata3.ex`) so `:req_options`, `:headers`, and query options work cleanly alongside `:into` while preserving `decode_body: false`.
3. **`Creatio.Util` Coverage Hardening (`>= 85%`):**
   - Add targeted unit/regression tests covering edge cases in `lib/creatio/util.ex` (currently `79.84%` in `v0.4.0`): `paginate_stream` with map options, `DateTime` / `NaiveDateTime` / GUID cursor formatting, empty-page/short-page termination, `max_records` / `Query.top` capping, and `clean_guid/1` edge cases.
4. **`usage-rules.md`, Migration Guide & `v1.0.0` Release Prep:**
   - Author a concise `usage-rules.md` in the repository root documenting `creatio` idioms (`Client`, `Query`, `Batch`, `stream` vs `stream!`, `read_only`, `$value` `into:`) and include it in `mix.exs` `package()[:files]`.
   - Document all `0.4.x -> 1.0.0` breaking changes (`@opaque Query/Batch`, `stream/3` tuple items, `from_req/2` env removal, `:req ~> 0.5`) in `CHANGELOG.md` and update `README.md` (`~> 1.0`).
   - Bump `mix.exs` `@version` to `"1.0.0"`, verify `mix hex.build --unpack`, and pass all CI checks (`format`, `compile --warnings-as-errors`, `credo --strict`, `dialyzer`, `test --cover`, `docs`).

## Non-Functional Requirements
- Zero credential leakage in `:telemetry` metadata or logs.
- Every module in `lib/` reaches `>= 85%` test coverage, and `Creatio` ExDocs build with `0` warnings.
- Tagging/pushing `v1.0.0` and running `mix hex.publish` require explicit user confirmation at final release time.

## Acceptance Criteria
- [ ] `:telemetry` events fire reliably for HTTP requests, auth calls, and `$batch` operations, with tests asserting sanitized metadata.
- [ ] `get_field_value/5` honors `:into`, `:headers`, and `:req_options` on both OData 4 and OData 3.
- [ ] `mix test --cover` passes with `Creatio.Util` >= `85%` and overall coverage >= `90%`.
- [ ] `usage-rules.md` is bundled in the Hex tarball (`mix hex.build --unpack`), `CHANGELOG.md` & `README.md` cover `v1.0.0`, and all CI/Dialyzer/Credo/ExDoc checks pass cleanly on `1.0.0`.

## Out of Scope
- Executing `git tag v1.0.0` / `git push` / `mix hex.publish` without explicit user release authorization.
