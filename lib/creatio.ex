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

      # Seamlessly iterates over pages of records using $top and $skip,
      # with optional initial :skip offset for resuming syncs
      Creatio.stream(client, "Contact", page_size: 100, skip: 500, select: ["Id", "Name"])
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

  alias Creatio.{Auth, Batch, Client, DataService, OData, OData3}
  alias Creatio.OData.Query

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
  defdelegate new(opts \\ []), to: Client

  @doc """
  Builds a `Creatio.Client` from an existing `Req.Request`.
  """
  defdelegate from_req(req, opts \\ []), to: Client

  @doc """
  Authenticates via Forms authentication using username and password.
  """
  defdelegate login(client_or_req, username, password, opts \\ []), to: Auth, as: :login_forms

  @doc """
  Authenticates via OAuth 2.0 client credentials against the Identity Service.
  """
  defdelegate login_oauth(client, opts \\ []), to: Auth

  @doc """
  Checks OAuth health endpoint (`/0/api/OAuthHealthCheck`).
  """
  defdelegate oauth_health_check(client, opts \\ []), to: Auth

  @doc """
  Retrieves OpenID configuration (`/.well-known/openid-configuration`).
  """
  defdelegate openid_configuration(url_or_client, opts \\ []), to: Auth

  @doc """
  Initializes a new `Creatio.OData.Query` builder.
  """
  def query(entity) when is_binary(entity), do: Query.new(entity)

  @doc """
  Initializes a new `Creatio.Batch` request.
  """
  def batch_new(opts \\ []), do: Batch.new(opts)

  @doc """
  Serializes a batch to a multipart/mixed MIME body string. Returns `{boundary, body}`.
  """
  defdelegate batch_to_multipart(batch, opts \\ []), to: Batch, as: :to_multipart

  @doc """
  Parses a multipart/mixed batch response body.
  """
  defdelegate batch_parse_multipart(body, boundary \\ nil),
    to: Batch,
    as: :parse_multipart_response

  @doc """
  Queries an entity collection (`GET /0/odata/{Entity}`).
  """
  def list(query_or_entity, client, opts \\ [])
  def list(%Creatio.OData.Query{} = query, client, opts), do: OData.list(client, query, opts)
  def list(client, entity_or_query, opts), do: OData.list(client, entity_or_query, opts)

  @doc """
  Same as `list/3`, raising `Creatio.Error` on failure.
  """
  def list!(query_or_entity, client, opts \\ [])
  def list!(%Creatio.OData.Query{} = query, client, opts), do: OData.list!(client, query, opts)
  def list!(client, entity_or_query, opts), do: OData.list!(client, entity_or_query, opts)

  @doc """
  Executes an OData query or entity listing. Alias for `list/3`.
  """
  def execute(query_or_entity, client, opts \\ [])

  def execute(%Creatio.OData.Query{} = query, client, opts),
    do: OData.execute(client, query, opts)

  def execute(client, entity_or_query, opts),
    do: OData.execute(client, entity_or_query, opts)

  @doc """
  Same as `execute/3`, raising `Creatio.Error` on failure.
  """
  def execute!(query_or_entity, client, opts \\ [])

  def execute!(%Creatio.OData.Query{} = query, client, opts),
    do: OData.execute!(client, query, opts)

  def execute!(client, entity_or_query, opts),
    do: OData.execute!(client, entity_or_query, opts)

  @doc """
  Retrieves a single entity by its primary ID (`GET /0/odata/{Entity}({id})`).
  """
  defdelegate get(client, entity, id, opts \\ []), to: OData

  @doc """
  Same as `get/4`, raising `Creatio.Error` on failure.
  """
  defdelegate get!(client, entity, id, opts \\ []), to: OData

  @doc """
  Retrieves related records via a navigation property (`GET /0/odata/{Entity}({id})/{Property}`).
  """
  defdelegate get_navigation(client, entity, id, nav_property, opts \\ []), to: OData

  @doc """
  Same as `get_navigation/5`, raising `Creatio.Error` on failure.
  """
  defdelegate get_navigation!(client, entity, id, nav_property, opts \\ []), to: OData

  @doc """
  Retrieves a specific field value by ID (`GET /0/odata/{Entity}({id})/{Field}`).
  """
  defdelegate get_field(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Same as `get_field/5`, raising `Creatio.Error` on failure.
  """
  defdelegate get_field!(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Retrieves raw scalar/stream value (`GET /0/odata/{Entity}({id})/{Field}/$value`).
  """
  defdelegate get_field_value(client, entity, id, field_name), to: OData

  @doc """
  Same as `get_field_value/4`, raising `Creatio.Error` on failure.
  """
  defdelegate get_field_value!(client, entity, id, field_name), to: OData

  @doc """
  Gets total count of an entity collection (`GET /0/odata/{Entity}/$count`).
  """
  defdelegate count(client, entity, opts \\ []), to: OData

  @doc """
  Same as `count/3`, raising `Creatio.Error` on failure.
  """
  defdelegate count!(client, entity, opts \\ []), to: OData

  @doc """
  Creates an entity record (`POST /0/odata/{Entity}`).
  """
  defdelegate create(client, entity, attrs, opts \\ []), to: OData

  @doc """
  Same as `create/4`, raising `Creatio.Error` on failure.
  """
  defdelegate create!(client, entity, attrs, opts \\ []), to: OData

  @doc """
  Updates an entity record (`PATCH /0/odata/{Entity}({id})`).
  """
  defdelegate update(client, entity, id, attrs, opts \\ []), to: OData

  @doc """
  Same as `update/5`, raising `Creatio.Error` on failure.
  """
  defdelegate update!(client, entity, id, attrs, opts \\ []), to: OData

  @doc """
  Deletes an entity record (`DELETE /0/odata/{Entity}({id})`).
  """
  defdelegate delete(client, entity, id, opts \\ []), to: OData

  @doc """
  Same as `delete/4`, raising `Creatio.Error` on failure.
  """
  defdelegate delete!(client, entity, id, opts \\ []), to: OData

  @doc """
  Updates a field or octet-stream binary (`PUT /0/odata/{Entity}({id})/{Field}`).
  """
  defdelegate update_field(client, entity, id, field_name, value, opts \\ []), to: OData

  @doc """
  Same as `update_field/6`, raising `Creatio.Error` on failure.
  """
  defdelegate update_field!(client, entity, id, field_name, value, opts \\ []), to: OData

  @doc """
  Deletes a specific field value (`DELETE /0/odata/{Entity}({id})/{Field}`).
  """
  defdelegate delete_field(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Same as `delete_field/5`, raising `Creatio.Error` on failure.
  """
  defdelegate delete_field!(client, entity, id, field_name, opts \\ []), to: OData

  @doc """
  Executes an OData batch request (`POST /0/odata/$batch`).
  """
  defdelegate batch(client, batch_or_requests, opts \\ []), to: OData

  @doc """
  Same as `batch/3`, raising `Creatio.Error` on failure.
  """
  defdelegate batch!(client, batch_or_requests, opts \\ []), to: OData

  @doc """
  Returns a lazy `Stream` that paginates through records of an entity or query.

  ## Options

    * `:page_size` - Number of records per request (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:select` - List of fields or comma-separated string to retrieve.
    * `:filter` - OData filter expression string.
    * `:orderby` - Ordering expression string.
    * `:expand` - Relations to expand.
  """
  def stream(query_or_entity, client, opts \\ [])
  def stream(%Creatio.OData.Query{} = query, client, opts), do: OData.stream(client, query, opts)
  def stream(client, entity, opts), do: OData.stream(client, entity, opts)

  # ---------------------------------------------------------------------------
  # DataService & Custom WebServices Delegates
  # ---------------------------------------------------------------------------

  @doc """
  Executes a SelectQuery against `/0/DataService/json/SyncReply/SelectQuery`.
  """
  defdelegate select_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `select_query/3`, raising `Creatio.Error` on failure.
  """
  defdelegate select_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes an InsertQuery against `/0/DataService/json/SyncReply/InsertQuery`.
  """
  defdelegate insert_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `insert_query/3`, raising `Creatio.Error` on failure.
  """
  defdelegate insert_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes an UpdateQuery against `/0/DataService/json/SyncReply/UpdateQuery`.
  """
  defdelegate update_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `update_query/3`, raising `Creatio.Error` on failure.
  """
  defdelegate update_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a DeleteQuery against `/0/DataService/json/SyncReply/DeleteQuery`.
  """
  defdelegate delete_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `delete_query/3`, raising `Creatio.Error` on failure.
  """
  defdelegate delete_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a BatchQuery against `/0/DataService/json/SyncReply/BatchQuery`.
  """
  defdelegate batch_query(client, query_payload, opts \\ []), to: DataService

  @doc """
  Same as `batch_query/3`, raising `Creatio.Error` on failure.
  """
  defdelegate batch_query!(client, query_payload, opts \\ []), to: DataService

  @doc """
  Executes a generic DataService query against `/0/DataService/json/SyncReply/{action}`.
  """
  defdelegate data_service_query(client, action, query_payload, opts \\ []),
    to: DataService,
    as: :execute_query

  @doc """
  Same as `data_service_query/4`, raising `Creatio.Error` on failure.
  """
  defdelegate data_service_query!(client, action, query_payload, opts \\ []),
    to: DataService,
    as: :execute_query!

  @doc """
  Calls a custom Creatio REST web service (`/0/rest/{service_name}/{endpoint}`).
  """
  defdelegate custom_service(client, service_name, endpoint, payload \\ %{}, opts \\ []),
    to: DataService

  @doc """
  Same as `custom_service/5`, raising `Creatio.Error` on failure.
  """
  defdelegate custom_service!(client, service_name, endpoint, payload \\ %{}, opts \\ []),
    to: DataService

  # ---------------------------------------------------------------------------
  # Legacy OData 3 Delegates
  # ---------------------------------------------------------------------------

  @doc """
  Queries an entity collection via legacy OData 3 (`/0/ServiceModel/EntityDataService.svc/`).
  """
  def odata3_list(query_or_entity, client, opts \\ [])

  def odata3_list(%Creatio.OData.Query{} = query, client, opts),
    do: OData3.list(client, query, opts)

  def odata3_list(client, entity_or_query, opts),
    do: OData3.list(client, entity_or_query, opts)

  @doc """
  Same as `odata3_list/3`, raising `Creatio.Error` on failure.
  """
  def odata3_list!(query_or_entity, client, opts \\ [])

  def odata3_list!(%Creatio.OData.Query{} = query, client, opts),
    do: OData3.list!(client, query, opts)

  def odata3_list!(client, entity_or_query, opts),
    do: OData3.list!(client, entity_or_query, opts)

  @doc """
  Retrieves an entity by ID via legacy OData 3.
  """
  defdelegate odata3_get(client, entity, id, opts \\ []), to: OData3, as: :get

  @doc """
  Same as `odata3_get/4`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_get!(client, entity, id, opts \\ []), to: OData3, as: :get!

  @doc """
  Retrieves related records via a navigation property in OData 3.
  """
  defdelegate odata3_get_navigation(client, entity, id, nav_property, opts \\ []),
    to: OData3,
    as: :get_navigation

  @doc """
  Same as `odata3_get_navigation/5`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_get_navigation!(client, entity, id, nav_property, opts \\ []),
    to: OData3,
    as: :get_navigation!

  @doc """
  Retrieves a field value of an entity in OData 3.
  """
  defdelegate odata3_get_field(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field

  @doc """
  Same as `odata3_get_field/5`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_get_field!(client, entity, id, field_name, opts \\ []),
    to: OData3,
    as: :get_field!

  @doc """
  Retrieves raw scalar/stream value in OData 3.
  """
  defdelegate odata3_get_field_value(client, entity, id, field_name),
    to: OData3,
    as: :get_field_value

  @doc """
  Same as `odata3_get_field_value/4`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_get_field_value!(client, entity, id, field_name),
    to: OData3,
    as: :get_field_value!

  @doc """
  Gets total count of an entity collection in OData 3.
  """
  defdelegate odata3_count(client, entity, opts \\ []), to: OData3, as: :count

  @doc """
  Same as `odata3_count/3`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_count!(client, entity, opts \\ []), to: OData3, as: :count!

  @doc """
  Creates an entity via legacy OData 3.
  """
  defdelegate odata3_create(client, entity, attrs, opts \\ []), to: OData3, as: :create

  @doc """
  Same as `odata3_create/4`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_create!(client, entity, attrs, opts \\ []), to: OData3, as: :create!

  @doc """
  Updates an entity via legacy OData 3.
  """
  defdelegate odata3_update(client, entity, id, attrs, opts \\ []), to: OData3, as: :update

  @doc """
  Same as `odata3_update/5`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_update!(client, entity, id, attrs, opts \\ []), to: OData3, as: :update!

  @doc """
  Deletes an entity via legacy OData 3.
  """
  defdelegate odata3_delete(client, entity, id, opts \\ []), to: OData3, as: :delete

  @doc """
  Same as `odata3_delete/4`, raising `Creatio.Error` on failure.
  """
  defdelegate odata3_delete!(client, entity, id, opts \\ []), to: OData3, as: :delete!

  @doc """
  Returns a lazy `Stream` that paginates through records of a legacy OData 3 entity collection.

  ## Options

    * `:page_size` - Records per request (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:select` - List or string of fields to retrieve.
    * `:filter` - Filter expression.
    * `:orderby` - Ordering expression.
    * `:expand` - Relations to expand.
  """
  def odata3_stream(query_or_entity, client, opts \\ [])

  def odata3_stream(%Creatio.OData.Query{} = query, client, opts),
    do: OData3.stream(client, query, opts)

  def odata3_stream(client, entity_or_query, opts),
    do: OData3.stream(client, entity_or_query, opts)

  @doc """
  Same as `odata3_stream/3`.
  """
  def odata3_stream!(query_or_entity, client, opts \\ [])

  def odata3_stream!(%Creatio.OData.Query{} = query, client, opts),
    do: OData3.stream!(client, query, opts)

  def odata3_stream!(client, entity_or_query, opts),
    do: OData3.stream!(client, entity_or_query, opts)
end
