# Product Definition: `creatio` (`creatio-sdk`)

## Vision
`creatio` is a production-grade, idiomatic Elixir SDK for the Creatio CRM API. Built directly on `Req` and `Jason`, it gives Elixir applications and data pipelines a safe, composable, well-typed interface to Creatio's OData 4, OData 3, `$batch`, DataService (`SyncReply`), and custom REST (`/0/rest/`) endpoints—without leaky HTTP boilerplate.

## Target Users
- **Elixir Backend & Integration Engineers:** Syncing CRM entities (`Contact`, `Account`, custom entities), webhooks, and files into internal services or Phoenix apps.
- **ETL & Batch Pipeline Maintainers:** Streaming large datasets lazily via offset or keyset pagination and executing high-throughput OData `$batch` mutations.
- **Automation & Audit Consumers:** Querying production Creatio instances safely using strict defense-in-depth `read_only` mode.

## Core Capabilities (Baseline: `v0.4.0`)
- **Authentication:** OAuth 2.0 Client Credentials (`IdentityService` / `/connect/token` with form-encoded and Basic auth fallback) and Forms (`AuthService.svc/Login` cookie + `BPMCSRF` extraction), isolating credentials cleanly across auth modes.
- **OData 4 & OData 3 Protocols:** Full CRUD, navigation/field/raw `$value` endpoints (with `into:` stream sink support), `$count`, `$expand`, and `Prefer: return=minimal` / `return=representation`.
- **Composable Query Builder:** Fluent `Creatio.OData.Query` supporting `$select`, `$filter`, `$orderby`, `$top`, `$skip`, `$expand`, boolean/date/GUID formatting, and O(1) accumulation.
- **Lazy Pagination Streams:** Offset (`$top`/`$skip`) and keyset/cursor (`cursor_field:`) lazy streaming over OData 4 and OData 3 collections.
- **OData `$batch` Engine:** JSON and `multipart/mixed` batch request construction (`O(1)` accumulation + iodata serialization) with `atomicityGroup` / changesets and `Prefer` headers.
- **DataService & Custom REST:** `select_query`, `insert_query`, `update_query`, `delete_query`, `batch_query`, `execute_query`, and `/0/rest/{Service}/{Endpoint}` helpers.
- **Read-Only Safety Guard:** Defense-in-depth blocking at both module entrypoints and the `Req` request step level against unintended mutations.

## v1.0.0 Roadmap Goal
Validate `v0.4.0` protocol behavior against a live Creatio instance (`@tag :live` opt-in suite), lock down public SemVer boundaries (`@opaque` structs, `Req` bounds, explicit `from_req` scoping, `{:ok, record} | {:error, %Creatio.Error{}}` stream ergonomics, complete `@spec`s), and add operational observability (`:telemetry`) and agent/AI usage documentation before cutting `v1.0.0`.
