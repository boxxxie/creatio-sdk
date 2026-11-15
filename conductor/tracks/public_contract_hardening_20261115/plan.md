# Implementation Plan: Public Contract, Struct Encapsulation & Dependency Bounds

## Phase 1: Opaque Struct Encapsulation (`Query` & `Batch`)
- [x] Task: Audit direct field access and add failing Dialyzer/unit tests for opaque `Query` & `Batch`
    - [x] Grep `lib/` and `test/` for direct pattern matches or field reads on `%Query{}` and `%Batch{}` internals (`select_rev`, `filters_rev`, `orderby_rev`, `expand_rev`, `ops`, `requests`).
    - [x] Add unit tests covering public accessors (e.g., `Query.entity/1`, `Batch.size/1`, `Batch.requests/1`) and confirming callers never depend on raw accumulator fields.
- [x] Task: Mark `Creatio.OData.Query.t()` and `Creatio.Batch.t()` as `@opaque` and refactor internal callers
    - [x] Update `@type t` to `@opaque t` in `lib/creatio/odata/query.ex` and `lib/creatio/batch.ex`, plus clean helper accessors for internal modules (`lib/creatio/util.ex`, `lib/creatio/odata.ex`, `lib/creatio/odata3.ex`).
    - [x] Run `mix dialyzer` and `mix test --cover` to verify zero opacity violations across `lib/` and `test/`.
- [x] Task: Conductor - User Manual Verification 'Phase 1: Opaque Struct Encapsulation (`Query` & `Batch`)' (Protocol in workflow.md)

## Phase 2: `stream/3` vs `stream!/3` Contract Separation
- [x] Task: Write failing ATDD specs and unit tests for non-bang `{:ok, record} | {:error, %Creatio.Error{}}` vs bang `stream!/3`
    - [x] Update `test/features/odata_entities_test.exs`, `test/features/odata3_legacy_entities_test.exs`, `test/features/sdk_facade_and_resilience_test.exs`, and `test/creatio/regressions_test.exs` with failing assertions expecting `{:ok, record}` / `{:error, error}` in `stream/3` and plain raising behavior in `OData.stream!/3`, `OData3.stream!/3`, `Creatio.stream!/3`, and `Creatio.odata3_stream!/3`.
    - [x] Update `test/support/dsl/odata_dsl.ex` and drivers as needed while keeping existing offset/keyset pagination scenarios failing cleanly in Red phase.
- [x] Task: Implement safe non-bang streaming and `OData.stream!/3` / `Creatio.stream!/3`
    - [x] Update `Util.paginate_stream/5` (`lib/creatio/util.ex`) to return a stream of `{:ok, record}` / `{:error, %Creatio.Error{}}` (halting after yielding `{:error, error}`) and provide a raising stream helper (or mode option) for `stream!/3`.
    - [x] Add `OData.stream!/3` in `lib/creatio/odata.ex` and `Creatio.stream!/3` in `lib/creatio.ex`; wire `OData3.stream!/3` and `Creatio.odata3_stream!/3` to the raising path and update `@doc` / `@spec`s.
    - [x] Run `mix test --cover`, `mix credo --strict`, and `mix dialyzer` to verify Green phase.
- [x] Task: Conductor - User Manual Verification 'Phase 2: `stream/3` vs `stream!/3` Contract Separation' (Protocol in workflow.md)

## Phase 3: Client `from_req/2` Scoping, `:req` Bounds & Facade `@spec`s
- [x] Task: Decouple `Client.from_req/2` from `System.get_env`
    - [x] Write a failing unit test in `test/creatio/client_test.exs` verifying `Client.from_req/2` ignores `System.get_env("CREATIO_BASE_URL")` when neither `opts[:base_url]` nor `req.options[:base_url]` is set.
    - [x] Remove `System.get_env("CREATIO_BASE_URL")` from `Client.from_req/2` in `lib/creatio/client.ex` while preserving `Client.new/1` fallback behavior.
- [x] Task: Tighten `:req` constraint and complete `Creatio` facade `@spec`s
    - [x] Update `{:req, ">= 0.5.0"}` to `{:req, "~> 0.5"}` in `mix.exs` and verify `mix deps.get` / `mix test`.
    - [x] Add `@spec` annotations above every `defdelegate` in `lib/creatio.ex` and verify `mix dialyzer`, `mix credo --strict`, `mix docs`, and `mix format --check-formatted`.
- [x] Task: Conductor - User Manual Verification 'Phase 3: Client `from_req/2` Scoping, `:req` Bounds & Facade `@spec`s' (Protocol in workflow.md)
