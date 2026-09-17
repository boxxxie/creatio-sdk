defmodule Creatio.OData do
  @moduledoc """
  Client implementation for Creatio OData 4 protocol endpoints (`/0/odata/`).

  Provides CRUD operations, field-level access, streams, pagination, and batching.
  """

  alias Creatio.{Batch, Client, Error}
  alias Creatio.OData.Query

  @default_content_type "application/json; odata=verbose; IEEE754Compatible=true"

  @doc """
  Queries an entity collection (`GET /0/odata/{Entity}`).

  Accepts either a `%Creatio.OData.Query{}` or a keyword list of options.

  ## Options

    * `:select` - List or comma-separated string of fields to retrieve.
    * `:filter` - OData filter string.
    * `:orderby` - Ordering string or list.
    * `:top` - Limit integer.
    * `:skip` - Offset integer.
    * `:expand` - Related entities to expand.
    * `:count` - When `true`, requests `@odata.count` inline.
    * `:params` - Map of additional query params.
  """
  @spec list(Client.t() | Req.Request.t(), String.t() | Query.t(), keyword() | map()) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity_or_query, opts \\ [])

  def list(%Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def list(client_or_req, %Query{} = query, opts) do
    client = Client.ensure_client(client_or_req)

    params =
      query
      |> Query.to_params()
      |> Map.merge(normalize_params(opts))

    do_list(client, query.entity, params, opts)
  end

  def list(client_or_req, entity, opts) when is_binary(entity) do
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params, opts)
  end

  defp do_list(%Client{} = client, entity, params, opts) do
    url = "/0/odata/#{entity}"

    case Req.get(client.req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"value" => records} = body}} when is_list(records) ->
        if params["$count"] == "true" or Keyword.get(opts, :count, false) do
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `list/3`, but raises `Creatio.Error` on failure.
  """
  def list!(client_or_req, entity_or_query, opts \\ [])

  def list!(%Query{} = query, client_or_req, opts) do
    list!(client_or_req, query, opts)
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
  def execute(client_or_req, entity_or_query, opts \\ [])

  def execute(%Query{} = query, client_or_req, opts) do
    list(client_or_req, query, opts)
  end

  def execute(client_or_req, entity_or_query, opts) do
    list(client_or_req, entity_or_query, opts)
  end

  @doc """
  Same as `execute/3`, but raises `Creatio.Error` on failure.
  """
  def execute!(client_or_req, entity_or_query, opts \\ [])

  def execute!(%Query{} = query, client_or_req, opts) do
    list!(client_or_req, query, opts)
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
      {:ok, %{status: 200, body: %{"value" => records}}} ->
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
  Same as `get_navigation/5`, but raises `Creatio.Error` on failure.
  """
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
      {:ok, %{status: 200, body: %{"value" => val}}} ->
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
  Retrieves the raw scalar or stream value of a field (`GET /0/odata/{Entity}({id})/{Field}/$value`).
  """
  @spec get_field_value(Client.t() | Req.Request.t(), String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name) do
    client = Client.ensure_client(client_or_req)
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})/#{field_name}/$value"

    case Req.get(client.req, url: url) do
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
            {:error, Error.new(message: Exception.message(exception), details: exception)}
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
            {:error, Error.new(message: Exception.message(exception), details: exception)}
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
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
  Updates an existing entity record (`PATCH /0/odata/{Entity}({id})`).
  """
  @spec update(Client.t() | Req.Request.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  def update(client_or_req, entity, id, attrs, opts \\ []) do
    client = Client.ensure_client(client_or_req)
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
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
  Deletes an entity record (`DELETE /0/odata/{Entity}({id})`).
  """
  @spec delete(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def delete(client_or_req, entity, id, opts \\ []) do
    client = Client.ensure_client(client_or_req)
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
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
    clean = clean_id(id)
    url = "/0/odata/#{entity}(#{clean})/#{field_name}"

    {body_payload, default_ct} =
      cond do
        is_map(value) or (is_list(value) and not is_nil(value)) ->
          {Jason.encode!(value), "application/json; IEEE754Compatible=true"}

        is_boolean(value) or is_number(value) or is_atom(value) ->
          {Jason.encode!(%{"value" => value}), "application/json; IEEE754Compatible=true"}

        true ->
          {value, "application/octet-stream; IEEE754Compatible=true"}
      end

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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `update_field/6`, but raises `Creatio.Error` on failure.
  """
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
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `delete_field/5`, but raises `Creatio.Error` on failure.
  """
  def delete_field!(client, entity, id, field_name, opts \\ []) do
    case delete_field(client, entity, id, field_name, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an OData batch request.
  """
  def batch(client_or_req, batch_or_requests, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    Batch.execute(client, batch_or_requests, opts)
  end

  @doc """
  Same as `batch/3`, but raises `Creatio.Error` on failure.
  """
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
    * `:select` - Fields to select.
    * `:filter` - Filter expression.
    * `:orderby` - Ordering expression.
    * `:expand` - Expanded relations.
  """
  @spec stream(Client.t() | Req.Request.t(), String.t() | Query.t(), keyword()) :: Enumerable.t()
  def stream(client_or_req, entity_or_query, opts \\ [])

  def stream(%Query{} = query, client_or_req, opts) do
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

    cleaned_entity_or_query =
      case entity_or_query do
        %Query{} = q -> %{q | count: false, top: nil, skip: nil}
        other -> other
      end

    Stream.resource(
      fn -> {0, false} end,
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
        Map.put(acc, "$count", "true")

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

  defp clean_id(id) do
    Creatio.Util.clean_guid(id)
  end
end
