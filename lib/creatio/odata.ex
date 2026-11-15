defmodule Creatio.OData do
  @moduledoc """
  Client implementation for Creatio OData 4 protocol endpoints (`/0/odata/`).

  Provides CRUD operations, field-level access, streams, pagination, and batching.
  """

  alias Creatio.{Batch, Client, Error, Util}
  alias Creatio.OData.Query

  @default_content_type "application/json; odata=verbose; IEEE754Compatible=true"

  @doc """
  Queries an entity collection (`GET /0/odata/{Entity}`).

  Accepts either a `%Creatio.OData.Query{}` or a keyword list / map of options.

  ## Options

    * `:select` - List or comma-separated string of fields to retrieve.
    * `:filter` - OData filter string.
    * `:orderby` - Ordering string or list.
    * `:top` - Limit integer.
    * `:skip` - Offset integer.
    * `:expand` - Related entities to expand.
    * `:count` - When `true`, requests `@odata.count` inline; when `false`, overrides `Query.count/2`.
    * `:params` - Map or keyword list of additional query params.
  """
  @spec list(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity_or_query, opts \\ [])

  def list(%Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def list(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    list(client_or_req, entity, opts)
  end

  def list(client_or_req, %Query{} = query, opts) do
    client = Client.ensure_client(client_or_req)
    params = Util.normalize_odata_params(opts, Query.to_params(query))
    do_list(client, query.entity, params)
  end

  def list(client_or_req, entity, opts) when is_binary(entity) do
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params)
  end

  defp do_list(%Client{} = client, entity, params) do
    url = "/0/odata/#{entity}"

    case Req.get(client.req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"value" => records} = body}} when is_list(records) ->
        if params["$count"] == "true" do
          count_val =
            case body["@odata.count"] do
              int when is_integer(int) ->
                int

              bin when is_binary(bin) ->
                cleaned = bin |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

                case Integer.parse(cleaned) do
                  {int, _} -> int
                  _ -> bin
                end

              other ->
                other
            end

          {:ok, %{records: records, count: count_val, raw: body}}
        else
          {:ok, records}
        end

      {:ok, %{status: 200, body: records}} when is_list(records) ->
        {:ok, records}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Same as `list/3`, but raises `Creatio.Error` on failure.
  """
  @spec list!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          list() | map()
  def list!(client_or_req, entity_or_query, opts \\ [])

  def list!(%Query{} = query, client_or_req, opts) do
    list!(client_or_req, query, opts)
  end

  def list!(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    list!(client_or_req, entity, opts)
  end

  def list!(client_or_req, entity_or_query, opts) do
    case list(client_or_req, entity_or_query, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an OData query or entity listing. Alias for `list/3`.
  """
  @spec execute(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def execute(client_or_req, entity_or_query, opts \\ [])

  def execute(%Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def execute(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    list(client_or_req, entity, opts)
  end

  def execute(client_or_req, entity_or_query, opts) do
    list(client_or_req, entity_or_query, opts)
  end

  @doc """
  Same as `execute/3`, but raises `Creatio.Error` on failure.
  """
  @spec execute!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          list() | map()
  def execute!(client_or_req, entity_or_query, opts \\ [])

  def execute!(%Query{} = query, client_or_req, opts) do
    list!(client_or_req, query, opts)
  end

  def execute!(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    list!(client_or_req, entity, opts)
  end

  def execute!(client_or_req, entity_or_query, opts) do
    list!(client_or_req, entity_or_query, opts)
  end

  @doc """
  Retrieves a single entity by its primary ID (`GET /0/odata/{Entity}({id})`).

  ## Options

    * `:select` - Fields to select.
    * `:expand` - Relations to expand.
  """
  @spec get(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(client_or_req, entity, id, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})"
    params = normalize_params(opts)

    case Req.get(client.req, url: url, params: params) do
      {:ok, %{status: 200, body: record}} ->
        {:ok, record}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Same as `get/4`, but raises `Creatio.Error` on failure.
  """
  @spec get!(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) :: map()
  def get!(client, entity, id, opts \\ []) do
    case get(client, entity, id, opts) do
      {:ok, record} -> record
      {:error, error} -> raise error
    end
  end

  @doc """
  Retrieves related records via a navigation property (`GET /0/odata/{Entity}({id})/{Property}`).
  """
  @spec get_navigation(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def get_navigation(client_or_req, entity, id, nav_property, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})/#{nav_property}"
    params = normalize_params(opts)

    case Req.get(client.req, url: url, params: params) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"value" => records}}} ->
        {:ok, records}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Same as `get_navigation/5`, but raises `Creatio.Error` on failure.
  """
  @spec get_navigation!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword()
        ) :: any()
  def get_navigation!(client, entity, id, nav_property, opts \\ []) do
    case get_navigation(client, entity, id, nav_property, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Retrieves a specific field value by ID (`GET /0/odata/{Entity}({id})/{Field}`).
  """
  @spec get_field(Client.t() | Req.Request.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, any()} | {:error, Error.t()}
  def get_field(client_or_req, entity, id, field_name, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})/#{field_name}"

    case Req.get(client.req, url: url, params: normalize_params(opts)) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"value" => val}}} ->
        {:ok, val}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Same as `get_field/5`, but raises `Creatio.Error` on failure.
  """
  @spec get_field!(Client.t() | Req.Request.t(), String.t(), String.t(), String.t(), keyword()) ::
          any()
  def get_field!(client, entity, id, field_name, opts \\ []) do
    case get_field(client, entity, id, field_name, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Retrieves the raw scalar or stream value of a field (`GET /0/odata/{Entity}({id})/{Field}/$value`).
  """
  @spec get_field_value(Client.t() | Req.Request.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary() | nil} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name) do
    client = Client.ensure_client(client_or_req)
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})/#{field_name}/$value"

    case Req.get(client.req, url: url) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Same as `get_field_value/4`, but raises `Creatio.Error` on failure.
  """
  @spec get_field_value!(Client.t() | Req.Request.t(), String.t(), String.t(), String.t()) ::
          binary() | nil
  def get_field_value!(client, entity, id, field_name) do
    case get_field_value(client, entity, id, field_name) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Gets the total count of an entity collection.

  Supports:
  - Option 1 (default): `GET /0/odata/{Entity}/$count`
  - Option 2: `GET /0/odata/{Entity}?$count=true&$top=0` (when `:strategy` is `:top_zero`)

  Accepts optional `:filter`.
  """
  @spec count(Client.t() | Req.Request.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, Error.t()}
  def count(client_or_req, entity, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    strategy = Keyword.get(opts, :strategy, :path)

    case strategy do
      :top_zero ->
        params =
          opts
          |> Keyword.delete(:strategy)
          |> Keyword.put(:count, true)
          |> Keyword.put(:top, 0)
          |> normalize_params()

        url = "/0/odata/#{entity}"

        case Req.get(client.req, url: url, params: params) do
          {:ok, %{status: 200, body: %{"@odata.count" => count}}} ->
            parse_integer_count(count)

          {:ok, %{status: 200, body: %{"value" => _}} = resp} ->
            case resp.body["@odata.count"] do
              nil -> {:error, Error.new(message: "No @odata.count found in response")}
              count -> parse_integer_count(count)
            end

          {:ok, %Req.Response{} = resp} ->
            {:error, Error.from_response(resp)}

          {:error, exception} ->
            Error.wrap_error(exception)
        end

      _ ->
        url = "/0/odata/#{entity}/$count"
        params = normalize_params(Keyword.delete(opts, :strategy))

        case Req.get(client.req, url: url, params: params) do
          {:ok, %{status: 200, body: body}} when is_integer(body) ->
            {:ok, body}

          {:ok, %{status: 200, body: %{"@odata.count" => count}}} ->
            parse_integer_count(count)

          {:ok, %{status: 200, body: %{"value" => count}}} ->
            parse_integer_count(count)

          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            parse_integer_count(body)

          {:ok, %Req.Response{} = resp} ->
            {:error, Error.from_response(resp)}

          {:error, exception} ->
            Error.wrap_error(exception)
        end
    end
  end

  defp parse_integer_count(count) when is_integer(count), do: {:ok, count}

  defp parse_integer_count(count) when is_binary(count) do
    cleaned = count |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

    case Integer.parse(cleaned) do
      {int, _} -> {:ok, int}
      :error -> {:error, Error.new(message: "Failed to parse count response: #{count}")}
    end
  end

  defp parse_integer_count(other) do
    {:error, Error.new(message: "Failed to parse count response: #{inspect(other)}")}
  end

  @doc """
  Same as `count/3`, but raises `Creatio.Error` on failure.
  """
  @spec count!(Client.t() | Req.Request.t(), String.t(), keyword()) :: integer()
  def count!(client, entity, opts \\ []) do
    case count(client, entity, opts) do
      {:ok, int} -> int
      {:error, error} -> raise error
    end
  end

  @doc """
  Creates a new entity record (`POST /0/odata/{Entity}`).
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(client_or_req, entity, attrs, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Creatio.Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode"
       )}
    else
      url = "/0/odata/#{entity}"

      req =
        client.req
        |> Req.Request.put_header("content-type", @default_content_type)
        |> Req.Request.put_header("forceusesession", "true")

      case Req.post(req, url: url, json: attrs, params: normalize_params(opts)) do
        {:ok, %{status: 201, body: body}} ->
          {:ok, body}

        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end
  end

  @doc """
  Same as `create/4`, but raises `Creatio.Error` on failure.
  """
  @spec create!(Client.t() | Req.Request.t(), String.t(), map(), keyword()) :: map()
  def create!(client, entity, attrs, opts \\ []) do
    case create(client, entity, attrs, opts) do
      {:ok, body} -> body
      {:error, error} -> raise error
    end
  end

  @doc """
  Updates an existing entity record (`PATCH /0/odata/{Entity}({id})`).
  """
  @spec update(Client.t() | Req.Request.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  def update(client_or_req, entity, id, attrs, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Creatio.Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode"
       )}
    else
      clean = clean_id(id)
      url = "/0/odata/#{entity}(#{clean})"

      req =
        client.req
        |> Req.Request.put_header("content-type", @default_content_type)
        |> Req.Request.put_header("forceusesession", "true")

      case Req.patch(req, url: url, json: attrs, params: normalize_params(opts)) do
        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end
  end

  @doc """
  Same as `update/5`, but raises `Creatio.Error` on failure.
  """
  @spec update!(Client.t() | Req.Request.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | map()
  def update!(client, entity, id, attrs, opts \\ []) do
    case update(client, entity, id, attrs, opts) do
      :ok -> :ok
      {:ok, body} -> body
      {:error, error} -> raise error
    end
  end

  @doc """
  Deletes an entity record (`DELETE /0/odata/{Entity}({id})`).
  """
  @spec delete(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete(client_or_req, entity, id, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Creatio.Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode"
       )}
    else
      clean = clean_id(id)
      url = "/0/odata/#{entity}(#{clean})"

      req =
        client.req
        |> Req.Request.put_header("forceusesession", "true")

      case Req.delete(req, url: url, params: normalize_params(opts)) do
        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{status: 200}} ->
          :ok

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end
  end

  @doc """
  Same as `delete/4`, but raises `Creatio.Error` on failure.
  """
  @spec delete!(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) :: :ok
  def delete!(client, entity, id, opts \\ []) do
    case delete(client, entity, id, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Updates a specific field or binary stream (`PUT /0/odata/{Entity}({id})/{Field}`).
  """
  @spec update_field(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) ::
          :ok | {:error, Error.t()}
  def update_field(client_or_req, entity, id, field_name, value, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Creatio.Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode"
       )}
    else
      clean = clean_id(id)
      url = "/0/odata/#{entity}(#{clean})/#{field_name}"

      {body_payload, default_ct} = encode_field_payload(value, opts)

      content_type = Keyword.get(opts, :content_type, default_ct)

      req =
        client.req
        |> Req.Request.put_header("accept", "application/json; text/plain; */*")
        |> Req.Request.put_header("content-type", content_type)
        |> Req.Request.put_header("forceusesession", "true")

      case Req.put(req, url: url, body: body_payload) do
        {:ok, %{status: status}} when status in [200, 201, 204] ->
          :ok

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end
  end

  defp encode_field_payload(value, _opts)
       when is_map(value) or (is_list(value) and not is_nil(value)) do
    {Jason.encode!(value), "application/json; IEEE754Compatible=true"}
  end

  defp encode_field_payload(value, _opts)
       when is_boolean(value) or is_number(value) or is_atom(value) do
    {Jason.encode!(%{"value" => value}), "application/json; IEEE754Compatible=true"}
  end

  defp encode_field_payload(value, opts) when is_binary(value) do
    explicit_ct = Keyword.get(opts, :content_type)

    cond do
      is_binary(explicit_ct) and not String.contains?(String.downcase(explicit_ct), "json") ->
        {value, explicit_ct}

      String.valid?(value) ->
        {Jason.encode!(%{"value" => value}), "application/json; IEEE754Compatible=true"}

      true ->
        {value, "application/octet-stream; IEEE754Compatible=true"}
    end
  end

  defp encode_field_payload(value, _opts) do
    {value, "application/octet-stream; IEEE754Compatible=true"}
  end

  @doc """
  Same as `update_field/6`, but raises `Creatio.Error` on failure.
  """
  @spec update_field!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) :: :ok
  def update_field!(client, entity, id, field_name, value, opts \\ []) do
    case update_field(client, entity, id, field_name, value, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Deletes a specific field of an entity (`DELETE /0/odata/{Entity}({id})/{Field}`).
  """
  @spec delete_field(Client.t() | Req.Request.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete_field(client_or_req, entity, id, field_name, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Creatio.Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode"
       )}
    else
      clean = clean_id(id)
      url = "/0/odata/#{entity}(#{clean})/#{field_name}"

      req =
        client.req
        |> Req.Request.put_header("accept", "application/json; text/plain; */*")
        |> Req.Request.put_header(
          "content-type",
          "application/octet-stream; IEEE754Compatible=true"
        )
        |> Req.Request.put_header("forceusesession", "true")

      case Req.delete(req, url: url, params: normalize_params(opts)) do
        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{status: 200}} ->
          :ok

        {:ok, %Req.Response{} = resp} ->
          {:error, Error.from_response(resp)}

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end
  end

  @doc """
  Same as `delete_field/5`, but raises `Creatio.Error` on failure.
  """
  @spec delete_field!(Client.t() | Req.Request.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok
  def delete_field!(client, entity, id, field_name, opts \\ []) do
    case delete_field(client, entity, id, field_name, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an OData batch request.
  """
  @spec batch(Client.t() | Req.Request.t(), Batch.t() | [map()], keyword()) ::
          {:ok, list() | any()} | {:error, Error.t()}
  def batch(client_or_req, batch_or_requests, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    Batch.execute(client, batch_or_requests, opts)
  end

  @doc """
  Same as `batch/3`, but raises `Creatio.Error` on failure.
  """
  @spec batch!(Client.t() | Req.Request.t(), Batch.t() | [map()], keyword()) :: list() | any()
  def batch!(client, batch_or_requests, opts \\ []) do
    case batch(client, batch_or_requests, opts) do
      {:ok, responses} -> responses
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns a lazy `Stream` that paginates through records of the given entity or query.

  ## Options

    * `:page_size` - Number of records per page (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:top` - Maximum total number of records to stream when passed explicitly (or via `Query.top/2`).
    * `:select` - Fields to select.
    * `:filter` - Filter expression.
    * `:orderby` - Ordering expression.
    * `:expand` - Expanded relations.
  """
  @spec stream(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          Enumerable.t()
  def stream(client_or_req, entity_or_query, opts \\ [])

  def stream(%Query{} = query, client_or_req, opts) do
    stream(client_or_req, query, opts)
  end

  def stream(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    stream(client_or_req, entity, opts)
  end

  def stream(client_or_req, entity_or_query, opts) do
    client = Client.ensure_client(client_or_req)
    Util.paginate_stream(client, entity_or_query, opts, &list/3)
  end

  defp normalize_params(opts) do
    Util.normalize_odata_params(opts, %{}, {"$count", "true"})
  end

  defp clean_id(id) do
    Util.clean_guid(id)
  end
end
