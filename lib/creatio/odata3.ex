defmodule Creatio.OData3 do
  @moduledoc """
  Legacy OData 3 protocol client for Creatio (`/0/ServiceModel/EntityDataService.svc/`).

  Provided for backward compatibility with legacy Creatio environments.
  Supports collection listing, CRUD, navigation traversal, field values, and counts.
  """

  alias Creatio.{Client, Error, Telemetry, Util}
  alias Creatio.OData.Query

  @base_path "/0/ServiceModel/EntityDataService.svc"

  defguardp is_client_or_req(term)
            when is_struct(term, Client) or is_struct(term, Req.Request)

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

  def list(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params)
  end

  def list(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = require_query_entity!(query)
    client = Client.ensure_client(client_or_req)
    query_params = Query.to_params(query)

    base_params =
      if Map.get(query_params, "$count") == "true" do
        query_params
        |> Map.delete("$count")
        |> Map.put("$inlinecount", "allpages")
      else
        query_params
      end

    params = Util.normalize_odata_params(opts, base_params, {"$inlinecount", "allpages"})
    do_list(client, entity, params)
  end

  def list(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list(client_or_req, entity_or_query, opts)
  end

  defp do_list(%Client{} = client, entity, params) do
    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :list, entity: entity, base_url: client.base_url},
      fn ->
        collection_name = collection_name(entity)
        url = "#{@base_path}/#{collection_name}"

        req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")

        case Req.get(req, url: url, params: params) do
          {:ok, %Req.Response{} = raw_resp} ->
            case Util.normalize_json_response(raw_resp) do
              %{status: 200, body: %{"d" => %{"results" => records} = d_map}} ->
                if params["$inlinecount"] == "allpages" do
                  count_val = parse_count_value(d_map["__count"] || d_map["count"])
                  {:ok, %{records: records, count: count_val, raw: d_map}}
                else
                  {:ok, records}
                end

              %{status: 200, body: %{"d" => records}} when is_list(records) ->
                {:ok, records}

              %{status: 200, body: body} when is_map(body) or is_list(body) ->
                {:ok, body}

              %Req.Response{} = resp ->
                {:error, Error.from_response(resp)}
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    )
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

  def list!(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    case list(client_or_req, entity_or_query, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  def list!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list!(client_or_req, entity_or_query, opts)
  end

  @doc """
  Gets a single entity by ID in OData 3 (`GET .../{Entity}Collection(guid'{id}')`).
  """
  @spec get(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(client_or_req, entity, id, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :get, entity: entity, base_url: client.base_url},
      fn ->
        collection_name = collection_name(entity)
        clean_id = Util.clean_guid(id)
        url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')"
        params = normalize_params(opts)

        req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")

        case Req.get(req, url: url, params: params) do
          {:ok, %Req.Response{} = raw_resp} ->
            case Util.normalize_json_response(raw_resp) do
              %{status: 200, body: %{"d" => record}} -> {:ok, record}
              %{status: 200, body: %{} = body} -> {:ok, body}
              %Req.Response{} = resp -> {:error, Error.from_response(resp)}
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    )
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

    Telemetry.span(
      :odata3,
      %{
        protocol: :odata3,
        action: :get_navigation,
        entity: entity,
        navigation: nav_property,
        base_url: client.base_url
      },
      fn ->
        collection_name = collection_name(entity)
        clean_id = Util.clean_guid(id)
        url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{nav_property}"
        params = normalize_params(opts)

        req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")

        case Req.get(req, url: url, params: params) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            case Util.normalize_json_response(raw_resp) do
              %{status: 200, body: %{"d" => %{"results" => records}}} -> {:ok, records}
              %{status: 200, body: %{"d" => record}} -> {:ok, record}
              %{status: 200, body: body} when is_map(body) or is_list(body) -> {:ok, body}
              %Req.Response{} = resp -> {:error, Error.from_response(resp)}
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    )
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

    Telemetry.span(
      :odata3,
      %{
        protocol: :odata3,
        action: :get_field,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        collection_name = collection_name(entity)
        clean_id = Util.clean_guid(id)
        url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}"
        params = normalize_params(opts)

        req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")

        case Req.get(req, url: url, params: params) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and not Util.html_or_xml_response?(resp) do
              case resp.body do
                %{"d" => %{} = d_map} -> {:ok, Map.get(d_map, field_name, d_map)}
                %{"d" => val} -> {:ok, val}
                other -> {:ok, other}
              end
            else
              {:error, Error.from_response(resp)}
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    )
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

  ## Options

    * `:into` - Pass `into: File.stream!("/path/to/file")` to stream large attachments
      directly to disk without buffering in memory.
    * `:headers` - Extra request headers (map or keyword/tuple list), e.g. `[{"range", "bytes=0-1023"}]`.
    * `:req_options` - Extra `Req` options (such as `:receive_timeout` or `:params`).
      `decode_body: false` is always preserved even if `:req_options` specifies `decode_body: true`.
    * Any standard OData query options (`:select`, `:filter`, `:params`, etc.).
  """
  @spec get_field_value(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword() | map()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata3,
      %{
        protocol: :odata3,
        action: :get_field_value,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        collection_name = collection_name(entity)
        clean_id = Util.clean_guid(id)
        url = "#{@base_path}/#{collection_name}(guid'#{clean_id}')/#{field_name}/$value"
        Util.fetch_field_value(client.req, url, opts, {"$inlinecount", "allpages"})
      end
    )
  end

  @doc """
  Same as `get_field_value/5`, but raises `Creatio.Error` on failure.
  """
  @spec get_field_value!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          String.t(),
          keyword() | map()
        ) ::
          any()
  def get_field_value!(client, entity, id, field_name, opts \\ []) do
    case get_field_value(client, entity, id, field_name, opts) do
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

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :count, entity: entity, base_url: client.base_url},
      fn ->
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

        case Req.get(client.req, req_opts) do
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
    )
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
  Returns a lazy `Stream` yielding `{:ok, record}` tuples through an OData 3 entity collection.

  If a page fetch or response payload fails mid-stream, yields `{:error, %Creatio.Error{}}`
  and halts cleanly. Use `stream!/3` for an exception-raising stream of plain record maps.

  Supports both offset (`$top`/`$skip`) and keyset/cursor pagination (`cursor_field: "Id"`).

  ## Options

    * `:page_size` - Records per request (default `100`).
    * `:skip` - Initial offset to begin streaming from (default: `0`).
    * `:cursor_field` - Field name (e.g. `"Id"`) to switch from `$skip` offset pagination to
      `$orderby={field} asc` + `$filter={field} gt guid'...'` keyset pagination.
    * `:after_cursor` - Initial cursor value to resume keyset pagination from.
    * `:max_records` - Maximum total number of records to stream.
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

  def stream(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    Util.paginate_stream(client_or_req, entity_or_query, opts, :odata3, &list/3)
  end

  def stream(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    stream(client_or_req, entity_or_query, opts)
  end

  @doc """
  Returns a lazy `Stream` yielding plain `record` maps through an OData 3 entity collection.

  Raises `Creatio.Error` if a page fetch fails mid-stream. Accepts the same options as `stream/3`.
  """
  @spec stream!(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: Enumerable.t()
  def stream!(client_or_req, entity_or_query, opts \\ [])

  def stream!(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    Util.paginate_stream!(client_or_req, entity_or_query, opts, :odata3, &list/3)
  end

  def stream!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    stream!(client_or_req, entity_or_query, opts)
  end

  @doc """
  Creates an entity via OData 3 (`POST .../{Entity}Collection`).
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(client_or_req, entity, attrs, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :create, entity: entity, base_url: client.base_url},
      fn ->
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

          case Req.post(req, url: url, json: attrs, params: normalize_params(opts)) do
            {:ok, %Req.Response{} = raw_resp} ->
              case Util.normalize_json_response(raw_resp) do
                %{status: status, body: %{"d" => record}} when status in [200, 201] ->
                  {:ok, record}

                %{status: status, body: %{} = body} when status in [200, 201] ->
                  {:ok, body}

                %Req.Response{} = resp ->
                  {:error, Error.from_response(resp)}
              end

            {:error, exception} ->
              Error.wrap_error(exception)
          end
        end
      end
    )
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

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :update, entity: entity, base_url: client.base_url},
      fn ->
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

          case Req.patch(req, url: url, json: attrs, params: normalize_params(opts)) do
            {:ok, %Req.Response{status: 204}} ->
              :ok

            {:ok, %Req.Response{} = raw_resp} ->
              resp = Util.normalize_json_response(raw_resp)

              if resp.status == 200 and not Util.html_or_xml_response?(resp) do
                case resp.body do
                  %{"d" => record} -> {:ok, record}
                  body -> {:ok, body}
                end
              else
                {:error, Error.from_response(resp)}
              end

            {:error, exception} ->
              Error.wrap_error(exception)
          end
        end
      end
    )
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

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :delete, entity: entity, base_url: client.base_url},
      fn ->
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

          case Req.delete(client.req, url: url, params: normalize_params(opts)) do
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
    )
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

  defp require_query_entity!(query) do
    case Query.entity(query) do
      "" ->
        raise ArgumentError, "Creatio.OData.Query must specify a non-empty entity name"

      entity ->
        entity
    end
  end
end
