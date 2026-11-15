defmodule Creatio.DataService do
  @moduledoc """
  Client for Creatio's proprietary DataService JSON API and custom REST WebServices.

  Supports `SelectQuery`, `InsertQuery`, `UpdateQuery`, `DeleteQuery`, `BatchQuery`,
  and calling custom REST service endpoints.
  """

  alias Creatio.{Client, Error, Telemetry, Util}

  @doc """
  Executes a SelectQuery against `/0/DataService/json/SyncReply/SelectQuery`.

  ## Examples

      query = %{
        "RootSchemaName" => "Account",
        "columns" => %{
          "items" => %{
            "Name" => %{
              "expression" => %{"columnPath" => "Name"}
            }
          }
        }
      }

      {:ok, result} = Creatio.DataService.select_query(client, query)
  """
  @spec select_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def select_query(client_or_req, query_payload, opts \\ []) do
    execute_query(client_or_req, "SelectQuery", query_payload, opts)
  end

  @doc """
  Same as `select_query/3`, but raises `Creatio.Error` on failure.
  """
  @spec select_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  def select_query!(client, query_payload, opts \\ []) do
    case select_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an InsertQuery against `/0/DataService/json/SyncReply/InsertQuery`.

  Returns `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}` if the client is in read-only mode.
  """
  @spec insert_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def insert_query(client_or_req, query_payload, opts \\ []) do
    execute_mutation_query(client_or_req, "InsertQuery", query_payload, opts)
  end

  @doc """
  Same as `insert_query/3`, but raises `Creatio.Error` on failure.
  """
  @spec insert_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  def insert_query!(client, query_payload, opts \\ []) do
    case insert_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an UpdateQuery against `/0/DataService/json/SyncReply/UpdateQuery`.

  Returns `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}` if the client is in read-only mode.
  """
  @spec update_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_query(client_or_req, query_payload, opts \\ []) do
    execute_mutation_query(client_or_req, "UpdateQuery", query_payload, opts)
  end

  @doc """
  Same as `update_query/3`, but raises `Creatio.Error` on failure.
  """
  @spec update_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  def update_query!(client, query_payload, opts \\ []) do
    case update_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a DeleteQuery against `/0/DataService/json/SyncReply/DeleteQuery`.

  Returns `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}` if the client is in read-only mode.
  """
  @spec delete_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def delete_query(client_or_req, query_payload, opts \\ []) do
    execute_mutation_query(client_or_req, "DeleteQuery", query_payload, opts)
  end

  @doc """
  Same as `delete_query/3`, but raises `Creatio.Error` on failure.
  """
  @spec delete_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  def delete_query!(client, query_payload, opts \\ []) do
    case delete_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a BatchQuery against `/0/DataService/json/SyncReply/BatchQuery`.

  Returns `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}` if the client is in read-only mode.
  """
  @spec batch_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def batch_query(client_or_req, query_payload, opts \\ []) do
    execute_mutation_query(client_or_req, "BatchQuery", query_payload, opts)
  end

  @doc """
  Same as `batch_query/3`, but raises `Creatio.Error` on failure.
  """
  @spec batch_query!(Client.t() | Req.Request.t(), map(), keyword()) :: map()
  def batch_query!(client, query_payload, opts \\ []) do
    case batch_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a generic DataService query against `/0/DataService/json/SyncReply/{action}`.

  Non-`SelectQuery` actions are blocked with `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}`
  when `client.read_only` is `true`.
  """
  @spec execute_query(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_query(client_or_req, action, query_payload, opts \\ []) do
    client = Client.ensure_client(client_or_req)

    Telemetry.span(
      :data_service,
      %{
        action: action,
        entity: extract_root_schema(query_payload),
        base_url: client.base_url
      },
      fn ->
        if client.read_only and action != "SelectQuery" do
          {:error, read_only_error()}
        else
          do_execute_query(client, action, query_payload, opts)
        end
      end
    )
  end

  @doc """
  Same as `execute_query/4`, but raises `Creatio.Error` on failure.
  """
  @spec execute_query!(Client.t() | Req.Request.t(), String.t(), map(), keyword()) :: map()
  def execute_query!(client, action, query_payload, opts \\ []) do
    case execute_query(client, action, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a custom Creatio REST web service (`/0/rest/{service_name}/{endpoint}`).

  ## Examples

      {:ok, response} =
        Creatio.DataService.custom_service(client, "CustomService", "CustomEndpoint", %{"param" => "value"})
  """
  @spec custom_service(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def custom_service(client_or_req, service_name, endpoint, payload \\ %{}, opts \\ []) do
    {final_payload, final_opts} =
      if opts == [] and is_list(payload) and payload != [] and Keyword.keyword?(payload) and
           Enum.any?(Keyword.keys(payload), &(&1 in [:method, :params, :headers, :req_options])) do
        {%{}, payload}
      else
        {payload, opts}
      end

    do_custom_service(client_or_req, service_name, endpoint, final_payload, final_opts)
  end

  @doc """
  Same as `custom_service/5`, but raises `Creatio.Error` on failure.
  """
  @spec custom_service!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          any(),
          keyword()
        ) ::
          any()
  def custom_service!(client, service_name, endpoint, payload_or_opts \\ %{}, opts \\ []) do
    case custom_service(client, service_name, endpoint, payload_or_opts, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp execute_mutation_query(client_or_req, action, query_payload, opts) do
    execute_query(client_or_req, action, query_payload, opts)
  end

  defp do_execute_query(%Client{} = client, action, query_payload, opts) do
    url = Keyword.get(opts, :url, "/0/DataService/json/SyncReply/#{action}")

    req = Req.Request.put_header(client.req, "content-type", "application/json; charset=utf-8")

    case Req.post(req, url: url, json: query_payload) do
      {:ok, %Req.Response{} = raw_resp} ->
        resp = Util.normalize_json_response(raw_resp)

        cond do
          resp.status in 200..299 and Util.html_or_xml_response?(resp) ->
            {:error, Error.from_response(resp)}

          resp.status in 200..299 and is_map(resp.body) ->
            if resp.body["success"] in [false, "false"] or
                 resp.body["Success"] in [false, "false"] do
              {:error, Error.from_response(resp)}
            else
              {:ok, resp.body}
            end

          resp.status in 200..299 ->
            {:ok, resp.body}

          true ->
            {:error, Error.from_response(resp)}
        end

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  defp do_custom_service(client_or_req, service_name, endpoint, payload, opts) do
    client = Client.ensure_client(client_or_req)
    {http_method, req_opts} = Keyword.pop(opts, :method, :post)

    Telemetry.span(
      :data_service,
      %{
        action: :custom_service,
        service: service_name,
        endpoint: endpoint,
        method: http_method,
        base_url: client.base_url
      },
      fn ->
        if client.read_only and http_method not in [:get, :head, :options] do
          {:error, read_only_error()}
        else
          url = "/0/rest/#{service_name}/#{endpoint}"

          {params, req_opts} = Keyword.pop(req_opts, :params, %{})
          {custom_headers, req_opts} = Keyword.pop(req_opts, :headers, %{})
          {extra_req_opts, req_opts} = Keyword.pop(req_opts, :req_options, [])
          req_opts = Keyword.merge(req_opts, extra_req_opts)

          req = apply_custom_headers(client.req, custom_headers)

          {final_payload, final_params} =
            resolve_custom_payload_and_params(http_method, payload, params)

          req_opts = Keyword.merge(req_opts, url: url, params: final_params, method: http_method)

          final_payload =
            if is_list(final_payload) and final_payload != [] and Keyword.keyword?(final_payload) do
              Map.new(final_payload)
            else
              final_payload
            end

          req_opts =
            cond do
              is_nil(final_payload) -> req_opts
              is_binary(final_payload) -> Keyword.put(req_opts, :body, final_payload)
              true -> Keyword.put(req_opts, :json, final_payload)
            end

          case Req.request(req, req_opts) do
            {:ok, %{status: status, body: body}} when status in 200..299 ->
              {:ok, body}

            {:ok, %Req.Response{} = resp} ->
              {:error, Error.from_response(resp)}

            {:error, exception} ->
              Error.wrap_error(exception)
          end
        end
      end
    )
  end

  defp extract_root_schema(payload) when is_map(payload) do
    payload["RootSchemaName"] ||
      payload["rootSchemaName"] ||
      payload[:RootSchemaName] ||
      payload[:rootSchemaName]
  end

  defp extract_root_schema(_), do: nil

  defp resolve_custom_payload_and_params(http_method, payload, params)
       when http_method in [:get, :head] do
    cond do
      is_map(payload) and not is_struct(payload) ->
        {nil, Map.merge(stringify_keys(params), stringify_keys(payload))}

      is_list(payload) and payload != [] and Keyword.keyword?(payload) ->
        {nil, Map.merge(stringify_keys(params), stringify_keys(payload))}

      true ->
        {payload, params}
    end
  end

  defp resolve_custom_payload_and_params(:delete, payload, params)
       when is_nil(payload) or payload == %{} do
    {nil, params}
  end

  defp resolve_custom_payload_and_params(_http_method, payload, params) do
    {payload, params}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(list) when is_list(list) do
    Map.new(list, fn {k, v} -> {to_string(k), v} end)
  end

  defp apply_custom_headers(req, headers) when is_map(headers) or is_list(headers) do
    Enum.reduce(headers, req, fn {k, v}, r ->
      Req.Request.put_header(r, to_string(k), to_string(v))
    end)
  end

  defp apply_custom_headers(req, _), do: req

  defp read_only_error do
    Error.new(
      status: 403,
      code: "ReadOnlyMode",
      message: "Client is in read-only mode"
    )
  end
end
