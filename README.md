# Creatio

[![Hex.pm](https://img.shields.io/hexpm/v/creatio.svg)](https://hex.pm/packages/creatio)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

An idiomatic, full-featured Elixir SDK for the **Creatio CRM** (formerly bpm'online) API.

Built on top of [Req](https://github.com/wojtekmach/req), `Creatio` provides a clean and resilient interface for OData 4, OData 3, DataService JSON APIs, Forms Authentication, and OAuth 2.0 Client Credentials.

---

## Features

- **Authentication**:
  - **OAuth 2.0**: Client credentials grant against Creatio Identity Service (`/connect/token`).
  - **Forms Authentication**: Session cookies (`.ASPXAUTH`, `BPMLOADER`) with automatic `BPMCSRF` extraction and URI decoding.
  - **OAuth Health Checks**: Endpoint checking (`/0/api/OAuthHealthCheck`) and OpenID configuration discovery.
- **OData 4 Support** (`/0/odata/`):
  - Collection listing with `$select`, `$filter`, `$orderby`, `$top`, `$skip`, `$expand`, and inline `$count`.
  - CRUD operations (`create`, `get`, `update`, `delete`).
  - Field-level operations and scalar `$value` access.
  - Binary stream / file uploads via `PUT` with `application/octet-stream`.
  - Composable **Query Builder** (`Creatio.OData.Query`).
  - Lazy auto-paginated streaming (`Creatio.stream/3`).
- **OData 4 Batch Operations** (`/0/odata/$batch`):
  - Full support for JSON batch requests, atomicity groups (changesets), and `Prefer: continue-on-error`.
- **DataService API**:
  - Direct execution of Creatio `SelectQuery` payloads.
  - Calling custom REST services (`/0/rest/...`).
- **OData 3 Support**:
  - Legacy `EntityDataService.svc` endpoint compatibility.
- **Test-Ready**:
  - Easily mockable using standard `Req` plug options (`req_options: [plug: ...]`).

---

## Installation

Add `creatio` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:creatio, "~> 0.1.0"}
  ]
end
```

Or when developing locally in the same repo:

```elixir
def deps do
  [
    {:creatio, path: "creatio"}
  ]
end
```

---

## Configuration & Client Initialization

Initialize a client by specifying your Creatio base URL:

```elixir
client = Creatio.new(base_url: "https://myinstance.creatio.com")
```

You can also configure global defaults in `config/config.exs`:

```elixir
config :creatio,
  base_url: "https://myinstance.creatio.com",
  auth_token: System.get_env("CREATIO_BEARER_TOKEN")
```

---

## Authentication

### 1. Forms Authentication (Username / Password)

```elixir
client = Creatio.new(base_url: "https://myinstance.creatio.com")
{:ok, client} = Creatio.login(client, "IntegrationUser", "SecurePassword123")
```

### 2. OAuth 2.0 (Identity Service)

Recommended for server-to-server synchronization:

```elixir
client = Creatio.new(
  base_url: "https://myinstance.creatio.com",
  identity_service_url: "https://myidentity.creatio.com",
  client_id: "your_client_id",
  client_secret: "your_client_secret"
)

{:ok, client, token_info} = Creatio.login_oauth(client)
```

Verify OAuth functionality at any time:

```elixir
{:ok, status} = Creatio.oauth_health_check(client)
```

---

## OData 4 Operations

### Querying Records

```elixir
# Simple list
{:ok, contacts} = Creatio.list(client, "Contact",
  select: ["Id", "Name", "Email"],
  filter: "Age gt 18",
  orderby: "Name asc",
  top: 10
)

# Request total count inline
{:ok, %{records: contacts, count: total_count}} =
  Creatio.list(client, "Contact", select: ["Id", "Name"], count: true)
```

### Composable Query Builder

```elixir
query =
  Creatio.query("Contact")
  |> Creatio.OData.Query.select(["Id", "Name", "MobilePhone"])
  |> Creatio.OData.Query.filter("Age gt 21 and City/Name eq 'Toronto'")
  |> Creatio.OData.Query.order_by("CreatedOn desc")
  |> Creatio.OData.Query.top(25)
  |> Creatio.OData.Query.skip(50)
  |> Creatio.OData.Query.expand("Account")

{:ok, contacts} = Creatio.list(client, query)
```

### Automatic Streaming / Pagination

Stream records without loading all results into memory at once:

```elixir
Creatio.stream(client, "Contact", page_size: 100, select: ["Id", "Name"])
|> Stream.filter(fn contact -> contact["Name"] != nil end)
|> Enum.take(500)
```

### CRUD Operations

```elixir
# Create
{:ok, new_contact} = Creatio.create(client, "Contact", %{
  "Name" => "John Doe",
  "Email" => "john.doe@example.com"
})

# Retrieve by ID
{:ok, contact} = Creatio.get(client, "Contact", new_contact["Id"])

# Update
:ok = Creatio.update(client, "Contact", contact["Id"], %{
  "JobTitle" => "Managing Director"
})

# Delete
:ok = Creatio.delete(client, "Contact", contact["Id"])
```

### Field & Binary Stream Uploads

```elixir
# Get raw scalar value
{:ok, name} = Creatio.get_field_value(client, "Contact", contact_id, "Name")

# Upload binary / octet-stream (e.g. photo or document)
binary_content = File.read!("avatar.png")
:ok = Creatio.update_field(client, "Contact", contact_id, "Photo", binary_content)

# Delete a field value
:ok = Creatio.delete_field(client, "Contact", contact_id, "Photo")
```

---

## Batch Requests

Execute multiple operations in a single HTTP request using the OData 4 JSON batch format:

```elixir
batch =
  Creatio.batch_new(continue_on_error: true)
  |> Creatio.Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "group1")
  |> Creatio.Batch.add_update("Contact", contact_id, %{"JobTitle" => "VP"}, atomicity_group: "group1")
  |> Creatio.Batch.add_delete("Contact", old_contact_id)

{:ok, responses} = Creatio.batch(client, batch)

Enum.each(responses, fn resp ->
  IO.puts("Request #{resp.id}: status #{resp.status}")
end)
```

---

## API Reference & Postman Collection

Comprehensive API documentation and resources are available in the [`docs/`](docs/) directory:

- [Creatio API & Integration Guide](docs/CREATIO_API_INTEGRATION.md) — Authentication flows, OData 4 protocol endpoints, and entity mapping reference.
- [Postman Collection v2.0](docs/creatio_api_collection.json) — Full 1.8 MB offline Postman collection covering all Creatio endpoints (OAuth 2.0, OData 4 CRUD, streaming, batching, and OData 3).
- [Online Creatio Postman Documentation](https://documenter.getpostman.com/view/10204500/SztHX5Qb?version=latest)
- [Official Postman Environment](https://academy.creatio.com/sites/default/files/documents/downloads/SDK/Creatio.postman_environment.zip)

---

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
