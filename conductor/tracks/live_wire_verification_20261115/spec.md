# Track Specification: Live Creatio Integration & Wire Verification

## Overview
All 329 tests in `v0.4.0` currently execute against local `Req`/`Plug` stubs (`test/test_helper.exs` excludes `:live`, and zero `:live` tests currently exist in `test/`). Before locking a `1.0.0` public wire and behavioral contract, this track introduces an opt-in `@moduletag :live` integration test suite and validates every protocol-sensitive change from `v0.4.0` against a live Creatio instance.

## Functional Requirements
1. **Opt-In Live Test Harness & Safety Gates:**
   - Provide a live test helper/module (e.g. `test/live/creatio_live_test.exs` + shared live helper in `test/support/`) tagged `@moduletag :live` so default `mix test` remains 100% offline and hermetic.
   - Support reading connection parameters from `.env` (via existing `test/test_helper.exs` `:live` loader) and expand `.env.example` / `README.md` with optional OAuth2 (`CREATIO_IDENTITY_URL`, `CREATIO_CLIENT_ID`, `CREATIO_CLIENT_SECRET`) and live mutation safety flags (`CREATIO_LIVE_ALLOW_MUTATIONS=true`, `CREATIO_LIVE_ENTITY`).
   - Run read-only tests with `read_only: true` by default so accidental execution against staging/production cannot mutate CRM records.
2. **Read-Only Live Protocol Verification (`read_only: true`):**
   - **Authentication:** Verify Forms login (`Auth.login/3` -> cookie + `BPMCSRF` extraction) and OAuth2 client-credentials (`Auth.authenticate_oauth/4`) when OAuth vars are present.
   - **OData 4 & `odata.metadata=minimal`:** Verify `list/3`, `get/4`, `count/3`, `get_field/5`, and `Query` (`$select`, `$filter`, `$orderby`, `$expand`, GUID formatting) against real Creatio responses.
   - **Keyset Pagination & Streaming:** Verify `stream/3` with `cursor_field: "Id"` vs `$skip` offset pagination parity and confirm ordering/filter escaping against real Creatio OData 4 rules.
   - **Binary `$value` Streaming:** Verify `get_field_value/5` (`decode_body: false`) with and without `into:` stream sink (including `204` empty field behavior).
   - **OData 3 & DataService (`SelectQuery`):** Verify `OData3.list/3`, `OData3.count/3`, and `DataService.select_query/3` still match live Creatio endpoints.
   - **Read-Only `$batch` & Safety Guard:** Verify JSON and `multipart/mixed` read-only `$batch` queries succeed, while write operations are blocked with `ReadOnlyMode`.
3. **Opt-In Mutation & Cleanup Verification (`CREATIO_LIVE_ALLOW_MUTATIONS=true`):**
   - Verify `OData.create/4` and `OData.update/5` with `Prefer: return=minimal` (`204` header extraction for `odata-entityid` / `location`) vs `return: :representation`.
   - Verify `OData.update_field/6`, `OData.delete/4`, and `$batch` `atomicityGroup` changeset execution, cleaning up created test records inside `on_exit/1`.
4. **Wire Regression Capture:**
   - Capture any live protocol discrepancies discovered during testing in `test/creatio/regressions_test.exs` (and `test/support/drivers/creatio_server_driver.ex`) and fix them in `lib/` before proceeding to Track 2.

## Non-Functional Requirements
- Default CI (`mix test --cover`) must still pass completely offline with zero live credentials configured.
- Live tests must never leave orphaned test records on a sandbox when `on_exit` runs cleanly.

## Acceptance Criteria
- [ ] Running `mix test` excludes `:live` and passes offline with zero skipped failures in CI.
- [ ] Running `mix test --only live` against a live Creatio instance validates auth, OData 3/4, `odata.metadata=minimal`, keyset pagination, `$value` streaming, `$batch`, `Prefer: return=minimal`, and `DataService.select_query/3`.
- [ ] Any discrepancies between stub assumptions (`CreatioServerDriver`) and live Creatio wire responses are fixed and covered by unit/regression tests.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`, and `mix test --cover` pass.

## Out of Scope
- Running `:live` tests automatically in `.gitlab-ci.yml` without dedicated sandbox secrets.
- Changing public struct opacity or breaking API signatures (covered in Track 2).
