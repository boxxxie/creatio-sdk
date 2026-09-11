defmodule Creatio.OData3 do
  @moduledoc """
  Legacy OData 3 protocol client for Creatio (`/0/ServiceModel/EntityDataService.svc/`).

  Provided for backward compatibility with legacy Creatio environments.
  """

  alias Creatio.{Client, Error}

  @base_path "/0/ServiceModel/EntityDataService.svc"

  @doc """
  Queries an OData 3 entity collection (`GET .../{Entity}Collection`).
  """
  @spec list(Client.t() | Req.Request.t(), String.t(), keyword() | map()) ::
          {:ok, list() | map()} | {:error, Error.t()}
  def list(client_or_req, entity, opts \\ []) do
    client = Client.ensure_client(client_or_req)
    collection_name = collection_name(entity)
    url = "#{@base_path}/#{collection_name}"
    params = normalize_params(opts)

    case Req.get(client.req, url: url, params: params) do
      {:ok, %{status: 200, body: %{"d" => %{"results" => records}}}} ->
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
  def list!(client, entity, opts \\ []) do
    case list(client, entity, opts) do
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
    url = "#{@base_path}/#{collection_name}(guid'#{id}')"
    params = normalize_params(opts)

    case Req.get(client.req, url: url, params: params) do
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
  Creates an entity via OData 3 (`POST .../{Entity}Collection`).
  """
  @spec create(Client.t() | Req.Request.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(client_or_req, entity, attrs, opts \\ []) do
    client = Client.ensure_client(client_or_req)
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
    collection_name = collection_name(entity)
    url = "#{@base_path}/#{collection_name}(guid'#{id}')"

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
    collection_name = collection_name(entity)
    url = "#{@base_path}/#{collection_name}(guid'#{id}')"

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

  defp collection_name(name) do
    if String.ends_with?(name, "Collection"), do: name, else: "#{name}Collection"
  end

  defp normalize_params(opts) when is_list(opts) do
    Enum.reduce(opts, %{}, fn
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

      {:expand, val}, acc when is_list(val) ->
        Map.put(acc, "$expand", Enum.map_join(val, ",", &to_string/1))

      {:expand, val}, acc when is_binary(val) or is_atom(val) ->
        Map.put(acc, "$expand", to_string(val))

      {key, val}, acc when is_binary(key) ->
        Map.put(acc, key, to_string(val))

      _, acc ->
        acc
    end)
  end

  defp normalize_params(map) when is_map(map), do: map
end
