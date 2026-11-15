# Implementation Plan: 1.0 Polish, Telemetry & Release Readiness

## Phase 1: `:telemetry` Instrumentation & Credential Redaction
- [ ] Task: Add `:telemetry` dependency and failing telemetry tests
    - [ ] Document `{:telemetry, "~> 1.2"}` in `conductor/tech-stack.md` and add it to `mix.exs`.
    - [ ] Write failing unit/ATDD tests asserting `[:creatio, :request, *]`, `[:creatio, :auth, *]`, and `[:creatio, :batch, *]` events plus secret redaction.
- [ ] Task: Implement `:telemetry` spans/events across `Client`, `Auth`, and `Batch`
    - [ ] Attach a safe `Req` telemetry step/hook in `Creatio.Client` and instrument `Creatio.Auth` and `Creatio.Batch`.
    - [ ] Verify all telemetry tests, Credo `--strict`, and Dialyzer pass cleanly.
- [ ] Task: Conductor - User Manual Verification 'Phase 1: `:telemetry` Instrumentation & Credential Redaction' (Protocol in workflow.md)

## Phase 2: `get_field_value/5` Options & `Creatio.Util` Coverage
- [ ] Task: Extend `get_field_value/5` options (`:headers`, `:req_options`, `:into`)
    - [ ] Write failing tests in `test/creatio/` verifying `OData.get_field_value/5` and `OData3.get_field_value/5` forward custom headers/req options while keeping `decode_body: false`.
    - [ ] Implement safe option merging in `lib/creatio/odata.ex` and `lib/creatio/odata3.ex` and update `@doc`/`@spec`.
- [ ] Task: Bring `Creatio.Util` test coverage above `85%`
    - [ ] Write unit/regression tests covering remaining branches in `lib/creatio/util.ex` (cursor types, map options, `max_records` + `top`, error paths, `clean_guid/1`).
    - [ ] Confirm `mix test --cover` reports `>= 85%` on `Creatio.Util`.
- [ ] Task: Conductor - User Manual Verification 'Phase 2: `get_field_value/5` Options & `Creatio.Util` Coverage' (Protocol in workflow.md)

## Phase 3: `usage-rules.md`, `1.0.0` Migration Docs & Release Verification
- [ ] Task: Create `usage-rules.md` and update Hex package manifest & docs
    - [ ] Write `usage-rules.md` documenting public API conventions (`Creatio`, `Query`, `Batch`, `stream/3` vs `stream!/3`, `read_only`, `into:` streaming) and add it to `package()[:files]` in `mix.exs`.
    - [ ] Update `README.md` (`~> 1.0`, telemetry docs, streaming return types) and `CHANGELOG.md` (`1.0.0` migration guide).
- [ ] Task: Bump version to `1.0.0` and verify release packaging & CI gates
    - [ ] Update `@version "1.0.0"` in `mix.exs` (`docs()` / `source_ref: "v1.0.0"`).
    - [ ] Run `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, `mix test --cover`, `mix docs`, and `mix hex.build --unpack` (cleaning up build scratch artifacts afterward).
    - [ ] Wait for explicit user approval before tagging `v1.0.0`, pushing to `origin`, or running `mix hex.publish`.
- [ ] Task: Conductor - User Manual Verification 'Phase 3: `usage-rules.md`, `1.0.0` Migration Docs & Release Verification' (Protocol in workflow.md)
