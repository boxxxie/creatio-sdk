defmodule Creatio.OData3 do
  @moduledoc """
  Legacy OData 3 protocol client for Creatio (`/0/ServiceModel/EntityDataService.svc/`).

  Provided for backward compatibility with legacy Creatio environments.
  Supports collection listing, CRUD, navigation traversal, field values, and counts.
  """

  alias Creatio.{Client, Error, Util}

  @base_path "/0/ServiceModel/EntityDataService.svc"

  @doc """
  Queries an OData 3 entity collection (`GET .../{Entity}Collection`).

  ## Options

    * `:select` - List or string of fields to retrieve.
    * `:filter` - OData filter string.
    * `:orderby` - Ordering expression or keyword list.
    * `:top` - Maximum records to retrieve.
    * `:skip` - Number of records to skip.
    * `:expand` - Related entities to expand.
    * `:count` - When `true`, requests inline count via `$inlinecount=allpages`; when `false`, overrides `Query.count/2`.
  """
  @spec list(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity_or_query, opts \\ [])

  def list(%Creatio.OData.Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def list(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    list(client_or_req, entity, opts)
  end

  def list(client_or_req, %Creatio.OData.Query{} = query, opts) do
    client = Client.ensure_client(client_or_req)
    query_params = Creatio.OData.Query.to_params(query)

    base_params =
      if Map.get(query_params, "$count") == "true" do
        query_params
        |> Map.delete("$count")
        |> Map.put("$inlinecount", "allpages")
      else
        query_params
      end

    params = Util.normalize_odata_params(opts, base_params, {"$inlinecount", "allpages"})
    do_list(client, query.entity, params)
  end

  def list(client_or_req, entity, opts) when is_binary(entity) do
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params)
  end

  defp do_list(%Client{} = client, entity, params) do
    collection_name = collection_name(entity)
    url = "#{@base_path}/#{collection_name}"

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"d" => %{"results" => records} = d_map}}} ->
        if params["$inlinecount"] == "allpages" do
          count_val = parse_count_value(d_map["__count"] || d_map["count"])
          {:ok, %{records: records, count: count_val, raw: d_map}}
        else
          {:ok, records}
        end

      {:ok, %{status: 200, body: %{"d" => records}}} when is_list(records) ->
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
  Same as `list/3`, but raises `Creatio.Error` on failure.
  """
  @spec list!(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: list() | map()
  def list!(client_or_req, entity_or_query, opts \\ [])

  def list!(%Creatio.OData.Query{} = query, client_or_req, opts) do
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
  Gets a single entity by ID in OData 3 (`GET .../{Entity}Collection(guid'{id}')`).
  """
  @spec get(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(client_or_req, entity, id, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    clean_id = Util.clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')"
    params = normalize_params(opts)

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"d" => record}}} ->
        {:ok, record}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

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
  Retrieves related records via a navigation property in OData 3 (`GET .../{Entity}Collection(guid'{id}')/{nav_property}`).
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
    collection_name = collection_name(entity)
    clean_id = Util.clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{nav_property}"
    params = normalize_params(opts)

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"d" => %{"results" => records}}}} ->
        {:ok, records}

      {:ok, %{status: 200, body: %{"d" => record}}} ->
        {:ok, record}

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
  Retrieves a specific field value of an entity in OData 3 (`GET .../{Entity}Collection(guid'{id}')/{field_name}`).
  """
  @spec get_field(Client.t() | Req.Request.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, any()} | {:error, Error.t()}
  def get_field(client_or_req, entity, id, field_name, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    clean_id = Util.clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}"
    params = normalize_params(opts)

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: %{"d" => %{} = d_map}}} ->
        val = Map.get(d_map, field_name, d_map)
        {:ok, val}

      {:ok, %{status: 200, body: %{"d" => val}}} ->
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
  Retrieves raw scalar/stream value in OData 3 (`GET .../{Entity}Collection(guid'{id}')/{field_name}/$value`).
  """
  @spec get_field_value(Client.t() | Req.Request.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary() | nil} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    clean_id = Util.clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}/$value"

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url) do
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
  Gets total count of an entity collection in OData 3.

  Supports both path strategy (`GET .../{Entity}Collection/$count`, default)
  and query strategy (`GET .../{Entity}Collection?/$count`, Postman collection format).

  ## Options

    * `:strategy` - `:path` (default) or `:query`.
    * `:filter` - Optional filter string.
  """
  @spec count(Client.t() | Req.Request.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, Error.t()}
  def count(client_or_req, entity, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    strategy = Keyword.get(opts, :strategy, :path)
    params = normalize_params(Keyword.drop(opts, [:strategy]))

    req_opts =
      if strategy == :query do
        base = "#{@base_path}/#{collection_name}?/$count"

        url =
          if map_size(params) > 0 do
            "#{base}&#{URI.encode_query(params)}"
          else
            base
          end

        [url: url]
      else
        url = "#{@base_path}/#{collection_name}/$count"
        if map_size(params) > 0, do: [url: url, params: params], else: [url: url]
      end

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, req_opts) do
      {:ok, %{status: 200, body: body}} when is_integer(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: %{"d" => count}}} when is_integer(count) ->
        {:ok, count}

      {:ok, %{status: 200, body: %{"d" => %{"count" => count}}}} when is_integer(count) ->
        {:ok, count}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        cleaned = body |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

        case Integer.parse(cleaned) do
          {int, _} -> {:ok, int}
          :error -> {:error, Error.new(message: "Failed to parse count response: #{body}")}
        end

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
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
  Returns a lazy `Stream` that paginates through records of an OData 3 entity collection using `$top` and `$skip`.

  ## Options

    * `:page_size` - Records per request (default `100`).
    * `:skip` - Initial offset to begin streaming from (default: `0`).
    * `:select` - List or string of fields to retrieve.
    * `:filter` - Filter expression.
    * `:orderby` - Ordering expression.
    * `:expand` - Relations to expand.
  """
  @spec stream(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  def stream(client_or_req, entity_or_query, opts \\ [])

  def stream(%Creatio.OData.Query{} = query, client_or_req, opts) do
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

  @doc """
  Same as `stream/3`.
  """
  @spec stream!(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  def stream!(client_or_req, entity_or_query, opts \\ [])

  def stream!(%Creatio.OData.Query{} = query, client_or_req, opts) do
    stream!(client_or_req, query, opts)
  end

  def stream!(entity, client_or_req, opts)
      when is_binary(entity) and
             (is_struct(client_or_req, Client) or is_struct(client_or_req, Req.Request)) do
    stream!(client_or_req, entity, opts)
  end

  def stream!(client_or_req, entity_or_query, opts) do
    stream(client_or_req, entity_or_query, opts)
  end

  @doc """
  Creates an entity via OData 3 (`POST .../{Entity}Collection`).
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
      collection_name = collection_name(entity)
      url = "#{@base_path}/#{collection_name}"

      req =
        client.req
        |> Req.Request.put_header("content-type", "application/json; odata=verbose")
        |> Req.Request.put_header("accept", "application/json; odata=verbose")
        |> Req.Request.put_header("forceusesession", "true")

      case Req.post(req, url: url, json: attrs, params: normalize_params(opts)) do
        {:ok, %{status: 201, body: %{"d" => record}}} ->
          {:ok, record}

        {:ok, %{status: 201, body: body}} ->
          {:ok, body}

        {:ok, %{status: 200, body: %{"d" => record}}} ->
          {:ok, record}

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
  Updates an entity via OData 3 (`PATCH .../{Entity}Collection(guid'{id}')`).
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
      collection_name = collection_name(entity)
      clean_id = Util.clean_guid(id)
      url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')"

      req =
        client.req
        |> Req.Request.put_header("content-type", "application/json; odata=verbose")
        |> Req.Request.put_header("accept", "application/json; odata=verbose")
        |> Req.Request.put_header("forceusesession", "true")

      case Req.patch(req, url: url, json: attrs, params: normalize_params(opts)) do
        {:ok, %{status: 204}} ->
          :ok

        {:ok, %{status: 200, body: %{"d" => record}}} ->
          {:ok, record}

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
  Deletes an entity via OData 3 (`DELETE .../{Entity}Collection(guid'{id}')`).
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
      collection_name = collection_name(entity)
      clean_id = Util.clean_guid(id)
      url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')"

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

  defp parse_count_value(val) when is_integer(val), do: val

  defp parse_count_value(val) when is_binary(val) do
    cleaned = val |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

    case Integer.parse(cleaned) do
      {int, _} -> int
      _ -> val
    end
  end

  defp parse_count_value(other), do: other

  defp collection_name(name) do
    if String.ends_with?(name, "Collection"), do: name, else: "#{name}Collection"
  end

  defp normalize_params(opts) do
    Util.normalize_odata_params(opts, %{}, {"$inlinecount", "allpages"})
  end
end
