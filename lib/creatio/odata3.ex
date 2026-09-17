defmodule Creatio.OData3 do
  @moduledoc """
  Legacy OData 3 protocol client for Creatio (`/0/ServiceModel/EntityDataService.svc/`).

  Provided for backward compatibility with legacy Creatio environments.
  Supports collection listing, CRUD, navigation traversal, field values, and counts.
  """

  alias Creatio.{Client, Error}

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
    * `:count` - When `true`, requests inline count via `$inlinecount=allpages`.
  """
  @spec list(
          Client.t() | Req.Request.t(),
          String.t() | Creatio.OData.Query.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity_or_query, opts \\ [])

  def list(%Creatio.OData.Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def list(client_or_req, %Creatio.OData.Query{} = query, opts) do
    client = Client.ensure_client(client_or_req)
    query_params = Creatio.OData.Query.to_params(query)

    query_params =
      if Map.get(query_params, "$count") == "true" do
        query_params
        |> Map.delete("$count")
        |> Map.put("$inlinecount", "allpages")
      else
        query_params
      end

    opts_params = normalize_params(opts)
    params = Map.merge(query_params, opts_params)
    do_list(client, query.entity, params, opts)
  end

  def list(client_or_req, entity, opts) when is_binary(entity) do
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params, opts)
  end

  defp do_list(%Client{} = client, entity, params, opts) do
    collection_name = collection_name(entity)
    url = "#{@base_path}/#{collection_name}"

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"d" => %{"results" => records} = d_map}}} ->
        if params["$inlinecount"] == "allpages" or Keyword.get(opts, :count, false) do
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `list/3`, but raises `Creatio.Error` on failure.
  """
  def list!(client_or_req, entity_or_query, opts \\ [])

  def list!(%Creatio.OData.Query{} = query, client_or_req, opts) do
    list!(client_or_req, query, opts)
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
    clean_id = clean_guid(id)
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `get/4`, but raises `Creatio.Error` on failure.
  """
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
    clean_id = clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{nav_property}"
    params = normalize_params(opts)

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"d" => %{"results" => records}}}} ->
        {:ok, records}

      {:ok, %{status: 200, body: %{"d" => record}}} ->
        {:ok, record}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `get_navigation/5`, but raises `Creatio.Error` on failure.
  """
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
    clean_id = clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}"
    params = normalize_params(opts)

    req =
      client.req
      |> Req.Request.put_header("accept", "application/json; odata=verbose")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url, params: params) do
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `get_field/5`, but raises `Creatio.Error` on failure.
  """
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
          {:ok, binary()} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    clean_id = clean_guid(id)
    url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}/$value"

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")

    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `get_field_value/4`, but raises `Creatio.Error` on failure.
  """
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

    url =
      if strategy == :query do
        "#{@base_path}/#{collection_name}?/$count"
      else
        "#{@base_path}/#{collection_name}/$count"
      end

    params = normalize_params(Keyword.drop(opts, [:strategy]))

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")

    req_opts = [url: url]
    req_opts = if map_size(params) > 0, do: Keyword.put(req_opts, :params, params), else: req_opts

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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `count/3`, but raises `Creatio.Error` on failure.
  """
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
          Client.t() | Req.Request.t(),
          String.t() | Creatio.OData.Query.t(),
          keyword()
        ) :: Enumerable.t()
  def stream(client_or_req, entity_or_query, opts \\ [])

  def stream(%Creatio.OData.Query{} = query, client_or_req, opts) do
    stream(client_or_req, query, opts)
  end

  def stream(client_or_req, entity_or_query, opts) do
    client = Client.ensure_client(client_or_req)
    raw_page_size = Keyword.get(opts, :page_size, 100)

    page_size =
      case raw_page_size do
        val when is_binary(val) -> String.to_integer(val)
        val when is_integer(val) -> val
      end

    page_size = max(1, page_size)
    base_opts = Keyword.drop(opts, [:page_size, :top, :skip, :count])

    initial_skip =
      case entity_or_query do
        %Creatio.OData.Query{skip: s} when is_integer(s) and s >= 0 -> s
        _ ->
          case Keyword.get(opts, :skip, 0) do
            val when is_binary(val) -> String.to_integer(val)
            val when is_integer(val) -> val
            _ -> 0
          end
      end

    cleaned_entity_or_query =
      case entity_or_query do
        %Creatio.OData.Query{} = q -> %{q | count: false, top: nil, skip: nil}
        other -> other
      end

    Stream.resource(
      fn -> {initial_skip, false} end,
      fn
        {_offset, true} ->
          {:halt, nil}

        {offset, false} ->
          page_opts =
            base_opts
            |> Keyword.put(:top, page_size)
            |> Keyword.put(:skip, offset)

          case list(client, cleaned_entity_or_query, page_opts) do
            {:ok, records} when is_list(records) ->
              len = length(records)

              cond do
                len == 0 ->
                  {:halt, nil}

                len < page_size ->
                  {records, {offset + len, true}}

                true ->
                  {records, {offset + len, false}}
              end

            {:ok, %{records: records}} when is_list(records) ->
              len = length(records)

              cond do
                len == 0 ->
                  {:halt, nil}

                len < page_size ->
                  {records, {offset + len, true}}

                true ->
                  {records, {offset + len, false}}
              end

            {:error, error} ->
              raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Same as `stream/3`.
  """
  def stream!(client_or_req, entity_or_query, opts \\ [])

  def stream!(%Creatio.OData.Query{} = query, client_or_req, opts) do
    stream!(client_or_req, query, opts)
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
      {:error, Creatio.Error.new(status: 403, code: "ReadOnlyMode", message: "Client is in read-only mode")}
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
          {:error, Error.new(message: Exception.message(exception), details: exception)}
      end
    end
  end

  @doc """
  Same as `create/4`, but raises `Creatio.Error` on failure.
  """
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
      {:error, Creatio.Error.new(status: 403, code: "ReadOnlyMode", message: "Client is in read-only mode")}
    else
      collection_name = collection_name(entity)
      clean_id = clean_guid(id)
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
          {:error, Error.new(message: Exception.message(exception), details: exception)}
      end
    end
  end

  @doc """
  Same as `update/5`, but raises `Creatio.Error` on failure.
  """
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
      {:error, Creatio.Error.new(status: 403, code: "ReadOnlyMode", message: "Client is in read-only mode")}
    else
      collection_name = collection_name(entity)
      clean_id = clean_guid(id)
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
          {:error, Error.new(message: Exception.message(exception), details: exception)}
      end
    end
  end

  @doc """
  Same as `delete/4`, but raises `Creatio.Error` on failure.
  """
  def delete!(client, entity, id, opts \\ []) do
    case delete(client, entity, id, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp clean_guid(id) do
    id
    |> to_string()
    |> String.trim()
    |> String.replace_prefix("guid'", "")
    |> String.replace_suffix("'", "")
    |> String.replace_prefix("{", "")
    |> String.replace_suffix("}", "")
    |> String.replace_prefix("'", "")
    |> String.replace_suffix("'", "")
    |> String.trim()
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

  defp normalize_params(opts) when is_list(opts) do
    Enum.reduce(opts, %{}, fn
      {:select, []}, acc ->
        acc

      {:select, val}, acc when is_list(val) ->
        Map.put(acc, "$select", Enum.map_join(val, ",", &to_string/1))

      {:select, val}, acc when is_binary(val) or is_atom(val) ->
        Map.put(acc, "$select", to_string(val))

      {:filter, val}, acc when is_binary(val) ->
        Map.put(acc, "$filter", val)

      {key, val}, acc when key in [:orderby, :order_by] ->
        orderby_str =
          cond do
            is_list(val) ->
              Enum.map_join(val, ",", fn
                {col, dir} -> "#{col} #{dir}"
                col -> to_string(col)
              end)

            is_binary(val) or is_atom(val) ->
              to_string(val)

            true ->
              nil
          end

        if orderby_str, do: Map.put(acc, "$orderby", orderby_str), else: acc

      {:top, val}, acc when not is_nil(val) ->
        Map.put(acc, "$top", to_string(val))

      {:skip, val}, acc when not is_nil(val) ->
        Map.put(acc, "$skip", to_string(val))

      {:expand, []}, acc ->
        acc

      {:expand, val}, acc when is_list(val) ->
        Map.put(acc, "$expand", Enum.map_join(val, ",", &to_string/1))

      {:expand, val}, acc when is_binary(val) or is_atom(val) ->
        Map.put(acc, "$expand", to_string(val))

      {:count, true}, acc ->
        Map.put(acc, "$inlinecount", "allpages")

      {:inlinecount, val}, acc when not is_nil(val) ->
        Map.put(acc, "$inlinecount", to_string(val))

      {:params, map}, acc when is_map(map) ->
        Map.merge(acc, map)

      {:params, list}, acc when is_list(list) ->
        Enum.reduce(list, acc, fn {k, v}, a -> Map.put(a, to_string(k), to_string(v)) end)

      {key, val}, acc when is_binary(key) and is_list(val) ->
        Map.put(acc, key, Enum.map_join(val, ",", &to_string/1))

      {key, val}, acc when is_binary(key) ->
        Map.put(acc, key, to_string(val))

      _, acc ->
        acc
    end)
  end

  defp normalize_params(map) when is_map(map) do
    map
    |> Map.to_list()
    |> normalize_params()
  end
end
