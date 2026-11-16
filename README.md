# Creatio

[![CI](https://img.shields.io/github/actions/workflow/status/boxxxie/creatio-sdk/ci.yml?branch=master&label=CI&logo=github)](https://github.com/boxxxie/creatio-sdk/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/creatio.svg?logo=elixir)](https://hex.pm/packages/creatio)
[![Hex.pm Downloads](https://img.shields.io/hexpm/dt/creatio.svg)](https://hex.pm/packages/creatio)
[![HexDocs](https://img.shields.io/badge/docs-hexdocs-4B275F.svg?logo=readthedocs&logoColor=white)](https://hexdocs.pm/creatio)
[![Elixir](https://img.shields.io/badge/Elixir-1.19%2B-4B275F.svg?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![OTP](https://img.shields.io/badge/OTP-28%2B-A90533.svg?logo=erlang&logoColor=white)](https://www.erlang.org)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub last commit](https://img.shields.io/github/last-commit/boxxxie/creatio-sdk)](https://github.com/boxxxie/creatio-sdk/commits/master)

An idiomatic Elixir SDK for integrating with **Creatio CRM** (formerly bpm'online) over OData 4, legacy OData 3, DataService JSON APIs, and custom REST web services. Built on [Req](https://github.com/wojtekmach/req) with zero runtime GenServers.

---

## Why `Creatio`?

Integrating Elixir services with Creatio CRM via raw HTTP calls quickly runs into Creatio-specific protocol quirks and operational hazards. `Creatio` gives you a single, well-typed SDK that handles them cleanly out of the box:

- **One client across all Creatio APIs**: Query modern OData 4 entities (`/0/odata/`), run transactional OData 4 `$batch` changesets, call legacy OData 3 collections (`EntityDataService.svc`), execute DataService `SyncReply` queries, and invoke custom `/0/rest/` endpoints without hand-rolling separate HTTP wrappers.
- **Turnkey authentication & session management**: Supports both OAuth 2.0 Client Credentials (`/connect/token` against Creatio Identity Service) and Forms Authentication (`AuthService.svc/Login` session cookies + automatic `BPMCSRF` extraction and URI decoding). Switching auth modes automatically clears conflicting credentials.
- **Creatio wire quirks handled automatically**:
  - Sets `ForceUseSession: true`, `odata.metadata=minimal`, and `IEEE754Compatible=true` headers automatically.
  - Formats unquoted GUIDs for OData 4 and `guid'...'` literals for OData 3, preserves `OR` precedence in composable queries, and works around Creatio's lack of OData `in` via `filter_in/4` and `filter_in_ids/4`.
  - Decodes JSON even when IIS returns `text/html` or a UTF-8 BOM, strips BOMs from `$count` payloads, and rejects HTTP 200 HTML/WAF interstitials (such as Incapsula challenges) instead of letting corrupt data enter your pipeline.
- **Memory-safe pagination & streaming**: Lazy `Stream` pagination handles `$top`/`$skip` offsets, server-driven `@odata.nextLink` / `__next` (`$skiptoken` / `$deltatoken`) continuation, and `$skip`-free keyset/cursor pagination with `(cursor_field, Id)` tie-breaking, plus `into:` `Collectable` stream gating for binary `$value` downloads.
- **Defense-in-depth safety & secret hygiene**: Enforce client-side `read_only: true` across SDK functions, batches, DataService calls, and `Req` request steps; rely on redacted `Inspect` output on `%Creatio.Client{}`; and get 18 structured `:telemetry` events with automatic header and credential redaction.

---

## Installation

Requires **Elixir ~> 1.19** (OTP 28+). Add `:creatio` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:creatio, "~> 1.0"}
  ]
end
```

---

## Quick Start

Connect with OAuth 2.0 (or `Creatio.login/4` for Forms auth), build a query, stream records lazily, and run CRUD operations through the top-level `Creatio` module:

```elixir
# 1. Initialize and authenticate
client =
  Creatio.new(
    base_url: "https://myinstance.creatio.com",
    identity_service_url: "https://myidentity.creatio.com",
    client_id: System.fetch_env!("CREATIO_CLIENT_ID"),
    client_secret: System.fetch_env!("CREATIO_CLIENT_SECRET")
  )

{:ok, client, _token_info} = Creatio.login_oauth(client)

# 2. Query records using the pipe-friendly OData 4 query builder
{:ok, contacts} =
  Creatio.query("Contact")
  |> Creatio.OData.Query.select(["Id", "Name", "Email"])
  |> Creatio.OData.Query.filter_eq("Active", true)
  |> Creatio.OData.Query.filter_contains("Name", "Smith")
  |> Creatio.OData.Query.order_by("CreatedOn desc")
  |> Creatio.OData.Query.top(25)
  |> Creatio.list(client)

# 3. Create, update, and delete
{:ok, created} =
  Creatio.create(client, "Contact", %{"Name" => "Ada Lovelace", "Email" => "ada@example.com"})

:ok = Creatio.update(client, "Contact", created["Id"], %{"JobTitle" => "CTO"}, return: :minimal)
:ok = Creatio.delete(client, "Contact", created["Id"])

# 4. Stream large collections without loading everything into memory
client
|> Creatio.stream!("Contact", page_size: 200, cursor_field: "Id", select: ["Id", "Name"])
|> Stream.take(1_000)
|> Enum.to_list()
```

---

## Which API Should I Use?

All everyday operations are delegated directly from the top-level `Creatio` facade module:

| Use Case | Recommended Module / Functions | When to Use |
| :--- | :--- | :--- |
| **Standard CRUD, Queries & Streams** | `Creatio` / `Creatio.OData` | Default choice for modern Creatio (`7.16+` / `8.x` Freedom UI) entity reads, writes, counts, `$value` binaries, and auto-pagination. |
| **Composable OData Filters** | `Creatio.query/1` + `Creatio.OData.Query` | When dynamically composing `$select`, `$filter`, `OR`/`IN` groups, `$orderby`, `$expand`, and pagination parameters. |
| **Multi-Operation Changesets** | `Creatio.batch_new/1` + `Creatio.Batch` + `Creatio.batch/3` | When bundling multiple reads/writes into one HTTP roundtrip (`$batch` JSON or `multipart/mixed`) or atomic changesets (`atomicity_group`). |
| **Complex Joins / Custom Endpoints** | `Creatio.select_query/3`, `Creatio.custom_service/5` (`Creatio.DataService`) | When calling Creatio `SelectQuery` SyncReply payloads or custom C# configuration services under `/0/rest/{Service}/{Endpoint}`. |
| **Legacy Entities** | `Creatio.odata3_*` (`Creatio.OData3`) | Only when integrating with older Creatio instances or schemas still exposed via `/0/ServiceModel/EntityDataService.svc/`. |

### Calling Conventions & Bang (`!`) Variants

- **Tuple vs. Raising (`!`)**: Every I/O function returns `{:ok, result}` / `:ok` or `{:error, %Creatio.Error{}}`. Use the `!` variant (`list!/3`, `get!/4`, `create!/4`, `update!/5`, `delete!/4`, `stream!/3`, `batch!/3`, `custom_service!/5`, etc.) when you want to unwrap results and raise `Creatio.Error` on failure.
- **Client-first or Pipe-first**: `list/3`, `execute/3`, `count/3`, `stream/3`, `odata3_list/3`, `odata3_count/3`, and `odata3_stream/3` (and their `!` variants) accept both `Creatio.list(client, query, opts)` and `query |> Creatio.list(client, opts)`.

---

## Configuration & Client Initialization

Initialize an isolated client per tenant, job, or process via `Creatio.new/1` (reads explicit `opts` first, falling back to `Application.get_env(:creatio, ...)` and environment variables):

```elixir
client = Creatio.new(base_url: "https://myinstance.creatio.com")
```

For production Phoenix/OTP releases, configure defaults in `config/runtime.exs`:

```elixir
config :creatio,
  base_url: System.get_env("CREATIO_BASE_URL"),
  auth_token: System.get_env("CREATIO_BEARER_TOKEN"),
  read_only: System.get_env("CREATIO_READ_ONLY") in ["true", "1"]
```

You can also wrap an existing `%Req.Request{}` with `Creatio.from_req(req, opts)` (for custom Finch pools, telemetry, or test plugs). Unlike `Creatio.new/1`, `from_req/2` does **not** implicitly read `CREATIO_BASE_URL` or `CREATIO_READ_ONLY` from environment variables—pass `base_url:` or `read_only:` explicitly in `opts` or on `req`.

### Client Options & Environment Variables

| Option | Env Var | Description |
| :--- | :--- | :--- |
| `:base_url` | `CREATIO_BASE_URL` | Base URL of your Creatio CRM instance |
| `:auth_token` / `:bearer_token` | `CREATIO_AUTH_TOKEN` / `CREATIO_BEARER_TOKEN` | Bearer access token for OAuth 2.0 |
| `:identity_service_url` | `CREATIO_IDENTITY_URL` / `CREATIO_IDENTITY_SERVICE_URL` | Identity Service base URL for OAuth 2.0 |
| `:client_id` | `CREATIO_CLIENT_ID` | OAuth 2.0 client ID |
| `:client_secret` | `CREATIO_CLIENT_SECRET` | OAuth 2.0 client secret |
| `:read_only` | `CREATIO_READ_ONLY` | Defense-in-depth read-only mode (`true`, `"true"`, `"1"`, or `false`) |
| `:cookie` | - | Pre-existing session cookie string for Forms auth |
| `:bpmcsrf` | - | Pre-existing `BPMCSRF` token for Forms auth |
| `:req_options` | - | Extra keyword options forwarded to `Req.new/1` (e.g., `:plug`, `:retry`, `:receive_timeout`) |

> **Safe Logging**: `Creatio.Client` implements a custom `Inspect` protocol that displays only `:base_url`, `:auth_mode`, `:identity_service_url`, `:client_id`, and `:read_only`, ensuring secrets and cookies are never dumped into logs or crash reports.

---

## Authentication

### 1. OAuth 2.0 (Recommended for Server-to-Server Sync)

```elixir
client =
  Creatio.new(
    base_url: "https://myinstance.creatio.com",
    identity_service_url: "https://myidentity.creatio.com",
    client_id: "your_client_id",
    client_secret: "your_client_secret"
  )

{:ok, client, token_info} = Creatio.login_oauth(client)

# Optional diagnostics
{:ok, health} = Creatio.oauth_health_check(client)
{:ok, oidc} = Creatio.openid_configuration(client)
```

### 2. Forms Authentication (Username / Password)

```elixir
client = Creatio.new(base_url: "https://myinstance.creatio.com")
{:ok, client} = Creatio.login(client, "IntegrationUser", "SecurePassword123")
```

To update credentials manually on an existing client, use `Creatio.Client.put_bearer_token/2` or `Creatio.Client.put_forms_auth/3`—each clears credentials from the other auth mode automatically.

---

## Defense-in-Depth Read-Only Mode

When running read replicas, analytics exports, dry-run migrations, or verification scripts, set `read_only: true` (or `CREATIO_READ_ONLY=true`) to guarantee the client cannot mutate CRM records:

```elixir
client = Creatio.new(base_url: "https://myinstance.creatio.com", read_only: true)

# Reads succeed normally
{:ok, contacts} = Creatio.list(client, "Contact")
{:ok, count} = Creatio.count(client, "Contact")
{:ok, res} = Creatio.select_query(client, %{"RootSchemaName" => "Account"})

# Any mutation is blocked locally without hitting the network
{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
  Creatio.create(client, "Contact", %{"Name" => "Test"})
```

Read-only mode is enforced across three layers:
1. **SDK mutation functions**: `create/4`, `update/5`, `delete/4`, `update_field/6`, `delete_field/5`, OData 3 mutations, and DataService write queries (`insert_query/3`, `update_query/3`, `delete_query/3`, `batch_query/3`, plus non-GET/HEAD/OPTIONS `custom_service/5` calls) return `ReadOnlyMode` immediately.
2. **Batch validation**: Any batch containing write methods (`POST`, `PATCH`, `PUT`, `DELETE`) or raw binary multipart bodies is rejected.
3. **HTTP request-step guard**: A `Req` request step blocks outbound non-read requests (with path-traversal checks) while permitting safe read-only auth/query endpoints (`/SelectQuery`, `/Login`, `/token`, `/AuthService.svc/Login`).

---

## OData 4 Operations

### Querying & Counting Records

```elixir
# Option-based list
{:ok, contacts} =
  Creatio.list(client, "Contact",
    select: ["Id", "Name", "Email"],
    filter: "Age gt 18",
    orderby: "Name asc",
    top: 10
  )

# Inline total count (`%{records: [...], count: integer}`)
{:ok, %{records: contacts, count: total_count}} =
  Creatio.list(client, "Contact", select: ["Id", "Name"], count: true)

# Standalone count (accepts entity name or Query.t(); pass `strategy: :top_zero` if `/$count` is disabled)
{:ok, total} = Creatio.count(client, "Contact", filter: "Active eq true")
```

### Composable Query Builder (`Creatio.OData.Query`)

```elixir
alias Creatio.OData.Query

query =
  Creatio.query("Contact")
  |> Query.select(["Id", "Name", "MobilePhone"])
  |> Query.filter_gt("Age", 21)
  |> Query.filter_contains("Name", "Smith")
  |> Query.filter_eq("City/Name", "Toronto")
  |> Query.or_filter_eq("JobTitle", "Director")
  |> Query.order_by("CreatedOn desc")
  |> Query.top(25)
  |> Query.skip(50)
  |> Query.expand("Account")

{:ok, contacts} = Creatio.list(client, query)
```

Supported filter helpers:
- Comparisons: `filter_eq/4`, `filter_ne/4`, `filter_gt/4`, `filter_ge/4`, `filter_lt/4`, `filter_le/4` (and `or_filter_*` variants; pass `quoted: false` or use `filter_guid/4` for unquoted OData 4 GUIDs)
- String & date functions: `filter_contains/3`, `filter_startswith/3`, `filter_endswith/3`, `filter_day/4`, `filter_length/4`, `filter_not/2` (plus `or_filter_*` variants)
- Multi-value `IN` emulation: `filter_in/4`, `or_filter_in/4`, `filter_in_ids/4` (expands to `(Id eq uuid1 or Id eq uuid2)` since Creatio OData 4 omits the `in` operator)

`Creatio.OData.Query.t()` is `@opaque`; inspect built queries with `Query.entity/1`, `Query.get_top/1`, `Query.get_skip/1`, `Query.to_params/1`, and `Query.to_query_string/1`.

### Automatic Streaming / Pagination

Choose the stream variant that matches your error-handling style:
- `Creatio.stream/3` (and `odata3_stream/3`) yields `{:ok, record}` tuples and emits a final `{:error, %Creatio.Error{}}` before halting cleanly if a page fails.
- `Creatio.stream!/3` (and `odata3_stream!/3`) yields plain `record` maps directly and raises `Creatio.Error` on failure.

Both support `$top`/`$skip` offset pagination, automatic `@odata.nextLink` / `__next` (`$skiptoken` / `$deltatoken`) continuation under server row caps, and `$skip`-free keyset pagination (`:cursor_field`, `:after_cursor`, `:max_records`):

```elixir
# Safe tuple-emitting stream
result =
  client
  |> Creatio.stream("Contact", page_size: 100, select: ["Id", "Name"])
  |> Enum.reduce_while([], fn
    {:ok, contact}, acc -> {:cont, [contact | acc]}
    {:error, error}, _acc -> {:halt, {:error, error}}
  end)

# Keyset / cursor pagination (avoids deep `$skip` overhead; tie-breaks non-`Id` cursors with `Id`)
contacts =
  client
  |> Creatio.stream!("Contact",
    page_size: 200,
    cursor_field: "ModifiedOn",
    after_cursor: ~U[2026-11-01 00:00:00Z],
    max_records: 1_000,
    select: ["Id", "Name", "ModifiedOn"]
  )
  |> Enum.to_list()
```

### CRUD & Navigation Operations

```elixir
# Create (pass `return: :minimal` to avoid echoing all columns; extracts Id from `odata-entityid` / `location` on 204)
{:ok, created} =
  Creatio.create(client, "Contact", %{"Name" => "John Doe", "Email" => "john@example.com"})

# Retrieve by ID or follow navigation property
{:ok, contact} = Creatio.get(client, "Contact", created["Id"], select: ["Id", "Name", "AccountId"])
{:ok, account} = Creatio.get_navigation(client, "Contact", created["Id"], "Account")

# Update & Delete
:ok = Creatio.update(client, "Contact", contact["Id"], %{"JobTitle" => "VP"}, return: :minimal)
:ok = Creatio.delete(client, "Contact", contact["Id"])
```

### Field & Binary `$value` Transfers

```elixir
# JSON property read vs. raw un-decoded `$value` (`decode_body: false` enforced)
{:ok, name} = Creatio.get_field(client, "Contact", contact_id, "Name")
{:ok, raw_name} = Creatio.get_field_value(client, "Contact", contact_id, "Name")

# Stream large attachments directly to disk (Collectable sinks are gated to 2xx/non-WAF responses; supports 206 Partial Content)
{:ok, _stream} =
  Creatio.get_field_value(client, "SysFile", file_id, "Data",
    into: File.stream!("/tmp/attachment.bin"),
    headers: [{"range", "bytes=0-1048575"}]
  )

# Upload binary, `File.Stream`, `IO.Stream`, or `Stream` via PUT (`application/octet-stream`)
:ok = Creatio.update_field(client, "Contact", contact_id, "Photo", File.stream!("avatar.png"))
:ok = Creatio.delete_field(client, "Contact", contact_id, "Photo")
```

---

## Batch Requests

Bundle multiple OData 4 operations into a single `POST /0/odata/$batch` request using JSON (default) or `multipart/mixed` MIME serialization:

```elixir
alias Creatio.Batch

batch =
  Creatio.batch_new(continue_on_error: true, return: :minimal)
  |> Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "g1")
  |> Batch.add_update("Contact", contact_id, %{"JobTitle" => "VP"}, atomicity_group: "g1")
  |> Batch.add_delete("Contact", old_contact_id)

# JSON `$batch` (default) or `format: :multipart`
{:ok, responses} = Creatio.batch(client, batch)

Enum.each(responses, fn resp ->
  if Batch.Response.success?(resp) do
    IO.puts("Sub-request #{resp.id} succeeded (#{resp.status})")
  else
    err = Batch.Response.to_error(resp)
    IO.puts("Sub-request #{resp.id} failed: #{Exception.message(err)}")
  end
end)
```

`Creatio.Batch.t()` is `@opaque`; inspect queued operations with `Batch.size/1`, `Batch.requests/1`, `Batch.to_payload/1`, `Batch.to_multipart_iodata/2`, or `Batch.to_multipart/2`.

---

## DataService & Custom REST Services

```elixir
# DataService SyncReply queries (`select_query/3`, `insert_query/3`, `update_query/3`, `delete_query/3`, `batch_query/3`)
{:ok, res} = Creatio.select_query(client, %{"RootSchemaName" => "Account"})

# Custom Creatio REST WebServices (`/0/rest/{Service}/{Endpoint}`)
{:ok, res} = Creatio.custom_service(client, "CustomService", "Endpoint", %{"param" => "value"})
{:ok, status} = Creatio.custom_service(client, "HealthService", "Ping", method: :get)
```

---

## Legacy OData 3 Support

Full compatibility for legacy `EntityDataService.svc` endpoints, including offset/keyset streaming and `into:` field downloads:

```elixir
{:ok, contacts} = Creatio.odata3_list(client, "Contact", top: 10, count: true)
{:ok, contact}  = Creatio.odata3_get(client, "Contact", contact_id)
{:ok, account}  = Creatio.odata3_get_navigation(client, "Contact", contact_id, "Account")
{:ok, name}     = Creatio.odata3_get_field(client, "Contact", contact_id, "Name")
{:ok, raw_name} = Creatio.odata3_get_field_value(client, "Contact", contact_id, "Name")
{:ok, count}    = Creatio.odata3_count(client, "Contact")
{:ok, created}  = Creatio.odata3_create(client, "Contact", %{"Name" => "Legacy"})
:ok             = Creatio.odata3_update(client, "Contact", contact_id, %{"Name" => "Updated"})
:ok             = Creatio.odata3_delete(client, "Contact", contact_id)

Creatio.odata3_stream!(client, "Contact", page_size: 100)
|> Enum.take(250)
```

---

## Error Handling (`Creatio.Error`)

Operational and HTTP failures return `{:error, %Creatio.Error{}}` (or raise `%Creatio.Error{}` from `!` functions) with normalized `:status`, `:code`, `:message`, `:details`, and `:response` fields:

```elixir
case Creatio.get(client, "Contact", contact_id) do
  {:ok, contact} ->
    {:ok, contact}

  {:error, %Creatio.Error{status: 404}} ->
    {:error, :not_found}

  {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} ->
    {:error, :read_only_violation}

  {:error, %Creatio.Error{} = err} ->
    Logger.error("Creatio request failed: #{Exception.message(err)}")
    {:error, err}
end
```

---

## Telemetry & Observability

`Creatio` emits 18 standard `:telemetry` events via `Creatio.Telemetry` with zero background GenServers:

- **HTTP Requests (`Creatio.Client` via `Req` steps)**:
  - `[:creatio, :request, :start]` (`%{system_time: integer(), monotonic_time: integer()}`)
  - `[:creatio, :request, :stop]` (`%{duration: integer(), monotonic_time: integer()}`, metadata includes `:method`, `:path`, `:base_url`, `:auth_mode`, `:status`, `:result`, and redacted `:headers`)
  - `[:creatio, :request, :exception]` (`%{duration: integer(), monotonic_time: integer()}`, metadata includes `:kind`, `:reason`, `:error`, `:status`, `:result`, `:stacktrace`)
- **Domain Spans (`:telemetry.span/3`)**:
  - `[:creatio, :odata, :start | :stop | :exception]` (`:protocol` `:odata4`, `:action`, `:entity`, `:result`)
  - `[:creatio, :odata3, :start | :stop | :exception]` (`:protocol` `:odata3`, `:action`, `:entity`, `:result`)
  - `[:creatio, :data_service, :start | :stop | :exception]` (`:action`, `:entity` / `:service` / `:endpoint`, `:result`)
  - `[:creatio, :auth, :start | :stop | :exception]` (`:auth_mode`, `:result`)
  - `[:creatio, :batch, :start | :stop | :exception]` (`:format`, `:operation_count`, `:status`, `:result`, and `:error_count` on `:stop`)

Sensitive headers (`authorization`, `cookie`, `set-cookie`, `bpmcsrf`, `x-api-key`, `proxy-authorization`) and credential metadata keys (`auth_token`, `bearer_token`, `access_token`, `refresh_token`, `client_secret`, `cookie`, `bpmcsrf`, passwords) are automatically replaced with `"[REDACTED]"`:

```elixir
:telemetry.attach_many(
  "my-app-creatio-metrics",
  Creatio.Telemetry.events(),
  fn event, measurements, metadata, _config ->
    Logger.debug("creatio event=#{inspect(event)} meas=#{inspect(measurements)} meta=#{inspect(metadata)}")
  end,
  nil
)
```

---

## Testing in Your Application & Live Sandbox Verification

### Unit-Testing Host Code (`Req` Plugs)

Pass `req_options: [plug: ...]` to `Creatio.new/1` to run fast, `async: true` tests with zero network calls:

```elixir
defmodule MyApp.CrmSyncTest do
  use ExUnit.Case, async: true

  test "fetches active contacts without hitting the network" do
    plug = fn conn ->
      assert conn.request_path == "/0/odata/Contact"
      Req.Test.json(conn, %{"value" => [%{"Id" => "1", "Name" => "Alice"}]})
    end

    client = Creatio.new(base_url: "https://example.creatio.com", req_options: [plug: plug])
    assert {:ok, [%{"Name" => "Alice"}]} = Creatio.list(client, "Contact")
  end
end
```

### SDK Test Suite & Live Sandbox Verification (`--only live`)

All offline unit and ATDD feature tests exclude `:live` tests by default:

```bash
mix test
```

To run end-to-end wire verification against a live Creatio sandbox without modifying CRM data:

1. Copy `.env.example` to `.env` and populate your sandbox URL plus OAuth 2.0 (`CREATIO_IDENTITY_SERVICE_URL`, `CREATIO_CLIENT_ID`, `CREATIO_CLIENT_SECRET`) or Forms (`CREATIO_USERNAME`, `CREATIO_PASSWORD`) credentials.
2. Run read-only live verification (`read_only: true` is enforced by default):

```bash
mix test --only live
```

To explicitly enable the opt-in CRUD & `$batch` changeset roundtrip test (which creates isolated synthetic test records and removes them in `on_exit/1`):

```bash
CREATIO_LIVE_ALLOW_MUTATIONS=true mix test --only live
```

Set `CREATIO_LIVE_STRICT=true` in CI to fail instead of skipping when sandbox credentials are absent or the endpoint is unreachable/WAF-gated.

---

## Further Reading & Resources

- [Usage Rules (`usage-rules.md`)](usage-rules.md) — Concise idioms, invariants, and gotchas for Elixir developers and coding agents (bundled in the Hex package).
- [Changelog (`CHANGELOG.md`)](CHANGELOG.md) — Release history and the `0.4.x` -> `1.0.0` migration guide.
- [Creatio API & Integration Guide](docs/CREATIO_API_INTEGRATION.md) — Authentication flows, OData 4 protocol endpoints, and entity mapping reference.
- [Syncing Creatio Users Guide](docs/USE_CASES_SYNCING_USERS.md) — Step-by-step tutorial on building a resilient sync engine between Creatio and a local database.
- [Postman Collection v2.0](docs/creatio_api_collection.json) — Offline Postman collection covering Creatio OAuth 2.0, OData 4 CRUD, streaming, batching, and OData 3 endpoints.
- [Online Creatio Postman Documentation](https://documenter.getpostman.com/view/10204500/SztHX5Qb?version=latest)
- [Official Postman Environment](https://academy.creatio.com/sites/default/files/documents/downloads/SDK/Creatio.postman_environment.zip)

---

## License

Licensed under the MIT License. See [LICENSE](LICENSE) for details.
