# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
