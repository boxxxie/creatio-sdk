# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-15

### Added

- **`:telemetry` Observability & Credential Redaction (`Creatio.Telemetry`)**:
  - Added `{:telemetry, "~> 1.2"}` runtime dependency and `Creatio.Telemetry` with zero runtime GenServers.
  - Emits `[:creatio, :request, :start | :stop | :exception]` via `Req` lifecycle steps attached by `Creatio.Client`.
  - Emits domain-level `:telemetry.span/3` events across OData 4 (`[:creatio, :odata, *]`), OData 3 (`[:creatio, :odata3, *]`), DataService (`[:creatio, :data_service, *]`), Auth (`[:creatio, :auth, *]`), and Batch (`[:creatio, :batch, *]`).
  - Automatically redacts sensitive headers (`authorization`, `cookie`, `set-cookie`, `bpmcsrf`, `x-api-key`, `proxy-authorization`) and credential metadata (`auth_token`, `client_secret`, `cookie`, `bpmcsrf`, passwords, OAuth tokens) to `"[REDACTED]"`.
- **Exception-Raising Streams (`stream!/3`, `odata3_stream!/3`)**:
  - Added `Creatio.stream!/3`, `Creatio.OData.stream!/3`, `Creatio.odata3_stream!/3`, and `Creatio.OData3.stream!/3` returning plain `record` maps and raising `%Creatio.Error{}` on failure.
- **Field Value Transport Option Forwarding**:
  - Extended `Creatio.get_field_value/5`, `Creatio.OData.get_field_value/5`, `Creatio.odata3_get_field_value/5`, and `Creatio.OData3.get_field_value/5` to forward `:headers`, `:req_options`, and query options alongside `:into` while preserving `decode_body: false`.
- **Opaque Builder Public Accessors & Full Facade `@spec` Coverage**:
  - Added public accessors `Creatio.Batch.size/1`, `Creatio.Batch.requests/1`, `Creatio.OData.Query.entity/1`, `Creatio.OData.Query.get_top/1`, and `Creatio.OData.Query.get_skip/1`.
  - Added explicit `@spec` annotations across every `defdelegate` in `Creatio`.
- **`usage-rules.md` & Opt-In Live Wire Verification**:
  - Added `usage-rules.md` in the repository root and bundled it in the Hex package manifest and ExDoc extras.
  - Added opt-in `@moduletag :live` wire integration suite (`test/live/`) and expanded unit/regression coverage (`mix test --cover`).

### Changed

- **Opaque Builder Contracts (`@opaque t`)**: Converted `Creatio.OData.Query.t()` and `Creatio.Batch.t()` from `@type` to `@opaque` so internal representation fields are excluded from the public SemVer contract.
- **Tuple-Emitting Non-Bang Streams**: Updated `Creatio.stream/3`, `Creatio.OData.stream/3`, `Creatio.odata3_stream/3`, and `Creatio.OData3.stream/3` to yield `{:ok, record}` items and emit `{:error, %Creatio.Error{}}` before halting cleanly on failure instead of raising mid-stream.
- **Explicit `from_req/2` Scoping**: Removed the implicit `System.get_env("CREATIO_BASE_URL")` fallback from `Creatio.Client.from_req/2` (it now uses `:base_url` from `opts` or `req.options[:base_url]`, defaulting to `""`). Environment/application config fallback remains exclusively in `Creatio.Client.new/1`.
- **Tightened Dependency Upper Bound**: Updated `:req` dependency constraint from `>= 0.5.0` to `~> 0.5`.

### Upgrading from 0.4.x to 1.0.0

1. **`stream/3` and `odata3_stream/3` now emit `{:ok, record}` tuples:**
   - Either pattern-match `{:ok, record}` / `{:error, error}` in consumers of `Creatio.stream/3` and `Creatio.odata3_stream/3`:
     ```elixir
     Creatio.stream(client, "Contact", page_size: 100)
     |> Enum.reduce_while([], fn
       {:ok, record}, acc -> {:cont, [record | acc]}
       {:error, error}, acc -> {:halt, {:error, error, acc}}
     end)
     ```
   - Or switch to `Creatio.stream!/3` / `Creatio.odata3_stream!/3` to preserve `0.4.x` behavior (plain `record` maps, raising `%Creatio.Error{}` on failure).
2. **`Creatio.OData.Query` and `Creatio.Batch` structs are `@opaque`:**
   - Replace any direct struct field access (e.g. `query.entity`, `query.top`, `query.skip`, `batch.requests`, `length(batch.ops)`) with public functions: `Query.entity/1`, `Query.get_top/1`, `Query.get_skip/1`, `Query.to_params/1`, `Batch.size/1`, `Batch.requests/1`, and `Batch.to_payload/1`.
3. **`Creatio.Client.from_req/2` no longer reads `CREATIO_BASE_URL`:**
   - Pass `base_url:` via `Req.new(base_url: ...)` or `Creatio.from_req(req, base_url: "...")`, or initialize with `Creatio.new/1` when relying on environment configuration.
