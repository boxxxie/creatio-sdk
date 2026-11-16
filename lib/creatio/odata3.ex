defmodule Creatio.OData3 do
  @moduledoc """
  Legacy OData 3 protocol client for Creatio (`/0/ServiceModel/EntityDataService.svc/`).

  Provided for backward compatibility with legacy Creatio environments.
  Supports collection listing, CRUD, navigation traversal, field values, and counts.

  Entity names are automatically suffixed with `"Collection"` (for example,
  `"Contact"` resolves to `"ContactCollection"`), unless the name already ends
  with `"Collection"`.
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
          Creatio.opts()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity_or_query, opts \\ [])

  def list(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "list/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params, opts)
  end

  def list(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "list/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_query_params(query, opts)
    do_list(client, entity, params, opts)
  end

  def list(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list(client_or_req, entity_or_query, opts)
  end

  @doc false
  @spec list_page(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          Creatio.opts()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list_page(client_or_req, entity_or_query, opts \\ [])

  def list_page(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params, opts, true)
  end

  def list_page(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "stream/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_query_params(query, opts)
    do_list(client, entity, params, opts, true)
  end

  def list_page(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list_page(client_or_req, entity_or_query, opts)
  end

  defp normalize_query_params(query, opts) do
    query_params = Query.to_params(query)

    base_params =
      if Map.get(query_params, "$count") == "true" do
        query_params
        |> Map.delete("$count")
        |> Map.put("$inlinecount", "allpages")
      else
        query_params
      end

    Util.normalize_odata_params(opts, base_params, {"$inlinecount", "allpages"})
  end

  defp do_list(%Client{} = client, entity, params, opts, include_meta? \\ false) do
    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :list, entity: entity, base_url: client.base_url},
      fn ->
        collection_name = collection_name(entity)
        url = "#{@base_path}/#{collection_name}"

        base_req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")
        {req, req_opts} = Util.prepare_req_call(base_req, opts, [url: url], params)

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{} = raw_resp} ->
            case Util.decode_api_response(raw_resp) do
              {:ok, %Req.Response{status: 200, body: %{"d" => %{"results" => records} = d_map}}}
              when is_list(records) ->
                if include_meta? or params["$inlinecount"] == "allpages" do
                  count_val = parse_count_value(d_map["__count"] || d_map["count"])
                  {:ok, %{records: records, count: count_val, raw: d_map}}
                else
                  {:ok, records}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => records} = body}}
              when is_list(records) ->
                if include_meta? or params["$inlinecount"] == "allpages" do
                  {:ok, %{records: records, count: nil, raw: body}}
                else
                  {:ok, records}
                end

              {:ok, %Req.Response{status: 200, body: records}} when is_list(records) ->
                if include_meta? or params["$inlinecount"] == "allpages" do
                  {:ok, %{records: records, count: nil, raw: records}}
                else
                  {:ok, records}
                end

              {_, resp} ->
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
  @spec get(Client.t() | Req.Request.t(), String.t(), Creatio.record_id(), Creatio.opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def get(client_or_req, entity, id, opts \\ []) do
    entity = require_entity_name!(entity, "get/4")
    key_literal = Util.format_record_key(id, :odata3)
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :get, entity: entity, base_url: client.base_url},
      fn ->
        collection_name = collection_name(entity)
        url = "#{@base_path}/#{collection_name}(#{key_literal})"
        params = normalize_params(opts)

        base_req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")
        {req, req_opts} = Util.prepare_req_call(base_req, opts, [url: url], params)

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{} = raw_resp} ->
            case Util.decode_api_response(raw_resp) do
              {:ok, %Req.Response{status: 200, body: %{"d" => %{} = record} = body} = resp} ->
                if Util.error_payload?(body) or Util.error_payload?(record) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, record}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => _non_map}} = resp} ->
                {:error, Error.from_response(resp)}

              {:ok, %Req.Response{status: 200, body: %{} = body} = resp} ->
                if Util.error_payload?(body) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, body}
                end

              {_, resp} ->
                {:error, Error.from_response(resp)}
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
  @spec get!(Client.t() | Req.Request.t(), String.t(), Creatio.record_id(), Creatio.opts()) ::
          map()
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
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def get_navigation(client_or_req, entity, id, nav_property, opts \\ []) do
    entity = require_entity_name!(entity, "get_navigation/5")
    key_literal = Util.format_record_key(id, :odata3)
    nav_property = Util.require_field_name!(nav_property, "get_navigation/5")
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
        url = "#{@base_path}/#{collection_name}(#{key_literal})/#{nav_property}"
        params = normalize_params(opts)

        base_req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")
        {req, req_opts} = Util.prepare_req_call(base_req, opts, [url: url], params)

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            case Util.decode_api_response(raw_resp) do
              {:ok, %Req.Response{status: 200, body: %{"d" => %{"results" => records}}} = resp}
              when is_list(records) ->
                if Util.error_payload?(resp.body) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, records}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => records}} = resp}
              when is_list(records) ->
                if Util.error_payload?(resp.body) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, records}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => %{} = record} = body} = resp} ->
                if Util.error_payload?(body) or Util.error_payload?(record) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, record}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => _non_collection}} = resp} ->
                {:error, Error.from_response(resp)}

              {:ok, %Req.Response{status: 200, body: %{} = body} = resp} ->
                if Util.error_payload?(body) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, body}
                end

              {:ok, %Req.Response{status: 200, body: list}} when is_list(list) ->
                {:ok, list}

              {_, resp} ->
                {:error, Error.from_response(resp)}
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
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
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
  @spec get_field(
          Client.t() | Req.Request.t(),
          String.t(),
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def get_field(client_or_req, entity, id, field_name, opts \\ []) do
    entity = require_entity_name!(entity, "get_field/5")
    key_literal = Util.format_record_key(id, :odata3)
    field_name = Util.require_field_name!(field_name, "get_field/5")
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
        url = "#{@base_path}/#{collection_name}(#{key_literal})/#{field_name}"
        params = normalize_params(opts)

        base_req = Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")
        {req, req_opts} = Util.prepare_req_call(base_req, opts, [url: url], params)

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            case Util.decode_api_response(raw_resp) do
              {:ok, %Req.Response{status: 200, body: %{"d" => %{} = d_map} = body} = resp} ->
                cond do
                  Util.error_payload?(body) or Util.error_payload?(d_map) ->
                    {:error, Error.from_response(resp)}

                  odata3_wrapped_field?(d_map, field_name) ->
                    {:ok, Map.fetch!(d_map, field_name)}

                  true ->
                    {:ok, d_map}
                end

              {:ok, %Req.Response{status: 200, body: %{"d" => val} = body} = resp} ->
                if Util.error_payload?(body) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, val}
                end

              {:ok, %Req.Response{status: 200, body: %{} = map} = resp} ->
                if Util.error_payload?(map) do
                  {:error, Error.from_response(resp)}
                else
                  {:ok, map}
                end

              {:ok, %Req.Response{status: 200, body: list}} when is_list(list) ->
                {:ok, list}

              {_, resp} ->
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
  @spec get_field!(
          Client.t() | Req.Request.t(),
          String.t(),
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
        ) ::
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
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def get_field_value(client_or_req, entity, id, field_name, opts \\ []) do
    entity = require_entity_name!(entity, "get_field_value/5")
    key_literal = Util.format_record_key(id, :odata3)
    field_name = Util.require_field_name!(field_name, "get_field_value/5")
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
        url = "#{@base_path}/#{collection_name}(#{key_literal})/#{field_name}/$value"
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
          Creatio.record_id(),
          String.t(),
          Creatio.opts()
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
  @spec count(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, integer()} | {:error, Error.t()}
  def count(client_or_req, entity_or_query, opts \\ [])

  def count(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "count/3")
    client = Client.ensure_client(client_or_req)
    do_count(client, entity, %{}, opts)
  end

  @count_disallowed_params [
    "$top",
    "$skip",
    "$select",
    "$orderby",
    "$expand",
    "$count",
    "$inlinecount"
  ]

  def count(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "count/3")
    client = Client.ensure_client(client_or_req)

    base_params =
      query
      |> Query.to_params()
      |> Map.drop(@count_disallowed_params)

    do_count(client, entity, base_params, opts)
  end

  def count(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    count(client_or_req, entity_or_query, opts)
  end

  defp do_count(%Client{} = client, entity, base_params, opts) do
    Telemetry.span(
      :odata3,
      %{protocol: :odata3, action: :count, entity: entity, base_url: client.base_url},
      fn ->
        collection_name = collection_name(entity)
        strategy = Util.get_opt(opts, :strategy, :path)

        params =
          opts
          |> drop_opt(:strategy)
          |> drop_opt(:req_options)
          |> Util.normalize_odata_params(base_params, {"$inlinecount", "allpages"})
          |> Map.drop(@count_disallowed_params)

        base_req =
          Req.Request.put_header(
            client.req,
            "accept",
            "text/plain, application/json; odata=verbose, */*"
          )

        {req, req_opts} =
          if strategy == :query do
            base = "#{@base_path}/#{collection_name}?/$count"

            {req_with_headers, prepared} =
              Util.prepare_req_call(base_req, opts, [url: base], params)

            {extra_params, rest_opts} = Keyword.pop(prepared, :params, %{})

            url =
              if Enum.empty?(extra_params) do
                base
              else
                "#{base}&#{URI.encode_query(extra_params)}"
              end

            {req_with_headers, Keyword.put(rest_opts, :url, url)}
          else
            url = "#{@base_path}/#{collection_name}/$count"
            Util.prepare_req_call(base_req, opts, [url: url], params)
          end

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{} = raw_resp} ->
            case Util.decode_api_response(raw_resp) do
              {:html_or_xml, %{status: 200, body: body} = resp} when is_binary(body) ->
                case Util.parse_integer_count(body, resp) do
                  {:ok, _} = ok -> ok
                  {:error, _} -> {:error, Error.from_response(resp)}
                end

              {:html_or_xml, resp} ->
                {:error, Error.from_response(resp)}

              {:ok, resp} ->
                extract_odata3_count(resp)
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    )
  end

  @doc """
  Same as `count/3`, but raises `Creatio.Error` on failure.
  """
  @spec count!(
          Client.t() | Req.Request.t() | Creatio.OData.Query.t() | String.t(),
          String.t() | Creatio.OData.Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) :: integer()
  def count!(client_or_req, entity_or_query, opts \\ [])

  def count!(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    case count(client_or_req, entity_or_query, opts) do
      {:ok, int} -> int
      {:error, error} -> raise error
    end
  end

  def count!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    count!(client_or_req, entity_or_query, opts)
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

  def stream(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream/3")
    Util.paginate_stream(client_or_req, entity, opts, :odata3, &list_page/3)
  end

  def stream(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    _entity = Query.require_entity!(query, "stream/3")
    Util.paginate_stream(client_or_req, query, opts, :odata3, &list_page/3)
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

  def stream!(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream!/3")
    Util.paginate_stream!(client_or_req, entity, opts, :odata3, &list_page/3)
  end

  def stream!(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    _entity = Query.require_entity!(query, "stream!/3")
    Util.paginate_stream!(client_or_req, query, opts, :odata3, &list_page/3)
  end

  def stream!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    stream!(client_or_req, entity_or_query, opts)
  end

  @doc """
  Creates an entity via OData 3 (`POST .../{Entity}Collection`).
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), Creatio.opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(client_or_req, entity, attrs, opts \\ []) do
    entity = require_entity_name!(entity, "create/4")
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

          base_req =
            client.req
            |> Req.Request.put_header("content-type", "application/json; odata=verbose")
            |> Req.Request.put_header("accept", "application/json; odata=verbose")

          {req, req_opts} =
            Util.prepare_req_call(
              base_req,
              opts,
              [url: url, json: attrs],
              normalize_params(opts),
              [:url, :method, :json, :body]
            )

          case Req.post(req, req_opts) do
            {:ok, %Req.Response{status: 204, headers: headers}} ->
              {:ok, Util.extract_created_entity(headers)}

            {:ok, %Req.Response{} = raw_resp} ->
              case Util.decode_api_response(raw_resp) do
                {:ok, %Req.Response{status: status, body: %{"d" => %{} = record} = body} = resp}
                when status in [200, 201] ->
                  if Util.error_payload?(body) or Util.error_payload?(record) do
                    {:error, Error.from_response(resp)}
                  else
                    {:ok, record}
                  end

                {:ok, %Req.Response{status: status, body: %{"d" => _non_map}} = resp}
                when status in [200, 201] ->
                  {:error, Error.from_response(resp)}

                {:ok, %Req.Response{status: status, body: %{} = body} = resp}
                when status in [200, 201] ->
                  if Util.error_payload?(body) do
                    {:error, Error.from_response(resp)}
                  else
                    {:ok, body}
                  end

                {:ok, %Req.Response{status: 201, body: body, headers: headers}}
                when is_nil(body) or is_binary(body) ->
                  if Util.blank_body?(body) do
                    {:ok, Util.extract_created_entity(headers)}
                  else
                    {:error, Error.from_response(raw_resp)}
                  end

                {_, resp} ->
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
  @spec create!(Client.t() | Req.Request.t(), String.t(), map(), Creatio.opts()) :: map()
  def create!(client, entity, attrs, opts \\ []) do
    case create(client, entity, attrs, opts) do
      {:ok, body} -> body
      {:error, error} -> raise error
    end
  end

  @doc """
  Updates an entity via OData 3 (`PATCH .../{Entity}Collection(guid'{id}')`).
  """
  @spec update(
          Client.t() | Req.Request.t(),
          String.t(),
          Creatio.record_id(),
          map(),
          Creatio.opts()
        ) ::
          :ok | {:ok, map()} | {:error, Error.t()}
  def update(client_or_req, entity, id, attrs, opts \\ []) do
    entity = require_entity_name!(entity, "update/5")
    key_literal = Util.format_record_key(id, :odata3)
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
          url = "#{@base_path}/#{collection_name}(#{key_literal})"

          base_req =
            client.req
            |> Req.Request.put_header("content-type", "application/json; odata=verbose")
            |> Req.Request.put_header("accept", "application/json; odata=verbose")

          {req, req_opts} =
            Util.prepare_req_call(
              base_req,
              opts,
              [url: url, json: attrs],
              normalize_params(opts),
              [:url, :method, :json, :body]
            )

          case Req.patch(req, req_opts) do
            {:ok, %Req.Response{status: 204}} ->
              :ok

            {:ok, %Req.Response{} = raw_resp} ->
              case Util.decode_api_response(raw_resp) do
                {:ok, %Req.Response{status: 200} = resp} ->
                  handle_ok_update_body(resp)

                {_, resp} ->
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
  @spec update!(
          Client.t() | Req.Request.t(),
          String.t(),
          Creatio.record_id(),
          map(),
          Creatio.opts()
        ) ::
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
  @spec delete(Client.t() | Req.Request.t(), String.t(), Creatio.record_id(), Creatio.opts()) ::
          :ok | {:error, Error.t()}
  def delete(client_or_req, entity, id, opts \\ []) do
    entity = require_entity_name!(entity, "delete/4")
    key_literal = Util.format_record_key(id, :odata3)
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
          url = "#{@base_path}/#{collection_name}(#{key_literal})"

          base_req =
            Req.Request.put_header(client.req, "accept", "application/json; odata=verbose")

          {req, req_opts} =
            Util.prepare_req_call(base_req, opts, [url: url], normalize_params(opts))

          case Req.delete(req, req_opts) do
            {:ok, %{status: 204}} ->
              :ok

            {:ok, %Req.Response{status: 200} = raw_resp} ->
              handle_ok_void_response(raw_resp)

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
  @spec delete!(Client.t() | Req.Request.t(), String.t(), Creatio.record_id(), Creatio.opts()) ::
          :ok
  def delete!(client, entity, id, opts \\ []) do
    case delete(client, entity, id, opts) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  defp extract_odata3_count(%{status: 200, body: count}) when is_integer(count) and count >= 0,
    do: {:ok, count}

  defp extract_odata3_count(%{status: 200, body: %{"d" => %{"__count" => count}}} = resp),
    do: Util.parse_integer_count(count, resp)

  defp extract_odata3_count(%{status: 200, body: %{"d" => %{"count" => count}}} = resp),
    do: Util.parse_integer_count(count, resp)

  defp extract_odata3_count(%{status: 200, body: %{"d" => count}} = resp)
       when is_integer(count) or is_binary(count),
       do: Util.parse_integer_count(count, resp)

  defp extract_odata3_count(%{status: 200, body: %{"__count" => count}} = resp),
    do: Util.parse_integer_count(count, resp)

  defp extract_odata3_count(%{status: 200, body: %{"count" => count}} = resp),
    do: Util.parse_integer_count(count, resp)

  defp extract_odata3_count(%{status: 200, body: body} = resp) when is_binary(body) do
    case Util.parse_integer_count(body, resp) do
      {:ok, _} = ok ->
        ok

      {:error, _} = err ->
        if Util.html_or_xml_response?(resp) do
          {:error, Error.from_response(resp)}
        else
          err
        end
    end
  end

  defp extract_odata3_count(%Req.Response{} = resp), do: {:error, Error.from_response(resp)}

  defp odata3_wrapped_field?(d_map, field_name) when is_map(d_map) do
    Map.has_key?(d_map, field_name) and
      Enum.reject(Map.keys(d_map), &(&1 == "__metadata")) == [field_name]
  end

  defp handle_ok_update_body(resp) do
    case resp.body do
      %{"d" => %{} = record} = body ->
        if Util.error_payload?(body) or Util.error_payload?(record) do
          {:error, Error.from_response(resp)}
        else
          {:ok, record}
        end

      %{"d" => _} ->
        {:error, Error.from_response(resp)}

      %{} = body ->
        if Util.error_payload?(body) do
          {:error, Error.from_response(resp)}
        else
          {:ok, body}
        end

      nil ->
        :ok

      bin when is_binary(bin) ->
        if(Util.blank_body?(bin), do: :ok, else: {:error, Error.from_response(resp)})

      _other ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_ok_void_response(raw_resp), do: Util.ok_void_response(raw_resp)

  defp parse_count_value(val) when is_integer(val) and val >= 0, do: val

  defp parse_count_value(val) when is_binary(val) do
    cleaned = val |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

    case Integer.parse(cleaned) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp parse_count_value(_other), do: nil

  defp drop_opt(opts, key), do: Util.drop_opt(opts, key)

  defp collection_name(name) do
    if String.ends_with?(name, "Collection"), do: name, else: "#{name}Collection"
  end

  defp normalize_params(opts) do
    Util.normalize_odata_params(opts, %{}, {"$inlinecount", "allpages"})
  end

  defp require_entity_name!(entity, fun_name), do: Util.require_entity_name!(entity, fun_name)
end
