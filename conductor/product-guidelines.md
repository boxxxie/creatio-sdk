# Product Guidelines: `creatio` (`creatio-sdk`)

## SemVer & Public API Contract (`1.0.0` Readiness)
1. **Strict Encapsulation Before `1.0.0`:** Internal accumulation fields (`select_rev`, `filters_rev`, `ops`, etc.) must not be relied on by external callers. Public builder structs (`Creatio.OData.Query`, `Creatio.Batch`) must hide internal mechanics behind `@opaque t()` and constructor/projection functions (`Query.to_params/1`, `Batch.to_payload/1`).
2. **Consistent Return Contracts:**
   - Standard operations return `{:ok, value} | {:error, %Creatio.Error{}}`.
   - Bang variants (`!*`) return `value` or raise `%Creatio.Error{}`.
   - Lazy streams distinguish non-bang `stream/3` (yielding `{:ok, record} | {:error, %Creatio.Error{}}`) from bang `stream!/3` (yielding `record` and raising `%Creatio.Error{}`).
3. **Composable Per-Client Configuration:** `Creatio.Client.from_req/2` and request helpers must never silently pull process/OS environment variables (`System.get_env/1`), preserving multi-tenant and test isolation. `Application.get_env(:creatio, ...)` defaults live exclusively in `Creatio.Client.new/1`.
4. **Defense-in-Depth Safety:** Read-only guarantees must hold across both high-level API wrappers and the `Req` request pipeline step (`read_only_guard`), including `/0/rest/` writes and binary `$batch` payloads.

## Documentation & DX
- **Complete Typespecs & ExDocs:** Every public module and public function (including `Creatio` facade `defdelegate`s) carries `@moduledoc`, `@doc`, and `@spec` verified by `mix docs` (0 warnings) and `mix dialyzer` (0 errors).
- **No Underscores in MathJax:** In `README.md`, `CHANGELOG.md`, and docs, always use backtick inline code spans (e.g. `` `odata.metadata=minimal` ``) rather than `$...$` blocks.
- **License & Attribution:** MIT licensed (`LICENSE`, `mix.exs`).
