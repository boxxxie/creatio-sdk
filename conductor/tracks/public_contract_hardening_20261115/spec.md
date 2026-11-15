# Track Specification: Public Contract, Struct Encapsulation & Dependency Bounds

## Overview
Before freezing a Semantic Versioning `1.0.0` contract, internal builder fields, inconsistent stream error semantics, implicit `System.get_env` coupling inside `from_req/2`, missing facade `@spec`s, and open-ended `Req` dependency bounds must be locked down. Because making structs opaque and changing `stream/3` return items are intentional breaking changes relative to `0.4.0`, they are grouped cleanly into this pre-`1.0` hardening track.

## Functional Requirements
1. **Opaque Builder Structs & Accessors (`Query`, `Batch`):**
   - Convert `@type t` on `Creatio.OData.Query` (`lib/creatio/odata/query.ex`) and `Creatio.Batch` (`lib/creatio/batch.ex`) to `@opaque t()` so internal accumulation fields (`select_rev`, `filters_rev`, `orderby_rev`, `expand_rev`, `ops`, `requests`) are excluded from the public SemVer contract.
   - Audit internal usage (`lib/`, `test/`) for direct struct field access and add clean public accessors where needed (e.g. `Batch.size/1`, `Batch.requests/1`, `Query.entity/1`) while preserving `Query.to_params/1` and `Batch.to_payload/1` as the canonical projection entrypoints.
   - Verify Dialyzer passes cleanly with `@opaque` enforcement across all callers (including `lib/creatio.ex`, `lib/creatio/odata.ex`, `lib/creatio/odata3.ex`, `lib/creatio/util.ex`, and `test/`).
2. **`stream/3` vs `stream!/3` Return & Error Parity:**
   - Update `Util.paginate_stream/5` (`lib/creatio/util.ex`), `OData.stream/3` (`lib/creatio/odata.ex`), `OData3.stream/3` (`lib/creatio/odata3.ex`), `Creatio.stream/3`, and `Creatio.odata3_stream/3` (`lib/creatio.ex`) so non-bang streams emit `{:ok, record}` items and yield `{:error, %Creatio.Error{}}` followed by halting if a page fetch or response fails (instead of raising).
   - Add `OData.stream!/3` and `Creatio.stream!/3`, and implement `OData3.stream!/3` and `Creatio.odata3_stream!/3` to emit plain `record` maps directly and raise `%Creatio.Error{}` on failure.
3. **Explicit `from_req/2` Scoping & `Client.new/1` Config Separation:**
   - Keep `Application.get_env(:creatio, ...)` (and `System.get_env` fallback behavior) in `Client.new/1` (`lib/creatio/client.ex`).
   - Remove the implicit `System.get_env("CREATIO_BASE_URL")` fallback from `Client.from_req/2` (`lib/creatio/client.ex`) so `from_req/2` relies strictly on `opts` and `req.options[:base_url]`, defaulting `base_url` to `""`.
4. **Dependency Upper Bound & Facade `@spec` Coverage:**
   - Tighten `{:req, ">= 0.5.0"}` in `mix.exs` to `{:req, "~> 0.5"}` since `Creatio.Client` inspects `Req.Request` struct internals (`options`, `request_steps`, `url`, `method`).
   - Add explicit `@spec` annotations for every `defdelegate` in `Creatio` (`lib/creatio.ex`).

## Non-Functional Requirements
- Maintain `>84%` test coverage, zero Dialyzer errors (especially across `@opaque` boundaries), and zero Credo `--strict` issues.
- Update ATDD DSL/Drivers (`test/support/dsl/odata_dsl.ex`, `test/support/drivers/crm_client_driver.ex`, `test/support/drivers/facade_driver.ex`) and feature specs (`test/features/`) cleanly for `{:ok, record}` vs `stream!` semantics.

## Acceptance Criteria
- [ ] Dialyzer passes with `@opaque t()` on `Creatio.OData.Query` and `Creatio.Batch`.
- [ ] `stream/3` (OData 4, OData 3, and `Creatio`) yields `{:ok, record}` and emits `{:error, %Creatio.Error{}}` on failure; `stream!/3` yields `record` and raises `%Creatio.Error{}` on failure across all three modules.
- [ ] `Client.from_req/2` does not read `System.get_env("CREATIO_BASE_URL")` and derives `base_url` solely from `opts` / `req.options[:base_url]`.
- [ ] `mix.exs` constrains `:req` to `"~> 0.5"`, and all public functions in `Creatio` carry `@spec`s verified by `mix docs` and `mix dialyzer`.

## Out of Scope
- Adding `:telemetry` instrumentation or changing `OData.get_field_value/5` options (handled in Track 3).
- Writing live Creatio sandbox integration tests (handled in Track 1).
