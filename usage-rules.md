# Creatio SDK (`creatio`) Usage Rules

Guidance for humans and coding agents using the `:creatio` Elixir SDK (`~> 1.0`).

## Client Initialization & Configuration

- Use `Creatio.new(opts)` (or `Creatio.Client.new(opts)`) for standard applications. It reads fallback values from `Application.get_env(:creatio, ...)` and environment variables (`CREATIO_BASE_URL`, `CREATIO_AUTH_TOKEN`, `CREATIO_BEARER_TOKEN`, `CREATIO_IDENTITY_URL`, `CREATIO_IDENTITY_SERVICE_URL`, `CREATIO_CLIENT_ID`, `CREATIO_CLIENT_SECRET`, `CREATIO_READ_ONLY`).
- Use `Creatio.from_req(req, opts)` (or `Creatio.Client.from_req(req, opts)`) when wrapping an existing `%Req.Request{}`. Unlike `new/1`, `from_req/2` does **not** read `CREATIO_BASE_URL` from the environment; pass `base_url:` in `opts` or configure it on `req`.
- Pass custom transport/test/retry options through `req_options: [...]` on `Creatio.new/1`.
- Never manually strip or hand-build Creatio auth headers alongside mixed auth modes: `Creatio.Client.put_bearer_token/2` and `Creatio.Client.put_forms_auth/3` mutually clear conflicting credentials before updating `client.req`.

## Authentication

- **Forms auth**: Call `{:ok, client} = Creatio.login(client, username, password)`. Rebind `client` from the returned tuple; cookies and `BPMCSRF` are stored on the updated `%Creatio.Client{}`.
- **OAuth 2.0 client credentials**: Configure `:identity_service_url`, `:client_id`, and `:client_secret`, then call `{:ok, client, token_info} = Creatio.login_oauth(client)` and rebind `client`.
- **Health & OIDC discovery**: Use `Creatio.oauth_health_check(client)` and `Creatio.openid_configuration(client_or_url)`.

## Read-Only Safety Mode (`read_only: true`)

- Enable `read_only: true` (or `CREATIO_READ_ONLY=true`) on read replicas, analytics pipelines, or verification scripts.
- All mutation operations (`create/4`, `update/5`, `delete/4`, `update_field/6`, `delete_field/5`, DataService write actions, mutating `custom_service/5` calls, and batches containing write methods) are blocked locally with `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}` and reinforced by a `Req` request step.

## Opaque Builders (`Creatio.OData.Query` & `Creatio.Batch`)

- Both `Creatio.OData.Query.t()` and `Creatio.Batch.t()` are `@opaque`.
- **Do not** pattern-match on or directly read internal struct fields (such as `select_rev`, `filters_rev`, `orderby_rev`, `expand_rev`, `ops`, or `requests`).
- **Always** use the public constructors, pipes, and accessors:
  - Query: `Creatio.query("Contact")`, `Query.select/2`, `Query.filter_eq/4`, `Query.and_filter/2`, `Query.or_filter_eq/4`, `Query.order_by/2`, `Query.top/2`, `Query.skip/2`, `Query.expand/2`, `Query.entity/1`, `Query.get_top/1`, `Query.get_skip/1`, `Query.to_params/1`, `Query.to_query_string/1`.
  - Batch: `Creatio.batch_new(opts)`, `Batch.add_get/2..4`, `Batch.add_create/4`, `Batch.add_update/5`, `Batch.add_delete/4`, `Batch.size/1`, `Batch.requests/1`, `Batch.to_payload/1`, `Batch.to_multipart_iodata/2`, `Batch.to_multipart/2`.

```elixir
# DO: construct and inspect via public builders and accessors
q = Creatio.query("Contact") |> Creatio.OData.Query.select(["Id", "Name"]) |> Creatio.OData.Query.top(25)
entity = Creatio.OData.Query.entity(q)

# DON'T: pattern-match or read internal @opaque fields
%Creatio.OData.Query{entity: entity} = q
```

## Calling Styles & Bang Variants

- All public facade functions live in `Creatio`. Use `{:ok, result}` / `:ok` variants in application pipelines and `!` variants (`list!/3`, `get!/4`, `stream!/3`, `create!/4`, `update!/5`, `delete!/4`, `custom_service!/5`, etc.) only when raising `%Creatio.Error{}` directly is intended.
- `list/3`, `execute/3`, `stream/3`, `odata3_list/3`, `odata3_stream/3` (and their `!` counterparts) accept both client-first (`Creatio.list(client, query, opts)`) and pipe/query-first (`query |> Creatio.list(client, opts)`) argument order.

