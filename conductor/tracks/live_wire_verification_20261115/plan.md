# Implementation Plan: Live Creatio Integration & Wire Verification

## Phase 1: Live Test Harness & Configuration Safety
- [ ] Task: Document and configure live-test environment variables
    - [ ] Update `.env.example` and `README.md` with optional `CREATIO_IDENTITY_URL`, `CREATIO_CLIENT_ID`, `CREATIO_CLIENT_SECRET`, `CREATIO_LIVE_ENTITY`, and `CREATIO_LIVE_ALLOW_MUTATIONS` flags.
    - [ ] Add a live-suite setup helper (under `test/support/live_helper.ex`) that skips cleanly with an explicit reason when `CREATIO_BASE_URL` / credentials are unset and enforces `read_only: true` unless `CREATIO_LIVE_ALLOW_MUTATIONS=true`.
- [ ] Task: Write failing smoke-test skeleton under `@moduletag :live`
    - [ ] Create `test/live/creatio_live_test.exs` with `@moduletag :live` verifying client construction, Forms authentication, and OAuth2 client-credentials (conditional on env vars).
    - [ ] Confirm `mix test` ignores `:live` offline while `mix test --only live` executes the new suite cleanly.
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Live Test Harness & Configuration Safety' (Protocol in workflow.md)

## Phase 2: Read-Only Live Protocol Suite
- [ ] Task: Add live OData 4, Query, and `odata.metadata=minimal` verification tests
    - [ ] Write `:live` tests for `OData.list/3`, `OData.get/4`, `OData.count/3`, `OData.get_field/5`, and `Query` builders (`$select`, `$filter`, `$orderby`, `$expand`, GUID literals).
    - [ ] Verify `OData.get_field_value/5` (`decode_body: false`) raw binary retrieval and `into:` streaming sink handling (including `204` responses).
- [ ] Task: Add live pagination, DataService, OData 3, and read-only Batch tests
    - [ ] Write `:live` tests comparing `OData.stream/3` offset pagination against `cursor_field: "Id"` keyset pagination on the configured test entity.
    - [ ] Write `:live` tests for `OData3.list/3`, `OData3.count/3`, `DataService.select_query/3`, and read-only `$batch` (both JSON and `:multipart` formats) plus `ReadOnlyMode` enforcement checks.
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Read-Only Live Protocol Suite' (Protocol in workflow.md)

## Phase 3: Opt-In Mutation Roundtrip & Regression Capture
- [ ] Task: Add opt-in mutation tests (`CREATIO_LIVE_ALLOW_MUTATIONS=true`) with cleanup
    - [ ] Write `:live` tests covering `OData.create/4` and `OData.update/5` with `return: :minimal` (`204` header handling) vs `return: :representation`, plus `delete/4`.
    - [ ] Write `:live` tests for `$batch` changeset execution (`atomicityGroup`) and register deterministic `on_exit/1` record cleanup.
- [ ] Task: Capture live Creatio wire findings in mock drivers and regressions
    - [ ] Run `mix test --only live` against a sandbox Creatio instance and log any wire/header/response differences.
    - [ ] Update `test/support/drivers/creatio_server_driver.ex`, `test/creatio/regressions_test.exs`, and `lib/` for any discovered discrepancies, then run full offline quality gates (`format`, `credo --strict`, `dialyzer`, `test --cover`, `docs`).
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Opt-In Mutation Roundtrip & Regression Capture' (Protocol in workflow.md)