4. **Dependency updates:**
   - `:creatio` `1.0.0` requires `{:req, "~> 0.5"}` and introduces `{:telemetry, "~> 1.2"}`.

## [0.4.0] - 2026-11-15

### Added

- **Keyset / Cursor Pagination**: Added `:cursor_field`, `:after_cursor`, and `:max_records` options to `Creatio.stream/3`, `Creatio.OData.stream/3`, `Creatio.odata3_stream/3`, and `Creatio.OData3.stream/3` for `$skip`-free pagination.
- **Streaming Field Downloads & Uploads**: Added `:into` stream sink support and `decode_body: false` to `get_field_value/5`, `get_field_value!/5`, `odata3_get_field_value/5`, and `odata3_get_field_value!/5`, plus `File.Stream` / `Stream` / 2-arity streaming function uploads and `Jason.encode_to_iodata!/1` payloads in `Creatio.OData.update_field/6`.
- **`Prefer: return=minimal` & `return=representation` Support**: Added `:return` option to `Creatio.OData.create/4` (with `204` `odata-entityid` / `location` extraction), `Creatio.OData.update/5`, `Creatio.Batch.new/1`, `Creatio.Batch.add/4`, and `Creatio.Batch.execute/3`.
- **Zero-Copy Batch Multipart Serialization**: Added `Creatio.Batch.to_multipart_iodata/2` and `Creatio.batch_to_multipart_iodata/2`.
- **Pipe-Friendly Facade & Exception Polish**: Added consistent client-first and query/entity-first argument heads with `@spec` typespecs across `Creatio`, added `Creatio.DataService.custom_service!/5`, and implemented `@impl true def message/1` on `Creatio.Error`.
- **ATDD & Regression Suites**: Added 4-layer ATDD feature specifications (`test/features/*`) and `test/creatio/regressions_test.exs`.

### Changed

- **License & Package Metadata**: Changed license from `Apache-2.0` to `MIT` (`LICENSE`, `mix.exs`, `README.md`), included `docs/CREATIO_API_INTEGRATION.md`, `docs/USE_CASES_SYNCING_USERS.md`, and `CHANGELOG.md` in Hex package files, and configured `source_ref` / `source_url` for ExDoc.
- **OData Metadata Negotiation**: Switched default OData 4 and Batch headers from `odata=verbose` to `application/json; odata.metadata=minimal` and centralized `accept` / `forceusesession` defaults in `Creatio.Client` without overwriting caller-supplied headers.
- **O(1) Query & Batch Accumulation**: Replaced repeated list concatenations in `Creatio.OData.Query` and `Creatio.Batch` with reverse-accumulated lists compiled once on serialization, flattened chained `and_filter` clauses while preserving `OR` precedence, and replaced regex-heavy multipart response parsing with byte-level splitting and `:binary.copy/1`.
- **Auth & Read-Only Hardening**: Extracted `identity_base_req/1` in `Creatio.Auth` to avoid leaking CRM session headers to Identity Service endpoints, blocked `batch_query/3`, non-`SelectQuery` `DataService.execute_query/4`, and mutating `/0/rest/` `custom_service/5` calls in read-only mode, and made `put_bearer_token/2` and `put_forms_auth/3` mutually clear prior auth credentials.

### Fixed

- Removed unreachable `nil` fallback guards in `Creatio.Batch` JSON response parsing flagged by Dialyzer.
- Handled case-insensitive `guid'...'` prefixes in GUID sanitization and `Creatio.OData.Query`, latest non-empty `BPMCSRF` cookie selection in `Creatio.Auth`, and expanded Creatio error payload parsing in `Creatio.Error`.

## [0.3.1] - 2026-09-17

### Fixed

- Added `:skip` initial offset support to `Creatio.OData.stream/3` and `Creatio.OData3.stream/3`.
- Updated `README.md`, module docs, and guides for read-only mode and stream offset support.

## [0.3.0] - 2026-09-17

### Added

- Added defense-in-depth read-only mode (`read_only: true` / `CREATIO_READ_ONLY=true`) enforced at SDK mutation functions, batch execution, and a `Req` request-step guard.

## [0.2.0] - 2026-09-17

### Added

- Added inverted function heads on `Creatio`, `Creatio.OData`, and `Creatio.OData3` for pipe-friendly usage.
- Expanded test coverage across batch, error handling, exceptions, query builder, and bang functions.

### Fixed

- Fixed Dialyzer warnings in `Creatio.Batch`, `update_field/6` scalar encoding, `Batch.add/4` keyword headers, `DataService.custom_service/5` keyword payloads, `openid_configuration/2`, `Client.from_req/2`, UTF-8 BOM trimming in collection counts, and OData 3/4 date/datetime literals.
- Consolidated GUID sanitization and optimized stream pagination.

## [0.1.0] - 2026-09-11

### Added

- Initial release of the Creatio Elixir SDK supporting OData 4, OData 3, DataService JSON APIs, Batch requests, Forms authentication, and OAuth 2.0 client credentials.