## Streaming & Pagination (`stream/3` vs `stream!/3`)

- **Default non-bang `stream/3` and `odata3_stream/3` emit `{:ok, record}` tuples** and emit a final `{:error, %Creatio.Error{}}` element before halting if any page fails. Always pattern-match `{:ok, record}` and `{:error, err}` when consuming `stream/3` or `odata3_stream/3`.
- **Use `stream!/3` or `odata3_stream!/3`** when you want plain `record` maps in the stream and want a mid-stream failure to raise `%Creatio.Error{}`.
- Prefer keyset pagination (`cursor_field: "Id"`, optional `after_cursor: last_id`) over large `:skip` offsets on big tables, and use `:max_records` when capping total streamed items.

```elixir
# DO: handle tuple results from stream/3
client
|> Creatio.stream(query, page_size: 200, max_records: 500)
|> Enum.reduce_while([], fn
  {:ok, row}, acc -> {:cont, [row | acc]}
  {:error, err}, _acc -> {:halt, {:error, err}}
end)

# DON'T: assume stream/3 yields bare maps
client |> Creatio.stream(query) |> Enum.map(& &1["Id"])
```

## Binary `$value` Downloads, Uploads & `Prefer` Headers

- Use `Creatio.get_field_value(client, entity, id, field, opts)` (or `odata3_get_field_value/5`) to fetch raw scalars or binary streams without automatic JSON decoding (`decode_body: false` is always enforced, even if `:req_options` passes `decode_body: true`).
- Forward `:into` (e.g. `into: File.stream!("/path/to/file")`), `:headers`, `:req_options`, and OData query options cleanly through `get_field_value/5`.
- When `:into` is a `Collectable` (such as `File.stream!/1`), chunk forwarding is gated to `2xx` responses (`204` returns `{:ok, nil}` without opening/writing the sink): non-`2xx` error bodies stay buffered so `4xx`/`5xx` server payloads never corrupt the target file and are preserved in `%Creatio.Error{}`. For custom 2-arity `into:` funs (`fn {:data, chunk}, {req, resp} -> ... end`), the callback itself controls status gating.
- Upload binaries, `File.Stream`, or arbitrary `Stream` chunks via `Creatio.update_field(client, entity, id, field, data, opts)` (uses `application/octet-stream` for binary/stream bodies or `Jason.encode_to_iodata!/1` for scalar/map values).
- Pass `return: :minimal` on `create/4`, `update/5`, or `Batch.new/1` / `Batch.add/4` to send `Prefer: return=minimal` and extract `Id` / `@odata.id` from `204` `odata-entityid` / `location` headers.

## Batch Requests

- Default `Creatio.batch(client, batch)` sends JSON `$batch` (`/0/odata/$batch`). Pass `format: :multipart` for `multipart/mixed` MIME serialization (or `Creatio.batch_to_multipart_iodata/2` for zero-copy iodata assembly).
- Use `atomicity_group: "group_id"` on mutating batch operations when changeset atomicity is required.

## Telemetry & Secret Redaction

- Attach telemetry handlers to `Creatio.Telemetry.events/0`, which returns all 18 events across 6 namespaces:
  - `[:creatio, :request, :start | :stop | :exception]`
  - `[:creatio, :odata, :start | :stop | :exception]`
  - `[:creatio, :odata3, :start | :stop | :exception]`
  - `[:creatio, :data_service, :start | :stop | :exception]`
  - `[:creatio, :auth, :start | :stop | :exception]`
  - `[:creatio, :batch, :start | :stop | :exception]`
- Route HTTP calls through `Creatio.Client` (or attach `Creatio.Telemetry.attach_req_steps/1` to custom `Req.Request` structs) so request metrics and credential redaction remain active.
- Sensitive headers (`authorization`, `cookie`, `set-cookie`, `bpmcsrf`, `x-api-key`, `proxy-authorization`) and credential metadata keys (`auth_token`, `bearer_token`, `access_token`, `refresh_token`, `client_secret`, `cookie`, `set_cookie`, `bpmcsrf`, `password`, `user_password`, `UserPassword`) are redacted to `"[REDACTED]"`.

## Testing Idioms

- Keep unit and feature tests offline by passing `req_options: [plug: plug_fn]` to `Creatio.new/1`.
- Leave `ExUnit` `:live` tests excluded in CI (`mix test` excludes `:live` by default); only run `mix test --only live` against an explicit sandbox `.env`.
