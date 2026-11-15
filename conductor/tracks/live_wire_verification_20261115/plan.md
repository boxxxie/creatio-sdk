# Implementation Plan: Live Creatio Integration & Wire Verification

## Phase 1: Live Test Harness & Configuration Safety
- [x] Task: Document and configure live-test environment variables
    - [x] Update `.env.example` and `README.md` with optional `CREATIO_IDENTITY_URL`, `CREATIO_CLIENT_ID`, `CREATIO_CLIENT_SECRET`, `CREATIO_LIVE_ENTITY`, `CREATIO_LIVE_ALLOW_MUTATIONS`, and `CREATIO_LIVE_STRICT` flags (and configure local `.env` from `../connect/.env.staging` with `CREATIO_READ_ONLY=true`).
    - [x] Add a live-suite setup helper (`test/support/live_helper.ex`) that skips cleanly with an explicit diagnostic reason when `CREATIO_BASE_URL` / credentials are unset or blocked by a WAF/network challenge (such as Imperva Incapsula), and enforces `read_only: true` unless `CREATIO_LIVE_ALLOW_MUTATIONS=true`.
- [x] Task: Write live smoke-test suite under `@moduletag :live`
    - [x] Create `test/live/creatio_live_test.exs` with `@moduletag :live` verifying client construction, Forms authentication, and OAuth2 client-credentials (`login_oauth/1`, `openid_configuration/1`, `oauth_health_check/1`).
    - [x] Confirm `mix test` excludes `:live` offline while `mix test --only live` executes cleanly.
- [x] Task: Conductor - Verification 'Phase 1: Live Test Harness & Configuration Safety'

## Phase 2: Read-Only Live Protocol Suite
- [x] Task: Add live OData 4, Query, and `odata.metadata=minimal` verification tests
    - [x] Write `:live` tests for `OData.list/3`, `OData.get/4`, `OData.count/3` (`:path` and `:top_zero`), `OData.get_field/5`, `OData.get_navigation/5`, and `Query` builders (`$select`, `$filter`, `$orderby`, `$expand`, GUID literals).
    - [x] Verify `OData.get_field_value/5` (`decode_body: false`) raw binary retrieval and `into:` streaming sink handling (including `204` responses).
- [x] Task: Add live pagination, DataService, OData 3, and read-only Batch tests
    - [x] Write `:live` tests comparing `OData.stream/3` offset pagination against `cursor_field: "Id"` keyset pagination on the configured test entity.
    - [x] Write `:live` tests for `OData3.list/3`, `OData3.count/3`, `OData3.stream/3`, `DataService.select_query/3`, and read-only `$batch` (both `:json` and `:multipart` formats) plus `ReadOnlyMode` enforcement checks.
- [x] Task: Conductor - Verification 'Phase 2: Read-Only Live Protocol Suite'

## Phase 3: Opt-In Mutation Roundtrip & Regression Capture
- [x] Task: Add opt-in mutation tests (`CREATIO_LIVE_ALLOW_MUTATIONS=true`) with cleanup
    - [x] Write `:live` tests covering `OData.create/4` and `OData.update/5` with `return: :minimal` (`204` header handling) vs `return: :representation`, `OData.update_field/6`, and `OData.delete/4`.
    - [x] Write `:live` tests for `$batch` changeset execution (`atomicityGroup`) and register deterministic `on_exit/1` record cleanup via `Creatio.LiveHelper.register_cleanup/3`.
- [x] Task: Capture live Creatio wire findings in mock drivers and regressions
    - [x] Probe live sandbox (`https://763309-caasa.creatio.com`) and cross-check official Postman collection / `connect` `SyncCreatio` usage. Observed Imperva Incapsula WAF HTML challenge (`/_Incapsula_Resource` HTTP `200 OK`) from this host IP and captured 4 wire discrepancies:
        1. IIS `Content-Type: text/html; charset=utf-8` (plus UTF-8 BOM) on JSON responses vs. HTTP `200` HTML WAF/login interstitials (`Creatio.Util.normalize_json_response/1`, `Creatio.Util.html_or_xml_response?/1`, and guards across `OData`, `OData3`, `Auth`, `DataService`, and `Batch`).
        2. Nested `$expand` comma corruption across parentheses in `Creatio.OData.Query.expand/2` (`split_top_level_commas/1`).
        3. `OData.create/4` `return: :minimal` (`204 No Content`) case-insensitive `OData-EntityId` / `Location` header lookup and `"Id"` extraction alongside `"@odata.id"`.
        4. `Client.new/1` and `Client.from_req/2` trailing slash normalization on `identity_service_url`.
    - [x] Update `test/support/drivers/creatio_server_driver.ex`, `test/creatio/regressions_test.exs`, `test/creatio/odata/query_test.exs`, `test/creatio/client_test.exs`, `test/creatio/util_test.exs`, and `lib/`, and pass all offline quality gates (`format`, `compile --warnings-as-errors`, `credo --strict`, `dialyzer`, `test --cover`, `docs`) plus `mix test --only live`.
- [x] Task: Conductor - Verification 'Phase 3: Opt-In Mutation Roundtrip & Regression Capture'
