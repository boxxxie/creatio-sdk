defmodule Creatio.DataService do
  @moduledoc """
  Client for Creatio's proprietary DataService JSON API and custom REST WebServices.

  Supports `SelectQuery`, `InsertQuery`, `UpdateQuery`, `DeleteQuery`, `BatchQuery`,
  and calling custom REST service endpoints.
  """

  alias Creatio.{Client, Error}

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
  def select_query!(client, query_payload, opts \\ []) do
    case select_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an InsertQuery against `/0/DataService/json/SyncReply/InsertQuery`.
  """
  @spec insert_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def insert_query(client_or_req, query_payload, opts \\ []) do
    execute_query(client_or_req, "InsertQuery", query_payload, opts)
  end

  @doc """
  Same as `insert_query/3`, but raises `Creatio.Error` on failure.
  """
  def insert_query!(client, query_payload, opts \\ []) do
    case insert_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes an UpdateQuery against `/0/DataService/json/SyncReply/UpdateQuery`.
  """
  @spec update_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_query(client_or_req, query_payload, opts \\ []) do
    execute_query(client_or_req, "UpdateQuery", query_payload, opts)
  end

  @doc """
  Same as `update_query/3`, but raises `Creatio.Error` on failure.
  """
  def update_query!(client, query_payload, opts \\ []) do
    case update_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a DeleteQuery against `/0/DataService/json/SyncReply/DeleteQuery`.
  """
  @spec delete_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def delete_query(client_or_req, query_payload, opts \\ []) do
    execute_query(client_or_req, "DeleteQuery", query_payload, opts)
  end

  @doc """
  Same as `delete_query/3`, but raises `Creatio.Error` on failure.
  """
  def delete_query!(client, query_payload, opts \\ []) do
    case delete_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a BatchQuery against `/0/DataService/json/SyncReply/BatchQuery`.
  """
  @spec batch_query(Client.t() | Req.Request.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def batch_query(client_or_req, query_payload, opts \\ []) do
    execute_query(client_or_req, "BatchQuery", query_payload, opts)
  end

  @doc """
  Same as `batch_query/3`, but raises `Creatio.Error` on failure.
  """
  def batch_query!(client, query_payload, opts \\ []) do
    case batch_query(client, query_payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Executes a generic DataService query against `/0/DataService/json/SyncReply/{action}`.
  """
  @spec execute_query(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_query(client_or_req, action, query_payload, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    url = Keyword.get(opts, :url, "/0/DataService/json/SyncReply/#{action}")

    req =
      client.req
      |> Req.Request.put_header("content-type", "application/json; charset=utf-8")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.post(req, url: url, json: query_payload) do
      {:ok, %{status: status, body: %{} = body} = resp} when status in 200..299 ->
        if body["success"] in [false, "false"] or body["Success"] in [false, "false"] do
          {:error, Error.from_response(resp)}
        else
          {:ok, body}
        end

      {:ok, %{status: status, body: body_str} = resp}
      when status in 200..299 and is_binary(body_str) ->
        case Jason.decode(body_str) do
          {:ok, %{} = decoded} ->
            if decoded["success"] in [false, "false"] or decoded["Success"] in [false, "false"] do
              {:error, Error.from_response(%{resp | body: decoded})}
            else
              {:ok, decoded}
            end

          _ ->
            {:ok, body_str}
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `execute_query/4`, but raises `Creatio.Error` on failure.
  """
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
      if opts == [] and is_list(payload) and Keyword.keyword?(payload) and
           Enum.any?(Keyword.keys(payload), &(&1 in [:method, :params, :headers, :req_options])) do
        {%{}, payload}
      else
        {payload, opts}
      end

    do_custom_service(client_or_req, service_name, endpoint, final_payload, final_opts)
  end

  defp do_custom_service(client_or_req, service_name, endpoint, payload, opts) do
    client = Client.ensure_client(client_or_req)
    url = "/0/rest/#{service_name}/#{endpoint}"

    {http_method, req_opts} = Keyword.pop(opts, :method, :post)
    {params, req_opts} = Keyword.pop(req_opts, :params, %{})
    {custom_headers, req_opts} = Keyword.pop(req_opts, :headers, %{})
    {extra_req_opts, req_opts} = Keyword.pop(req_opts, :req_options, [])
    req_opts = Keyword.merge(req_opts, extra_req_opts)

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")
      |> apply_custom_headers(custom_headers)

    {final_payload, final_params} =
      if http_method in [:get, :delete] do
        cond do
          is_map(payload) and not Map.has_key?(payload, :__struct__) ->
            {nil, Map.merge(Map.new(params), payload)}

          is_list(payload) and Keyword.keyword?(payload) ->
            {nil, Keyword.merge(Enum.to_list(params), payload)}

          true ->
            {payload, params}
        end
      else
        {payload, params}
      end

    req_opts = Keyword.merge(req_opts, url: url, params: final_params, method: http_method)

    final_payload =
      if is_list(final_payload) and Keyword.keyword?(final_payload) do
        Map.new(final_payload)
      else
        final_payload
      end

    req_opts =
      if is_nil(final_payload) do
        req_opts
      else
        if is_binary(final_payload) do
          Keyword.put(req_opts, :body, final_payload)
        else
          Keyword.put(req_opts, :json, final_payload)
        end
      end

    case Req.request(req, req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  defp apply_custom_headers(req, headers) when is_map(headers) do
    Enum.reduce(headers, req, fn {k, v}, r ->
      Req.Request.put_header(r, to_string(k), to_string(v))
    end)
  end

  defp apply_custom_headers(req, headers) when is_list(headers) do
    Enum.reduce(headers, req, fn {k, v}, r ->
      Req.Request.put_header(r, to_string(k), to_string(v))
    end)
  end

  defp apply_custom_headers(req, _), do: req

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
  def custom_service!(client, service_name, endpoint, payload_or_opts \\ %{}, opts \\ [])

  def custom_service!(client, service_name, endpoint, opts, []) when is_list(opts) do
    if Keyword.keyword?(opts) do
      custom_service!(client, service_name, endpoint, %{}, opts)
    else
      case custom_service(client, service_name, endpoint, opts, []) do
        {:ok, result} -> result
        {:error, error} -> raise error
      end
    end
  end

  def custom_service!(client, service_name, endpoint, payload, opts) when is_list(opts) do
    case custom_service(client, service_name, endpoint, payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
