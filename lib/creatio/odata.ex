defmodule Creatio.OData do
  @moduledoc """
  Client implementation for Creatio OData 4 protocol endpoints (`/0/odata/`).

  Provides CRUD operations, field-level access, streams, pagination, and batching.
  """

  alias Creatio.{Batch, Client, Error, Telemetry, Util}
  alias Creatio.OData.Query

  defguardp is_client_or_req(term) when is_struct(term, Client) or is_struct(term, Req.Request)

  @default_content_type "application/json; odata.metadata=minimal; IEEE754Compatible=true"

  @doc """
  Queries an entity collection (`GET /0/odata/{Entity}`).

  Accepts either an opaque `Creatio.OData.Query.t()` or a keyword list / map of options.

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

  def list(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "list/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params)
  end

  def list(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "list/3")
    client = Client.ensure_client(client_or_req)
    params = Util.normalize_odata_params(opts, Query.to_params(query))
    do_list(client, entity, params)
  end

  def list(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list(client_or_req, entity_or_query, opts)
  end

  @doc false
  @spec list_page(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list_page(client_or_req, entity_or_query, opts \\ [])

  def list_page(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream/3")
    client = Client.ensure_client(client_or_req)
    params = normalize_params(opts)
    do_list(client, entity, params, true)
  end

  def list_page(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "stream/3")
    client = Client.ensure_client(client_or_req)
    params = Util.normalize_odata_params(opts, Query.to_params(query))
    do_list(client, entity, params, true)
  end

  def list_page(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    list_page(client_or_req, entity_or_query, opts)
  end

  defp do_list(%Client{} = client, entity, params, include_meta? \\ false) do
    Telemetry.span(
      :odata,
      %{protocol: :odata4, action: :list, entity: entity, base_url: client.base_url},
      fn ->
        url = "/0/odata/#{entity}"

        case Req.get(client.req, url: url, params: params) do
          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and not Util.html_or_xml_response?(resp) do
              case resp.body do
                %{"value" => records} = body when is_list(records) ->
                  if include_meta? or params["$count"] == "true" do
                    {:ok,
                     %{
                       records: records,
                       count: parse_odata_count(body["@odata.count"]),
                       raw: body
                     }}
                  else
                    {:ok, records}
                  end

                records when is_list(records) ->
                  {:ok, records}

                _ ->
                  {:error, Error.from_response(resp)}
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

  defp parse_odata_count(int) when is_integer(int) and int >= 0, do: int

  defp parse_odata_count(bin) when is_binary(bin) do
    cleaned = bin |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

    case Integer.parse(cleaned) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp parse_odata_count(_), do: nil

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
  Executes an OData query or entity listing. Alias for `list/3`.
  """
  @spec execute(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def execute(client_or_req, entity_or_query, opts \\ [])

  def execute(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    list(client_or_req, entity_or_query, opts)
  end

  def execute(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
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

  def execute!(client_or_req, entity_or_query, opts) when is_client_or_req(client_or_req) do
    list!(client_or_req, entity_or_query, opts)
  end

  def execute!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
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
    entity = require_entity_name!(entity, "get/4")
    clean = clean_id(id)
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{protocol: :odata4, action: :get, entity: entity, base_url: client.base_url},
      fn ->
        url = "/0/odata/#{entity}(#{clean})"
        params = normalize_params(opts)

        case Req.get(client.req, url: url, params: params) do
          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and not Util.html_or_xml_response?(resp) do
              case resp.body do
                %{"error" => _} -> {:error, Error.from_response(resp)}
                %{} = record -> {:ok, record}
                _ -> {:error, Error.from_response(resp)}
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
    entity = require_entity_name!(entity, "get_navigation/5")
    clean = clean_id(id)
    nav_property = Util.require_field_name!(nav_property, "get_navigation/5")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :get_navigation,
        entity: entity,
        navigation: nav_property,
        base_url: client.base_url
      },
      fn ->
        url = "/0/odata/#{entity}(#{clean})/#{nav_property}"
        params = normalize_params(opts)

        case Req.get(client.req, url: url, params: params) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and not Util.html_or_xml_response?(resp) do
              case resp.body do
                %{"error" => _} -> {:error, Error.from_response(resp)}
                %{"value" => records} when is_list(records) -> {:ok, records}
                %{} = map -> {:ok, map}
                list when is_list(list) -> {:ok, list}
                _ -> {:error, Error.from_response(resp)}
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
    entity = require_entity_name!(entity, "get_field/5")
    clean = clean_id(id)
    field_name = Util.require_field_name!(field_name, "get_field/5")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :get_field,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        url = "/0/odata/#{entity}(#{clean})/#{field_name}"

        case Req.get(client.req, url: url, params: normalize_params(opts)) do
          {:ok, %Req.Response{status: 204}} ->
            {:ok, nil}

          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and not Util.html_or_xml_response?(resp) do
              case resp.body do
                %{"error" => _} -> {:error, Error.from_response(resp)}
                %{"value" => val} -> {:ok, val}
                %{} = map -> {:ok, map}
                list when is_list(list) -> {:ok, list}
                _other -> {:error, Error.from_response(resp)}
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
  Retrieves the raw scalar or binary stream value of a field (`GET /0/odata/{Entity}({id})/{Field}/$value`).

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
    entity = require_entity_name!(entity, "get_field_value/5")
    clean = clean_id(id)
    field_name = Util.require_field_name!(field_name, "get_field_value/5")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :get_field_value,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        url = "/0/odata/#{entity}(#{clean})/#{field_name}/$value"
        Util.fetch_field_value(client.req, url, opts, {"$count", "true"})
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
  Gets the total count of an entity collection.

  Supports:
  - Option 1 (default): `GET /0/odata/{Entity}/$count`
  - Option 2: `GET /0/odata/{Entity}?$count=true&$top=0` (when `:strategy` is `:top_zero`)

  Accepts optional `:filter`.
  """
  @spec count(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
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

  def count(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    entity = Query.require_entity!(query, "count/3")
    client = Client.ensure_client(client_or_req)

    base_params =
      query
      |> Query.to_params()
      |> Map.drop(["$top", "$skip", "$select", "$orderby", "$expand", "$count", "$inlinecount"])

    do_count(client, entity, base_params, opts)
  end

  def count(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    count(client_or_req, entity_or_query, opts)
  end

  defp do_count(%Client{} = client, entity, base_params, opts) do
    strategy = Util.get_opt(opts, :strategy, :path)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :count,
        entity: entity,
        strategy: strategy,
        base_url: client.base_url
      },
      fn ->
        case strategy do
          :top_zero ->
            params =
              opts
              |> drop_opt(:strategy)
              |> put_opt(:count, true)
              |> put_opt(:top, 0)
              |> then(&Util.normalize_odata_params(&1, base_params, {"$count", "true"}))

            url = "/0/odata/#{entity}"

            case Req.get(client.req, url: url, params: params) do
              {:ok, %Req.Response{} = raw_resp} ->
                case Util.normalize_json_response(raw_resp) do
                  %{status: 200, body: %{"@odata.count" => count}} = resp ->
                    parse_integer_count(count, resp)

                  %{status: 200, body: %{"value" => _} = body} = resp ->
                    case body["@odata.count"] do
                      nil ->
                        {:error,
                         Error.new(
                           status: resp.status,
                           message: "No @odata.count found in response",
                           response: resp
                         )}

                      count ->
                        parse_integer_count(count, resp)
                    end

                  %Req.Response{} = resp ->
                    {:error, Error.from_response(resp)}
                end

              {:error, exception} ->
                Error.wrap_error(exception)
            end

          _ ->
            url = "/0/odata/#{entity}/$count"

            params =
              opts
              |> drop_opt(:strategy)
              |> then(&Util.normalize_odata_params(&1, base_params, {"$count", "true"}))

            case Req.get(client.req, url: url, params: params) do
              {:ok, %Req.Response{} = raw_resp} ->
                case Util.normalize_json_response(raw_resp) do
                  %{status: 200, body: body} when is_integer(body) and body >= 0 ->
                    {:ok, body}

                  %{status: 200, body: %{"@odata.count" => count}} = resp ->
                    parse_integer_count(count, resp)

                  %{status: 200, body: %{"value" => count}} = resp ->
                    parse_integer_count(count, resp)

                  %{status: 200, body: body} = resp when is_binary(body) ->
                    case parse_integer_count(body, resp) do
                      {:ok, _} = ok ->
                        ok

                      {:error, _} = err ->
                        if Util.html_or_xml_response?(resp) do
                          {:error, Error.from_response(resp)}
                        else
                          err
                        end
                    end

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

  defp parse_integer_count(count, resp), do: Util.parse_integer_count(count, resp)

  @doc """
  Same as `count/3`, but raises `Creatio.Error` on failure.
  """
  @spec count!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
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
  Creates a new entity record (`POST /0/odata/{Entity}`).

  ## Options

    * `:return` - `:minimal` or `:representation`. Pass `return: :minimal` to send
      `Prefer: return=minimal` and avoid echoing all columns back from Creatio.
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(client_or_req, entity, attrs, opts \\ []) do
    entity = require_entity_name!(entity, "create/4")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{protocol: :odata4, action: :create, entity: entity, base_url: client.base_url},
      fn ->
        if client.read_only do
          {:error,
           Creatio.Error.new(
             status: 403,
             code: "ReadOnlyMode",
             message: "Client is in read-only mode"
           )}
        else
          url = "/0/odata/#{entity}"
          {return_pref, query_opts} = pop_opt(opts, :return)

          req =
            client.req
            |> Req.Request.put_header("content-type", @default_content_type)
            |> maybe_put_return_prefer(return_pref)

          case Req.post(req, url: url, json: attrs, params: normalize_params(query_opts)) do
            {:ok, %Req.Response{status: 204, headers: headers}} ->
              {:ok, extract_created_entity(headers)}

            {:ok, %Req.Response{} = raw_resp} ->
              resp = Util.normalize_json_response(raw_resp)

              if resp.status in [200, 201] and not Util.html_or_xml_response?(resp) do
                case resp.body do
                  %{"error" => _} -> {:error, Error.from_response(resp)}
                  %{} = body -> {:ok, body}
                  _ -> {:error, Error.from_response(resp)}
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

  ## Options

    * `:return` - `:minimal` or `:representation` (`Prefer: return=minimal` / `return=representation`).
  """
  @spec update(Client.t() | Req.Request.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:ok, map() | binary()} | {:error, Error.t()}
  def update(client_or_req, entity, id, attrs, opts \\ []) do
    entity = require_entity_name!(entity, "update/5")
    clean = clean_id(id)
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{protocol: :odata4, action: :update, entity: entity, base_url: client.base_url},
      fn ->
        if client.read_only do
          {:error,
           Creatio.Error.new(
             status: 403,
             code: "ReadOnlyMode",
             message: "Client is in read-only mode"
           )}
        else
          url = "/0/odata/#{entity}(#{clean})"
          {return_pref, query_opts} = pop_opt(opts, :return)

          req =
            client.req
            |> Req.Request.put_header("content-type", @default_content_type)
            |> maybe_put_return_prefer(return_pref)

          case Req.patch(req, url: url, json: attrs, params: normalize_params(query_opts)) do
            {:ok, %Req.Response{status: 204}} ->
              :ok

            {:ok, %Req.Response{} = raw_resp} ->
              resp = Util.normalize_json_response(raw_resp)

              if resp.status == 200 and not Util.html_or_xml_response?(resp) do
                handle_ok_update_body(resp)
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
          :ok | map() | binary()
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
    entity = require_entity_name!(entity, "delete/4")
    clean = clean_id(id)
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{protocol: :odata4, action: :delete, entity: entity, base_url: client.base_url},
      fn ->
        if client.read_only do
          {:error,
           Creatio.Error.new(
             status: 403,
             code: "ReadOnlyMode",
             message: "Client is in read-only mode"
           )}
        else
          url = "/0/odata/#{entity}(#{clean})"

          case Req.delete(client.req, url: url, params: normalize_params(opts)) do
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
    entity = require_entity_name!(entity, "update_field/6")
    clean = clean_id(id)
    field_name = Util.require_field_name!(field_name, "update_field/6")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :update_field,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        if client.read_only do
          {:error,
           Creatio.Error.new(
             status: 403,
             code: "ReadOnlyMode",
             message: "Client is in read-only mode"
           )}
        else
          url = "/0/odata/#{entity}(#{clean})/#{field_name}"

          {body_payload, default_ct} = encode_field_payload(value, opts)

          content_type = Util.get_opt(opts, :content_type, default_ct)

          req =
            client.req
            |> Req.Request.put_header("accept", "application/json; text/plain; */*")
            |> Req.Request.put_header("content-type", content_type)

          case Req.put(req, url: url, body: body_payload) do
            {:ok, %{status: 204}} ->
              :ok

            {:ok, %Req.Response{status: status} = raw_resp} when status in [200, 201] ->
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

  defp encode_field_payload(value, _opts)
       when is_struct(value, File.Stream) or is_struct(value, IO.Stream) or
              is_struct(value, Stream) or is_function(value, 2) do
    {value, "application/octet-stream; IEEE754Compatible=true"}
  end

  defp encode_field_payload(value, _opts)
       when is_map(value) or (is_list(value) and not is_nil(value)) do
    {Jason.encode_to_iodata!(value), "application/json; IEEE754Compatible=true"}
  end

  defp encode_field_payload(value, _opts)
       when is_boolean(value) or is_number(value) or is_atom(value) do
    {Jason.encode_to_iodata!(%{"value" => value}), "application/json; IEEE754Compatible=true"}
  end

  defp encode_field_payload(value, opts) when is_binary(value) do
    explicit_ct = Keyword.get(opts, :content_type)

    cond do
      is_binary(explicit_ct) and not String.contains?(String.downcase(explicit_ct), "json") ->
        {value, explicit_ct}

      String.valid?(value) ->
        {Jason.encode_to_iodata!(%{"value" => value}), "application/json; IEEE754Compatible=true"}

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
    entity = require_entity_name!(entity, "delete_field/5")
    clean = clean_id(id)
    field_name = Util.require_field_name!(field_name, "delete_field/5")
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :odata,
      %{
        protocol: :odata4,
        action: :delete_field,
        entity: entity,
        field: field_name,
        base_url: client.base_url
      },
      fn ->
        if client.read_only do
          {:error,
           Creatio.Error.new(
             status: 403,
             code: "ReadOnlyMode",
             message: "Client is in read-only mode"
           )}
        else
          url = "/0/odata/#{entity}(#{clean})/#{field_name}"

          req =
            client.req
            |> Req.Request.put_header("accept", "application/json; text/plain; */*")
            |> Req.Request.put_header(
              "content-type",
              "application/octet-stream; IEEE754Compatible=true"
            )

          case Req.delete(req, url: url, params: normalize_params(opts)) do
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
  @spec batch(Client.t() | Req.Request.t(), Batch.t() | map() | [map()] | binary(), keyword()) ::
          {:ok, list() | any()} | {:error, Error.t()}
  def batch(client_or_req, batch_or_requests, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    Batch.execute(client, batch_or_requests, opts)
  end

  @doc """
  Same as `batch/3`, but raises `Creatio.Error` on failure.
  """
  @spec batch!(Client.t() | Req.Request.t(), Batch.t() | map() | [map()] | binary(), keyword()) ::
          list() | any()
  def batch!(client, batch_or_requests, opts \\ []) do
    case batch(client, batch_or_requests, opts) do
      {:ok, responses} -> responses
      {:error, error} -> raise error
    end
  end

  @doc """
  Returns a lazy `Stream` that paginates through records of the given entity or query,
  yielding `{:ok, record}` tuples and a terminal `{:error, %Creatio.Error{}}` tuple
  before halting if any page fetch fails.

  Supports both offset (`$top`/`$skip`) and keyset/cursor pagination (`cursor_field: "Id"`).

  ## Options

    * `:page_size` - Number of records per page (default: 100).
    * `:skip` - Initial offset to begin streaming from (default: 0).
    * `:cursor_field` - Field name (e.g. `"Id"`) to switch from `$skip` offset pagination to
      `$orderby={field} asc` + `$filter={field} gt {cursor}` keyset pagination.
    * `:after_cursor` - Initial cursor value to resume keyset pagination from.
    * `:max_records` - Maximum total number of records to stream.
    * `:top` - Maximum total number of records to stream when set via `Query.top/2`.
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

  def stream(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream/3")
    Util.paginate_stream(client_or_req, entity, opts, :odata4, &list_page/3)
  end

  def stream(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    _entity = Query.require_entity!(query, "stream/3")
    Util.paginate_stream(client_or_req, query, opts, :odata4, &list_page/3)
  end

  def stream(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    stream(client_or_req, entity_or_query, opts)
  end

  @doc """
  Returns a lazy `Stream` that paginates through records of the given entity or query,
  emitting plain record maps and raising `Creatio.Error` if any page fetch fails.

  Accepts the same options and argument orders as `stream/3`.
  """
  @spec stream!(
          Client.t() | Req.Request.t() | Query.t() | String.t(),
          String.t() | Query.t() | Client.t() | Req.Request.t(),
          keyword() | map()
        ) ::
          Enumerable.t()
  def stream!(client_or_req, entity_or_query, opts \\ [])

  def stream!(client_or_req, entity, opts)
      when is_client_or_req(client_or_req) and is_binary(entity) do
    entity = require_entity_name!(entity, "stream!/3")
    Util.paginate_stream!(client_or_req, entity, opts, :odata4, &list_page/3)
  end

  def stream!(client_or_req, query, opts) when is_client_or_req(client_or_req) do
    _entity = Query.require_entity!(query, "stream!/3")
    Util.paginate_stream!(client_or_req, query, opts, :odata4, &list_page/3)
  end

  def stream!(entity_or_query, client_or_req, opts) when is_client_or_req(client_or_req) do
    stream!(client_or_req, entity_or_query, opts)
  end

  defp handle_ok_update_body(resp) do
    case resp.body do
      %{"error" => _} ->
        {:error, Error.from_response(resp)}

      %{} = body ->
        {:ok, body}

      nil ->
        :ok

      bin when is_binary(bin) ->
        if(String.trim(bin) == "", do: :ok, else: {:error, Error.from_response(resp)})

      _other ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_ok_void_response(raw_resp), do: Util.ok_void_response(raw_resp)

  defp require_entity_name!(entity, fun_name), do: Util.require_entity_name!(entity, fun_name)

  defp pop_opt(opts, key) when is_list(opts), do: Keyword.pop(opts, key)
  defp pop_opt(opts, key) when is_map(opts), do: Map.pop(opts, key)

  defp drop_opt(opts, key) when is_list(opts),
    do: Keyword.drop(opts, [key, Atom.to_string(key)])

  defp drop_opt(opts, key) when is_map(opts),
    do: Map.drop(opts, [key, Atom.to_string(key)])

  defp put_opt(opts, key, val) when is_list(opts), do: Keyword.put(opts, key, val)

  defp put_opt(opts, key, val) when is_map(opts) do
    opts
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, val)
  end

  defp maybe_put_return_prefer(req, :minimal),
    do: Req.Request.put_header(req, "prefer", "return=minimal")

  defp maybe_put_return_prefer(req, :representation),
    do: Req.Request.put_header(req, "prefer", "return=representation")

  defp maybe_put_return_prefer(req, _), do: req

  defp normalize_params(opts) do
    Util.normalize_odata_params(opts, %{}, {"$count", "true"})
  end

  defp clean_id(id) do
    Util.clean_guid(id)
  end

  defp extract_created_entity(headers) do
    entity_id =
      Util.response_header(headers, "odata-entityid") ||
        Util.response_header(headers, "location")

    case entity_id do
      nil ->
        %{}

      uri ->
        case Regex.run(~r/\(([^()]+)\)\s*$/, uri) do
          [_, raw_id] ->
            cleaned = Util.strip_guid_syntax(raw_id)

            if cleaned != "" and not String.contains?(raw_id, ["=", ","]) do
              %{"@odata.id" => uri, "Id" => cleaned}
            else
              %{"@odata.id" => uri}
            end

          _ ->
            %{"@odata.id" => uri}
        end
    end
  end
end
