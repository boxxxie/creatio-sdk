# Implementation Plan: ATDD Test Suite Refactoring, Matrix Consolidation & Regression Deduplication

## Phase 1: Eliminate Facade "DSL Theater" & Consolidate Loop Matrices (`test/features/`)
- [x] Task: Replace `169` loop-generated scenarios in `test/features/sdk_facade_and_resilience_test.exs`
    - [x] Replace `@given crm_facade_server()` scenarios with explicit, concrete Layer 1 ATDD scenarios covering bang (`!`) raising, non-bang error tuples, stream `{:error, %Creatio.Error{}}` halting, and transport timeout resilience.
    - [x] Move the exhaustive `@facade_cases` (`82`), `@bang_error_operations` (`36`), `@timeout_operations` (`34`), and `@tuple_error_operations` (`13`) sweeps into compact table-driven contract checks with clear per-case failure attribution.
- [x] Task: Consolidate loop-generated tables in `read_only_safety_test.exs`, `odata_entities_test.exs`, and `odata3_legacy_entities_test.exs`
    - [x] Refactor `@blocked_mutations`, `@allowed_transport_requests`, and `@blocked_transport_requests` in `test/features/read_only_safety_test.exs` into concise table-driven checks keeping the explicit tables in Layer 1.
    - [x] Refactor `@count_format_cases` in `test/features/odata_entities_test.exs` and `@odata3_count_cases` in `test/features/odata3_legacy_entities_test.exs` into single table-driven scenarios per protocol.
    - [x] Run `mix test --cover` to verify 100% assertion parity and coverage preservation.
- [x] Task: Conductor - User Manual Verification 'Phase 1: Eliminate Facade "DSL Theater" & Consolidate Loop Matrices (`test/features/`)' (Protocol in workflow.md)

## Phase 2: Promote Behavioral Regressions into 4-Layer ATDD Feature Specs (`regressions_test.exs` -> `test/features/`)
- [x] Task: Inventory `test/creatio/regressions_test.exs` and promote OData 4 & OData 3 behavioral scenarios
    - [x] Add explicit Layer 1 ATDD scenarios (and minimal Layer 2/3 DSL/driver support in `odata_dsl.ex` / `creatio_server_driver.ex`) in `test/features/odata_entities_test.exs` and `test/features/odata3_legacy_entities_test.exs` for: keyset (`cursor_field`) pagination, `@odata.nextLink` / `__next` server-capped streaming, `Prefer: return=minimal` + `204 OData-EntityId` / `Location` extraction, `206 Partial Content` Range downloads, `into: Collectable` 2xx sink gating, `204` nil navigation/field responses, and IIS `text/html` JSON / WAF HTML interstitial handling.
- [x] Task: Promote Auth, Batch, DataService, and Read-Only behavioral regressions to `test/features/`
    - [x] Add explicit Layer 1 ATDD scenarios in `test/features/authentication_test.exs`, `test/features/batch_operations_test.exs`, `test/features/data_service_and_rest_test.exs`, and `test/features/read_only_safety_test.exs` for: `Client.from_req/2` plug preservation and `token_url` in OAuth/OIDC, `+` in `BPMCSRF` and `Set-Cookie` deduplication, `DataService` & `Batch` `ReadOnlyMode` `403` preservation, `custom_service` keyword/empty-list/GET/DELETE payload handling, and `Batch` `return: :minimal` / minimal metadata headers.
    - [x] Remove the migrated behavioral tests from `test/creatio/regressions_test.exs` and verify `mix test --cover`.
- [x] Task: Conductor - User Manual Verification 'Phase 2: Promote Behavioral Regressions into 4-Layer ATDD Feature Specs (`regressions_test.exs` -> `test/features/`)' (Protocol in workflow.md)

## Phase 3: Migrate Low-Level Regression Checks & Consolidate Unit Suites (`test/creatio/`)
- [x] Task: Move remaining parser, validation, and security-guard checks from `regressions_test.exs` into owning unit test files
    - [x] Move URL/path-traversal validation, `clean_guid/1`, `prepare_field_value_request/4`, integer parsing, and WAF/JSON helper edge cases into `test/creatio/util_test.exs`.
    - [x] Move `Query` `and_filter` flattening, `OR` precedence, and `custom_params` checks into `test/creatio/odata/query_test.exs`.
    - [x] Move `Batch` O(1) accumulation, iodata multipart, boundary/atomicity-group/header-injection validation into `test/creatio/batch_test.exs`, and `Auth`/`Client` option validation into `test/creatio/client_test.exs`.
    - [x] Delete `test/creatio/regressions_test.exs` once 100% of its unique assertions are accounted for in `test/features/` or `test/creatio/*_test.exs`.
- [x] Task: Consolidate repetitive unit micro-tests in `error_test.exs`, `client_test.exs`, `query_test.exs`, and `util_test.exs`
    - [x] Group the 10 `Error.from_response/1` payload tests in `test/creatio/error_test.exs` and repetitive initialization/option tests in `test/creatio/client_test.exs`, `test/creatio/odata/query_test.exs`, and `test/creatio/util_test.exs` into clean table-driven tests.
    - [x] Run `mix test --cover` and confirm all unit and feature tests pass with `>84%` coverage.
- [x] Task: Conductor - User Manual Verification 'Phase 3: Migrate Low-Level Regression Checks & Consolidate Unit Suites (`test/creatio/`)' (Protocol in workflow.md)

## Phase 4: Prune Layer 2/3 Driver Bloat & Final Quality Gate Audit
- [x] Task: Clean up dead code in `test/support/dsl/` and `test/support/drivers/`
    - [x] Remove `test/support/drivers/facade_driver.ex` (or reduce to any still-used helpers) and prune unused dispatch clauses from `test/support/drivers/crm_client_driver.ex` and `test/support/dsl/safety_dsl.ex`.
    - [x] Verify all remaining Layer 2 `@then` macros preserve `__CALLER__.line` failure attribution and Layer 1 scenarios contain zero opaque zero-argument setup steps.
- [x] Task: Run full CI quality gates and verify test count and coverage targets
    - [x] Run `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test --cover && mix docs` *(all gates passed except `mix dialyzer` which reports 20 pre-existing `@spec`/unreachable-clause warnings solely inside untouched `lib/` files; see `spec.md` Deviation Note)*.
    - [x] Confirm active test count is in the `~160–220` range (`179` active tests), total coverage exceeds `84%` (`89.11%`), and 0 warnings/errors are emitted by compiler, Credo, ExUnit, or ExDoc.
- [x] Task: Conductor - User Manual Verification 'Phase 4: Prune Layer 2/3 Driver Bloat & Final Quality Gate Audit' (Protocol in workflow.md)
