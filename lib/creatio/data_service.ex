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
  @spec execute_query(Client.t() | Req.Request.t(), String.t(), map(), Creatio.opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_query(client_or_req, action, query_payload, opts \\ []) do
    action = validate_path_segment!(action, "action", "execute_query/4")
    client = Client.ensure_client(client_or_req)

    raw_url = Util.get_opt(opts, :url, "/0/DataService/json/SyncReply/#{action}")
    url = Util.validate_crm_url!(raw_url, client.base_url, "DataService query URL")

    Telemetry.span(
      :data_service,
      %{
        action: action,
        entity: extract_root_schema(query_payload),
        base_url: client.base_url
      },
      fn ->
        if client.read_only and not allowed_read_only_query?(action, url) do
          {:error, read_only_error()}
        else
          do_execute_query(client, url, query_payload, opts)
        end
      end
    )
  end

  @doc """
  Same as `execute_query/4`, but raises `Creatio.Error` on failure.
  """
  @spec execute_query!(Client.t() | Req.Request.t(), String.t(), map(), Creatio.opts()) :: map()
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
          Creatio.opts()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def custom_service(client_or_req, service_name, endpoint, payload \\ %{}, opts \\ []) do
    {final_payload, final_opts} =
      if opts == [] and custom_service_opts?(payload) do
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
          Creatio.opts()
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

  defp do_execute_query(%Client{} = client, url, query_payload, opts) do
    base_req =
      Req.Request.put_header(client.req, "content-type", "application/json; charset=utf-8")

    {req, req_opts} =
      Util.prepare_req_call(
        base_req,
        opts,
        [url: url, json: query_payload],
        %{},
        [:url, :method, :json, :body]
      )

    case Req.post(req, req_opts) do
      {:ok, %Req.Response{} = raw_resp} ->
        case Util.decode_api_response(raw_resp) do
          {:html_or_xml, resp} ->
            {:error, Error.from_response(resp)}

          {:ok, %Req.Response{status: status, body: %{} = body} = resp} when status in 200..299 ->
            if body["success"] in [false, "false"] or body["Success"] in [false, "false"] do
              {:error, Error.from_response(resp)}
            else
              {:ok, body}
            end

          {:ok, %Req.Response{} = resp} ->
            {:error, Error.from_response(resp)}
        end

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  defp do_custom_service(client_or_req, service_name, endpoint, payload, opts) do
    service_name = validate_path_segment!(service_name, "service_name", "custom_service/5")
    endpoint = validate_path_segment!(endpoint, "endpoint", "custom_service/5")
    client = Client.ensure_client(client_or_req)

    opts_kw =
      cond do
        is_nil(opts) -> []
        is_map(opts) -> Util.to_keyword_opts(opts)
        true -> opts
      end

    {raw_method, req_opts} = Keyword.pop(opts_kw, :method, :post)
    http_method = normalize_http_method!(raw_method)

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
          {_dropped_req_options, inline_req_opts} = Keyword.pop(req_opts, :req_options, [])
          inline_req_opts = Keyword.drop(inline_req_opts, [:url, :method, :json, :body])

          {final_payload, final_params} =
            resolve_custom_payload_and_params(http_method, payload, params)

          {req_with_extra_headers, prepared_opts} =
            Util.prepare_req_call(
              apply_custom_headers(client.req, custom_headers),
              opts_kw,
              [url: url, method: http_method],
              stringify_keys(final_params),
              [:url, :method, :json, :body]
            )

          req_opts = Keyword.merge(inline_req_opts, prepared_opts)

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

          case Req.request(req_with_extra_headers, req_opts) do
            {:ok, %Req.Response{} = raw_resp} ->
              case Util.decode_api_response(raw_resp) do
                {:ok, %Req.Response{status: status, body: body} = resp}
                when status in 200..299 ->
                  if wcf_error_payload?(body) do
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

      payload == [] ->
        {nil, params}

      true ->
        {payload, params}
    end
  end

  defp resolve_custom_payload_and_params(:delete, payload, params)
       when is_nil(payload) or payload == %{} or payload == [] do
    {nil, params}
  end

  defp resolve_custom_payload_and_params(_http_method, payload, params) do
    {payload, params}
  end

  @allowed_http_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp normalize_http_method!(method) when is_atom(method) or is_binary(method) do
    key = method |> to_string() |> String.trim() |> String.downcase()

    case Map.fetch(@allowed_http_methods, key) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError, "invalid HTTP method for custom_service/5: #{inspect(method)}"
    end
  end

  defp normalize_http_method!(other) do
    raise ArgumentError, "invalid HTTP method for custom_service/5: #{inspect(other)}"
  end

  defp wcf_error_payload?(%{"error" => _}), do: true
  defp wcf_error_payload?(%{"errorInfo" => %{} = info}) when map_size(info) > 0, do: true
  defp wcf_error_payload?(%{"ErrorInfo" => %{} = info}) when map_size(info) > 0, do: true
  defp wcf_error_payload?(%{"responseStatus" => %{} = rs}) when map_size(rs) > 0, do: true
  defp wcf_error_payload?(%{"ResponseStatus" => %{} = rs}) when map_size(rs) > 0, do: true
  defp wcf_error_payload?(%{"Exception" => %{} = ex}) when map_size(ex) > 0, do: true
  defp wcf_error_payload?(%{"success" => val}) when val in [false, "false"], do: true
  defp wcf_error_payload?(%{"Success" => val}) when val in [false, "false"], do: true
  defp wcf_error_payload?(_), do: false

  defp stringify_keys(nil), do: %{}

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

  @custom_service_opt_keys [
    :method,
    :params,
    :headers,
    :req_options,
    :receive_timeout,
    :pool_timeout,
    :connect_options,
    :retry,
    :retry_delay,
    :max_retries,
    :plug,
    :adapter,
    :finch,
    :decode_body,
    :redirect,
    :max_redirects,
    :compressed,
    :raw,
    :http_errors,
    :into
  ]

  defp custom_service_opts?(term) do
    is_list(term) and term != [] and Keyword.keyword?(term) and
      Enum.all?(Keyword.keys(term), &(&1 in @custom_service_opt_keys))
  end

  defp validate_path_segment!(val, label, fun_name)
       when is_atom(val) and not is_nil(val) and not is_boolean(val) do
    val |> Atom.to_string() |> validate_path_segment!(label, fun_name)
  end

  defp validate_path_segment!(val, label, fun_name) when is_binary(val) do
    trimmed = String.trim(val)

    if trimmed != "" and trimmed not in [".", ".."] and not String.contains?(trimmed, "..") and
         Regex.match?(~r/^[A-Za-z0-9_.-]+$/, trimmed) do
      trimmed
    else
      raise ArgumentError,
            "#{label} must be a non-empty safe path segment before calling #{fun_name}, got: #{inspect(val)}"
    end
  end

  defp validate_path_segment!(other, label, fun_name) do
    raise ArgumentError,
          "#{label} must be a non-empty safe path segment before calling #{fun_name}, got: #{inspect(other)}"
  end

  defp allowed_read_only_query?(action, url) do
    raw_path = URI.parse(url).path || ""

    case Util.safe_normalized_path(raw_path) do
      {:ok, path} ->
        action == "SelectQuery" and
          not String.contains?(path, "/0/rest/") and
          String.ends_with?(path, "/DataService/json/SyncReply/SelectQuery")

      {:error, :invalid_path} ->
        false
    end
  end

  defp read_only_error do
    Error.new(
      status: 403,
      code: "ReadOnlyMode",
      message: "Client is in read-only mode"
    )
  end
end
