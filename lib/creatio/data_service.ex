defmodule Creatio.DataService do
  @moduledoc """
  Client for Creatio's proprietary DataService JSON API and custom REST WebServices.

  Supports `SelectQuery` operations and calling custom service endpoints.
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
    client = Client.ensure_client(client_or_req)
    url = Keyword.get(opts, :url, "/0/DataService/json/SyncReply/SelectQuery")

    req =
      client.req
      |> Req.Request.put_header("content-type", "application/json; charset=utf-8")
      |> Req.Request.put_header("forceusesession", "true")

    case Req.post(req, url: url, json: query_payload) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
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
  Executes a custom Creatio REST web service (`/0/rest/{service_name}/{endpoint}`).

  ## Examples

      {:ok, response} =
        Creatio.DataService.custom_service(client, "CustomService", "CustomEndpoint", %{"param" => "value"})
  """
  @spec custom_service(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          map() | keyword(),
          keyword()
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def custom_service(client_or_req, service_name, endpoint, payload_or_opts \\ %{}, opts \\ [])

  def custom_service(client_or_req, service_name, endpoint, opts, []) when is_list(opts) do
    custom_service(client_or_req, service_name, endpoint, %{}, opts)
  end

  def custom_service(client_or_req, service_name, endpoint, payload, opts)
      when is_map(payload) and is_list(opts) do
    client = Client.ensure_client(client_or_req)
    url = "/0/rest/#{service_name}/#{endpoint}"
    http_method = Keyword.get(opts, :method, :post)

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")

    result =
      case http_method do
        :get -> Req.get(req, url: url, params: payload)
        :post -> Req.post(req, url: url, json: payload)
        :put -> Req.put(req, url: url, json: payload)
        :delete -> Req.delete(req, url: url, params: payload)
      end

    case result do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  @doc """
  Same as `custom_service/5`, but raises `Creatio.Error` on failure.
  """
  @spec custom_service!(
          Client.t() | Req.Request.t(),
          String.t(),
          String.t(),
          map() | keyword(),
          keyword()
        ) ::
          any()
  def custom_service!(client, service_name, endpoint, payload_or_opts \\ %{}, opts \\ [])

  def custom_service!(client, service_name, endpoint, opts, []) when is_list(opts) do
    custom_service!(client, service_name, endpoint, %{}, opts)
  end

  def custom_service!(client, service_name, endpoint, payload, opts)
      when is_map(payload) and is_list(opts) do
    case custom_service(client, service_name, endpoint, payload, opts) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
