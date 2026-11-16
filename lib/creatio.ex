defmodule Creatio do
  @moduledoc """
  Elixir SDK for Creatio CRM (formerly bpm'online).

  Provides an idiomatic, comprehensive client for interacting with Creatio instances
  via OData 4, OData 3, DataService JSON APIs, Forms Authentication, and OAuth 2.0.

  ## Quick Start

  ### Forms Authentication

      client = Creatio.new(base_url: "https://myinstance.creatio.com")
      {:ok, client} = Creatio.login(client, "User01", "Password123")

      # List contacts
      {:ok, contacts} = Creatio.list(client, "Contact", select: ["Id", "Name", "Email"], top: 10)

  ### OAuth 2.0 Client Credentials

      client = Creatio.new(
        base_url: "https://myinstance.creatio.com",
        identity_service_url: "https://myidentity.creatio.com",
        client_id: "your_client_id",
        client_secret: "your_client_secret"
      )

      {:ok, client, _token} = Creatio.login_oauth(client)

  ### OData 4 Query Builder

      {:ok, results} =
        Creatio.query("Contact")
        |> Creatio.OData.Query.select(["Id", "Name", "MobilePhone"])
        |> Creatio.OData.Query.filter_contains("Name", "Smith")
        |> Creatio.OData.Query.filter_eq("Active", true)
        |> Creatio.OData.Query.order_by("CreatedOn desc")
        |> Creatio.OData.Query.top(20)
        |> Creatio.list(client)

  ### Streaming / Auto-pagination

      # Seamlessly iterates over pages using $top and $skip with optional initial :skip offset.
      # Use `Creatio.stream/3` to handle `{:ok, record}` / `{:error, error}` tuples safely,
      # or `Creatio.stream!/3` to stream plain record maps and raise `Creatio.Error` on failure:
      Creatio.stream!(client, "Contact", page_size: 100, skip: 500, select: ["Id", "Name"])
      |> Stream.map(& &1["Name"])
      |> Enum.take(250)

  ### Read-Only Safety Mode

      # Protect production CRM data by enforcing client-side read-only mode
      client = Creatio.new(base_url: "https://myinstance.creatio.com", read_only: true)

      # Queries succeed normally:
      {:ok, contacts} = Creatio.list(client, "Contact")

      # All mutation attempts are blocked locally with status 403 / "ReadOnlyMode":
      {:error, %Creatio.Error{code: "ReadOnlyMode"}} = Creatio.create(client, "Contact", %{"Name" => "Jane"})

  ### Batch Operations

      batch =
        Creatio.batch_new(continue_on_error: true)
        |> Creatio.Batch.add_create("Contact", %{"Name" => "John Doe"})
        |> Creatio.Batch.add_update("Contact", "some-uuid", %{"JobTitle" => "Director"})

      {:ok, responses} = Creatio.batch(client, batch)
  """

  alias Creatio.{Auth, Batch, Client, DataService, Error, OData, OData3}
  alias Creatio.OData.Query

  @type record_id :: String.t() | integer() | atom()
  @type opts :: keyword() | map()

  @doc """
  Builds a new `Creatio.Client`.

  ## Options

    * `:base_url` - The base URL of the Creatio instance (e.g. `"https://myinstance.creatio.com"`).
    * `:auth_token` - OAuth 2.0 Bearer access token.
    * `:cookie` - Cookie string for Forms authentication.
    * `:bpmcsrf` - CSRF token string for Forms authentication.
    * `:identity_service_url` - Base URL for Creatio Identity Service.
    * `:client_id` - OAuth 2.0 client ID.
    * `:client_secret` - OAuth 2.0 client secret.
    * `:read_only` - If `true`, enables defense-in-depth read-only mode to prevent mutation requests (defaults to `false`, or `Application.get_env(:creatio, :read_only)`, or `CREATIO_READ_ONLY` env var).
    * `:req_options` - Extra options passed directly to `Req.new/1`.
  """
  @spec new(keyword() | map() | Req.Request.t()) :: Client.t()
  defdelegate new(opts \\ []), to: Client

  @doc """
  Builds a `Creatio.Client` from an existing `Req.Request`.
  """
  @spec from_req(Req.Request.t(), keyword() | map()) :: Client.t()
  defdelegate from_req(req, opts \\ []), to: Client

  @doc """
  Authenticates via Forms authentication using username and password.
  """
  @spec login(Client.t() | Req.Request.t(), String.t(), String.t(), opts()) ::
          {:ok, Client.t()} | {:error, Error.t()}
  defdelegate login(client_or_req, username, password, opts \\ []), to: Auth, as: :login_forms

  @doc """
  Authenticates via OAuth 2.0 client credentials against the Identity Service.
  """
  @spec login_oauth(Client.t(), keyword()) :: {:ok, Client.t(), map()} | {:error, Error.t()}
  defdelegate login_oauth(client, opts \\ []), to: Auth

  @doc """
  Checks OAuth health endpoint (`/0/api/OAuthHealthCheck`).
  """
  @spec oauth_health_check(Client.t(), opts()) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  defdelegate oauth_health_check(client, opts \\ []), to: Auth

  @doc """
  Retrieves OpenID configuration (`/.well-known/openid-configuration`).
  """
  @spec openid_configuration(Client.t() | String.t(), opts()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate openid_configuration(url_or_client, opts \\ []), to: Auth

  @doc """
  Initializes a new `Creatio.OData.Query` builder.
  """
  @spec query(String.t()) :: Query.t()
  def query(entity) when is_binary(entity), do: Query.new(entity)

  @doc """
  Initializes a new `Creatio.Batch` request.
  """
  @spec batch_new(opts()) :: Batch.t()
  def batch_new(opts \\ []), do: Batch.new(opts)

  @doc """
  Adds a generic sub-request to a `Creatio.Batch`.
  """
  @spec batch_add(Batch.t(), String.t() | atom(), String.t(), opts()) :: Batch.t()
  defdelegate batch_add(batch, method, url, opts \\ []), to: Batch, as: :add

  @doc """
  Adds an OData `GET` operation to a `Creatio.Batch`.
  """
  @spec batch_get(Batch.t(), String.t()) :: Batch.t()
  @spec batch_get(Batch.t(), String.t(), opts() | record_id()) :: Batch.t()
  @spec batch_get(Batch.t(), String.t(), record_id(), opts()) :: Batch.t()
  defdelegate batch_get(batch, entity_or_path, opts_or_id \\ []), to: Batch, as: :add_get
  defdelegate batch_get(batch, entity, id, opts), to: Batch, as: :add_get

  @doc """
  Adds an OData `POST` creation operation to a `Creatio.Batch`.
  """
  @spec batch_create(Batch.t(), String.t(), map(), opts()) :: Batch.t()
  defdelegate batch_create(batch, entity, attrs, opts \\ []), to: Batch, as: :add_create

  @doc """
  Adds an OData `PATCH` update operation to a `Creatio.Batch`.
  """
  @spec batch_update(Batch.t(), String.t(), record_id(), map(), opts()) :: Batch.t()
  defdelegate batch_update(batch, entity, id, attrs, opts \\ []), to: Batch, as: :add_update

  @doc """
  Adds an OData `DELETE` operation to a `Creatio.Batch`.
  """
  @spec batch_delete(Batch.t(), String.t(), record_id(), opts()) :: Batch.t()
  defdelegate batch_delete(batch, entity, id, opts \\ []), to: Batch, as: :add_delete

  @doc """
  Serializes a batch to `{boundary, iodata}` without intermediate binary copying.
  """
  @spec batch_to_multipart_iodata(Batch.t(), opts()) :: {String.t(), iodata()}
  defdelegate batch_to_multipart_iodata(batch, opts \\ []), to: Batch, as: :to_multipart_iodata

  @doc """
  Serializes a batch to a multipart/mixed MIME body string. Returns `{boundary, body}`.
  """
  @spec batch_to_multipart(Batch.t(), opts()) :: {String.t(), String.t()}
  defdelegate batch_to_multipart(batch, opts \\ []), to: Batch, as: :to_multipart

  @doc """
  Parses a multipart/mixed batch response body.
  """
  @spec batch_parse_multipart(String.t(), String.t() | nil) ::
          {:ok, [Batch.Response.t()]} | {:error, Error.t()}
  defdelegate batch_parse_multipart(body, boundary \\ nil),
    to: Batch,
    as: :parse_multipart_response

  @doc """
  Queries an entity collection (`GET /0/odata/{Entity}`).

  Supports both client-first (`Creatio.list(client, "Contact", opts)`) and
  pipe/query-first (`Creatio.query("Contact") |> Creatio.list(client, opts)` or
  `Creatio.list("Contact", client, opts)`) argument order.
  """
  @spec list(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: {:ok, list() | map()} | {:error, Error.t()}
  defdelegate list(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Same as `list/3`, raising `Creatio.Error` on failure.

  Supports both client-first and pipe/query-first argument order.
  """
  @spec list!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: list() | map()
  defdelegate list!(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Executes an OData query or entity listing. Alias for `list/3`.

  Supports both client-first and pipe/query-first argument order.
  """
  @spec execute(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: {:ok, list() | map()} | {:error, Error.t()}
  defdelegate execute(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Same as `execute/3`, raising `Creatio.Error` on failure.

  Supports both client-first and pipe/query-first argument order.
  """
  @spec execute!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: list() | map()
  defdelegate execute!(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Retrieves a single entity by its primary ID (`GET /0/odata/{Entity}({id})`).
  """
  @spec get(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate get(client, entity, id, opts \\ []), to: OData

  @doc """
  Same as `get/4`, raising `Creatio.Error` on failure.
  """
  @spec get!(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) :: map()
  defdelegate get!(client, entity, id, opts \\ []), to: OData

  @doc """
  Retrieves related records via a navigation property (`GET /0/odata/{Entity}({id})/{Property}`).
  """
  @spec get_navigation(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  defdelegate get_navigation(client, entity, id, nav_property, opts \\ []), to: OData

  @doc """
  Same as `get_navigation/5`, raising `Creatio.Error` on failure.
  """
  @spec get_navigation!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: any()
  defdelegate get_navigation!(client, entity, id, nav_property, opts \\ []), to: OData

  @doc """
  Retrieves a specific field value by ID (`GET /0/odata/{Entity}({id})/{Field}`).
  """
  @spec get_field(Client.t() | Req.Request.t(), String.t(), record_id(), String.t(), opts()) ::
          {:ok, any()} | {:error, Error.t()}
  defdelegate get_field(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Same as `get_field/5`, raising `Creatio.Error` on failure.
  """
  @spec get_field!(Client.t() | Req.Request.t(), String.t(), record_id(), String.t(), opts()) ::
          any()
  defdelegate get_field!(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Retrieves raw scalar/stream value (`GET /0/odata/{Entity}({id})/{Field}/$value`).

  Supports `:into` (`into: File.stream!("/path/to/file")`), `:headers`, `:req_options`
  (preserving `decode_body: false`), and OData query options (`:select`, `:params`, etc.).
  """
  @spec get_field_value(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: {:ok, any()} | {:error, Error.t()}
  defdelegate get_field_value(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Same as `get_field_value/5`, raising `Creatio.Error` on failure.
  """
  @spec get_field_value!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: any()
  defdelegate get_field_value!(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Gets total count of an entity collection (`GET /0/odata/{Entity}/$count`).
  """
  @spec count(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: {:ok, integer()} | {:error, Error.t()}
  defdelegate count(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Same as `count/3`, raising `Creatio.Error` on failure.
  """
  @spec count!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: integer()
  defdelegate count!(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Creates an entity record (`POST /0/odata/{Entity}`).

  Pass `return: :minimal` to send `Prefer: return=minimal` and avoid echoing all columns back.
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), opts()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate create(client, entity, attrs, opts \\ []), to: OData

  @doc """
  Same as `create/4`, raising `Creatio.Error` on failure.
  """
  @spec create!(Client.t() | Req.Request.t(), String.t(), map(), opts()) :: map()
  defdelegate create!(client, entity, attrs, opts \\ []), to: OData

  @doc """
  Updates an entity record (`PATCH /0/odata/{Entity}({id})`).

  Pass `return: :minimal` or `return: :representation` to control the `Prefer` header.
  """
  @spec update(Client.t() | Req.Request.t(), String.t(), record_id(), map(), opts()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  defdelegate update(client, entity, id, attrs, opts \\ []), to: OData

  @doc """
  Same as `update/5`, raising `Creatio.Error` on failure.
  """
  @spec update!(Client.t() | Req.Request.t(), String.t(), record_id(), map(), opts()) ::
          :ok | map()
  defdelegate update!(client, entity, id, attrs, opts \\ []), to: OData

  @doc """
  Deletes an entity record (`DELETE /0/odata/{Entity}({id})`).
  """
  @spec delete(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) ::
          :ok | {:error, Error.t()}
  defdelegate delete(client, entity, id, opts \\ []), to: OData

  @doc """
  Same as `delete/4`, raising `Creatio.Error` on failure.
  """
  @spec delete!(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) :: :ok
  defdelegate delete!(client, entity, id, opts \\ []), to: OData

  @doc """
  Updates a field or octet-stream binary (`PUT /0/odata/{Entity}({id})/{Field}`).
  """
  @spec update_field(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          any(),
          opts()
        ) :: :ok | {:error, Error.t()}
  defdelegate update_field(client, entity, id, field_name, value, opts \\ []), to: OData

  @doc """
  Same as `update_field/6`, raising `Creatio.Error` on failure.
  """
  @spec update_field!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          any(),
          opts()
        ) :: :ok
  defdelegate update_field!(client, entity, id, field_name, value, opts \\ []), to: OData

  @doc """
  Deletes a specific field value (`DELETE /0/odata/{Entity}({id})/{Field}`).
  """
  @spec delete_field(Client.t() | Req.Request.t(), String.t(), record_id(), String.t(), opts()) ::
          :ok | {:error, Error.t()}
  defdelegate delete_field(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Same as `delete_field/5`, raising `Creatio.Error` on failure.
  """
  @spec delete_field!(Client.t() | Req.Request.t(), String.t(), record_id(), String.t(), opts()) ::
          :ok
  defdelegate delete_field!(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Executes an OData batch request (`POST /0/odata/$batch`).
  """
  @spec batch(Client.t() | Req.Request.t(), Batch.payload()) ::
          {:ok, list() | any()} | {:error, Error.t()}
  @spec batch(Client.t() | Req.Request.t(), Batch.payload(), opts()) ::
          {:ok, list() | any()} | {:error, Error.t()}
  defdelegate batch(client, batch_or_requests, opts \\ []), to: OData

  @doc """
  Same as `batch/3`, raising `Creatio.Error` on failure.
  """
  @spec batch!(Client.t() | Req.Request.t(), Batch.payload()) ::
          list() | any()
  @spec batch!(Client.t() | Req.Request.t(), Batch.payload(), opts()) ::
          list() | any()
  defdelegate batch!(client, batch_or_requests, opts \\ []), to: OData

  @doc """
  Returns a lazy `Stream` yielding `{:ok, record}` tuples through an entity or query.

  If a page fetch or response payload fails mid-stream, yields `{:error, %Creatio.Error{}}`
  and halts cleanly. Use `stream!/3` for an exception-raising stream of plain record maps.

  Supports both offset (`$top`/`$skip`) and keyset/cursor pagination (`cursor_field: "Id"`).

  ## Options

    * `:page_size` - Number of records per request (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:cursor_field` - Field name (e.g. `"Id"`) to use `$orderby={field} asc` +
      `$filter={field} gt {cursor}` keyset pagination instead of `$skip`.
    * `:after_cursor` - Initial cursor value to resume keyset pagination from.
    * `:max_records` - Maximum total number of records to stream.
    * `:top` - Maximum total number of records to stream (in options or via `Query.top/2`).
    * `:select` - List of fields or comma-separated string to retrieve.
    * `:filter` - OData filter expression string.
    * `:orderby` - Ordering expression string.
    * `:expand` - Relations to expand.
  """
  @spec stream(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  defdelegate stream(client_or_query, entity_or_client, opts \\ []), to: OData

  @doc """
  Returns a lazy `Stream` yielding plain `record` maps through an entity or query.

  Raises `Creatio.Error` if a page fetch fails mid-stream. Accepts the same options as `stream/3`.
  """
  @spec stream!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  defdelegate stream!(client_or_query, entity_or_client, opts \\ []), to: OData

  # ---------------------------------------------------------------------------
  # DataService & Custom WebServices Delegates
  # ---------------------------------------------------------------------------

  @doc """
  Executes a SelectQuery against `/0/DataService/json/SyncReply/SelectQuery`.
  """
  @spec select_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate select_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `select_query/3`, raising `Creatio.Error` on failure.
  """
  @spec select_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  defdelegate select_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes an InsertQuery against `/0/DataService/json/SyncReply/InsertQuery`.
  """
  @spec insert_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate insert_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `insert_query/3`, raising `Creatio.Error` on failure.
  """
  @spec insert_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  defdelegate insert_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes an UpdateQuery against `/0/DataService/json/SyncReply/UpdateQuery`.
  """
  @spec update_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate update_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `update_query/3`, raising `Creatio.Error` on failure.
  """
  @spec update_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  defdelegate update_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a DeleteQuery against `/0/DataService/json/SyncReply/DeleteQuery`.
  """
  @spec delete_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate delete_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `delete_query/3`, raising `Creatio.Error` on failure.
  """
  @spec delete_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  defdelegate delete_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a BatchQuery against `/0/DataService/json/SyncReply/BatchQuery`.
  """
  @spec batch_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate batch_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `batch_query/3`, raising `Creatio.Error` on failure.
  """
  @spec batch_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  defdelegate batch_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a generic DataService query against `/0/DataService/json/SyncReply/{action}`.
  """
  @spec data_service_query(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate data_service_query(client, action, query_payload, opts \\ []),
    to: DataService,
    as: :execute_query

  @doc """
  Same as `data_service_query/4`, raising `Creatio.Error` on failure.
  """
  @spec data_service_query!(Client.t() | Req.Request.t(), String.t(), map(), keyword()) :: map()
  defdelegate data_service_query!(client, action, query_payload, opts \\ []),
    to: DataService,
    as: :execute_query!

  @doc """
  Calls a custom Creatio REST web service (`/0/rest/{service_name}/{endpoint}`).
  """
  @spec custom_service(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) :: {:ok, any()} | {:error, Error.t()}
  defdelegate custom_service(client, service_name, endpoint, payload \\ %{}, opts \\ []),
    to: DataService

  @doc """
  Same as `custom_service/5`, raising `Creatio.Error` on failure.
  """
  @spec custom_service!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) :: any()
  defdelegate custom_service!(client, service_name, endpoint, payload \\ %{}, opts \\ []),
    to: DataService

  # ---------------------------------------------------------------------------
  # Legacy OData 3 Delegates
  # ---------------------------------------------------------------------------

  @doc """
  Queries an entity collection via legacy OData 3 (`/0/ServiceModel/EntityDataService.svc/`).

  Supports both client-first and pipe/query-first argument order.
  """
  @spec odata3_list(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: {:ok, list() | map()} | {:error, Error.t()}
  defdelegate odata3_list(client_or_query, entity_or_client, opts \\ []), to: OData3, as: :list

  @doc """
  Same as `odata3_list/3`, raising `Creatio.Error` on failure.

  Supports both client-first and pipe/query-first argument order.
  """
  @spec odata3_list!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: list() | map()
  defdelegate odata3_list!(client_or_query, entity_or_client, opts \\ []), to: OData3, as: :list!

  @doc """
  Retrieves an entity by ID via legacy OData 3.
  """
  @spec odata3_get(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate odata3_get(client, entity, id, opts \\ []), to: OData3, as: :get

  @doc """
  Same as `odata3_get/4`, raising `Creatio.Error` on failure.
  """
  @spec odata3_get!(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) :: map()
  defdelegate odata3_get!(client, entity, id, opts \\ []), to: OData3, as: :get!

  @doc """
  Retrieves related records via a navigation property in OData 3.
  """
  @spec odata3_get_navigation(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: {:ok, any()} | {:error, Error.t()}
  defdelegate odata3_get_navigation(client, entity, id, nav_property, opts \\ []),
    to: OData3,
    as: :get_navigation

  @doc """
  Same as `odata3_get_navigation/5`, raising `Creatio.Error` on failure.
  """
  @spec odata3_get_navigation!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: any()
  defdelegate odata3_get_navigation!(client, entity, id, nav_property, opts \\ []),
    to: OData3,
    as: :get_navigation!

  @doc """
  Retrieves a field value of an entity in OData 3.
  """
  @spec odata3_get_field(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: {:ok, any()} | {:error, Error.t()}
  defdelegate odata3_get_field(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field

  @doc """
  Same as `odata3_get_field/5`, raising `Creatio.Error` on failure.
  """
  @spec odata3_get_field!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: any()
  defdelegate odata3_get_field!(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field!

  @doc """
  Retrieves raw scalar/stream value in OData 3.

  Supports `:into` (`into: File.stream!("/path/to/file")`), `:headers`, `:req_options`
  (preserving `decode_body: false`), and OData query options (`:select`, `:params`, etc.).
  """
  @spec odata3_get_field_value(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: {:ok, any()} | {:error, Error.t()}
  defdelegate odata3_get_field_value(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field_value

  @doc """
  Same as `odata3_get_field_value/5`, raising `Creatio.Error` on failure.
  """
  @spec odata3_get_field_value!(
          Client.t() | Req.Request.t(),
          String.t(),
          record_id(),
          String.t(),
          opts()
        ) :: any()
  defdelegate odata3_get_field_value!(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field_value!

  @doc """
  Gets total count of an entity collection in OData 3.
  """
  @spec odata3_count(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          opts()
        ) :: {:ok, integer()} | {:error, Error.t()}
  defdelegate odata3_count(client_or_query, entity_or_client, opts \\ []),
    to: OData3,
    as: :count

  @doc """
  Same as `odata3_count/3`, raising `Creatio.Error` on failure.
  """
  @spec odata3_count!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          opts()
        ) :: integer()
  defdelegate odata3_count!(client_or_query, entity_or_client, opts \\ []),
    to: OData3,
    as: :count!

  @doc """
  Creates an entity via legacy OData 3.
  """
  @spec odata3_create(Client.t() | Req.Request.t(), String.t(), map(), opts()) ::
          {:ok, map()} | {:error, Error.t()}
  defdelegate odata3_create(client, entity, attrs, opts \\ []), to: OData3, as: :create

  @doc """
  Same as `odata3_create/4`, raising `Creatio.Error` on failure.
  """
  @spec odata3_create!(Client.t() | Req.Request.t(), String.t(), map(), opts()) :: map()
  defdelegate odata3_create!(client, entity, attrs, opts \\ []), to: OData3, as: :create!

  @doc """
  Updates an entity via legacy OData 3.
  """
  @spec odata3_update(Client.t() | Req.Request.t(), String.t(), record_id(), map(), opts()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  defdelegate odata3_update(client, entity, id, attrs, opts \\ []), to: OData3, as: :update

  @doc """
  Same as `odata3_update/5`, raising `Creatio.Error` on failure.
  """
  @spec odata3_update!(Client.t() | Req.Request.t(), String.t(), record_id(), map(), opts()) ::
          :ok | map()
  defdelegate odata3_update!(client, entity, id, attrs, opts \\ []), to: OData3, as: :update!

  @doc """
  Deletes an entity via legacy OData 3.
  """
  @spec odata3_delete(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) ::
          :ok | {:error, Error.t()}
  defdelegate odata3_delete(client, entity, id, opts \\ []), to: OData3, as: :delete

  @doc """
  Same as `odata3_delete/4`, raising `Creatio.Error` on failure.
  """
  @spec odata3_delete!(Client.t() | Req.Request.t(), String.t(), record_id(), opts()) :: :ok
  defdelegate odata3_delete!(client, entity, id, opts \\ []), to: OData3, as: :delete!

  @doc """
  Returns a lazy `Stream` yielding `{:ok, record}` tuples through a legacy OData 3 entity collection.

  If a page fetch or response payload fails mid-stream, yields `{:error, %Creatio.Error{}}`
  and halts cleanly. Use `odata3_stream!/3` for an exception-raising stream of plain record maps.

  Supports both client-first and pipe/query-first argument order, as well as offset
  (`$top`/`$skip`) and keyset/cursor pagination (`cursor_field: "Id"`).

  ## Options

    * `:page_size` - Records per request (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:cursor_field` - Field name (e.g. `"Id"`) to switch from `$skip` offset pagination to
      `$orderby={field} asc` + `$filter={field} gt guid'...'` keyset pagination.
    * `:after_cursor` - Initial cursor value to resume keyset pagination from.
    * `:max_records` - Maximum total number of records to stream.
    * `:top` - Maximum total number of records to stream (in options or via `Query.top/2`).
    * `:select` - List or string of fields to retrieve.
    * `:filter` - Filter expression.
    * `:orderby` - Ordering expression.
    * `:expand` - Relations to expand.
  """
  @spec odata3_stream(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  defdelegate odata3_stream(client_or_query, entity_or_client, opts \\ []),
    to: OData3,
    as: :stream

  @doc """
  Returns a lazy `Stream` yielding plain `record` maps through a legacy OData 3 entity collection.

  Raises `Creatio.Error` if a page fetch fails mid-stream. Supports both client-first and
  pipe/query-first argument order and accepts the same options as `odata3_stream/3`.
  """
  @spec odata3_stream!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  defdelegate odata3_stream!(client_or_query, entity_or_client, opts \\ []),
    to: OData3,
    as: :stream!
end
