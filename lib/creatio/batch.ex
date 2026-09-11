defmodule Creatio.Batch do
  @moduledoc """
  Constructs and executes OData 4 JSON batch requests (`/0/odata/$batch`).

  Supports multiple operations, atomicity groups (changesets), and `Prefer: continue-on-error`.

  ## Examples

      batch =
        Creatio.Batch.new(continue_on_error: true)
        |> Creatio.Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "g1")
        |> Creatio.Batch.add_update("Contact", "c31c7862-fe...", %{"JobTitle" => "VP"}, atomicity_group: "g1")
        |> Creatio.Batch.add_delete("Contact", "b6a05348-55...")

      {:ok, responses} = Creatio.Batch.execute(client, batch)
  """

  alias Creatio.{Client, Error}

  defmodule Response do
    @moduledoc """
    Individual response item inside a batch response.
    """
    defstruct [:id, :status, :headers, :body, :atomicity_group]

    @type t :: %__MODULE__{
            id: String.t(),
            status: integer(),
            headers: map(),
            body: any(),
            atomicity_group: String.t() | nil
          }

    @doc """
    Returns `true` if the batch response status is in the 2xx range.
    """
    @spec success?(t()) :: boolean()
    def success?(%__MODULE__{status: status}) when is_integer(status), do: status in 200..299
    def success?(_), do: false

    @doc """
    Returns `true` if the batch response represents a failure (status not in 2xx).
    """
    @spec error?(t()) :: boolean()
    def error?(%__MODULE__{} = resp), do: not success?(resp)

    @doc """
    Converts a failed batch response item into a `%Creatio.Error{}`.
    """
    @spec to_error(t()) :: Error.t()
    def to_error(%__MODULE__{} = resp) do
      Error.from_response(%Req.Response{
        status: resp.status,
        headers: resp.headers || %{},
        body: resp.body
      })
    end
  end

  defstruct requests: [], continue_on_error: false

  @type t :: %__MODULE__{
          requests: [map()],
          continue_on_error: boolean()
        }

  @doc """
  Initializes a new batch request.

  ## Options

    * `:continue_on_error` - boolean. If `true`, adds header `Prefer: continue-on-error`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      requests: [],
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }
  end

  @doc """
  Adds a generic request to the batch.
  """
  @spec add(t(), String.t(), String.t(), keyword()) :: t()
  def add(%__MODULE__{} = batch, method, url, opts \\ []) do
    id = Keyword.get(opts, :id) || "req_#{length(batch.requests) + 1}"
    body = Keyword.get(opts, :body)
    atomicity_group = Keyword.get(opts, :atomicity_group)

    default_headers =
      if batch.continue_on_error or Keyword.get(opts, :continue_on_error, false) do
        %{
          "Content-Type" => "application/json;odata=verbose",
          "Accept" => "application/json;odata=verbose",
          "Prefer" => "continue-on-error"
        }
      else
        %{
          "Content-Type" => "application/json;odata=verbose",
          "Accept" => "application/json;odata=verbose"
        }
      end

    headers = Keyword.get(opts, :headers, default_headers)

    item =
      %{
        "id" => to_string(id),
        "method" => String.upcase(to_string(method)),
        "url" => url,
        "headers" => headers
      }
      |> maybe_put("body", body)
      |> maybe_put("atomicityGroup", atomicity_group)

    %{batch | requests: batch.requests ++ [item]}
  end

  @doc """
  Adds an entity retrieval operation (`GET /0/odata/...`) to the batch.

  Can be used to retrieve:
  - An entity collection or path: `add_get(batch, "Contact")` or `add_get(batch, "Contact", headers: ...)`
  - A single entity by ID: `add_get(batch, "Contact", "some-uuid")` or `add_get(batch, "Contact", "some-uuid", headers: ...)`
  """
  @spec add_get(t(), String.t(), keyword() | String.t()) :: t()
  def add_get(batch, entity_or_path, opts_or_id \\ [])

  def add_get(%__MODULE__{} = batch, entity_or_path, opts)
      when is_binary(entity_or_path) and is_list(opts) do
    add(batch, "GET", entity_or_path, opts)
  end

  def add_get(%__MODULE__{} = batch, entity, id)
      when is_binary(entity) and is_binary(id) do
    add(batch, "GET", "#{entity}(#{id})", [])
  end

  @doc """
  Adds a single entity retrieval operation with options to the batch.
  """
  @spec add_get(t(), String.t(), String.t(), keyword()) :: t()
  def add_get(%__MODULE__{} = batch, entity, id, opts)
      when is_binary(entity) and is_binary(id) and is_list(opts) do
    add(batch, "GET", "#{entity}(#{id})", opts)
  end

  @doc """
  Adds an entity creation operation (`POST /0/odata/{Entity}`) to the batch.
  """
  @spec add_create(t(), String.t(), map(), keyword()) :: t()
  def add_create(%__MODULE__{} = batch, entity, attrs, opts \\ []) do
    add(batch, "POST", entity, Keyword.put(opts, :body, attrs))
  end

  @doc """
  Adds an entity update operation (`PATCH /0/odata/{Entity}({id})`) to the batch.
  """
  @spec add_update(t(), String.t(), String.t(), map(), keyword()) :: t()
  def add_update(%__MODULE__{} = batch, entity, id, attrs, opts \\ []) do
    add(batch, "PATCH", "#{entity}(#{id})", Keyword.put(opts, :body, attrs))
  end

  @doc """
  Adds an entity deletion operation (`DELETE /0/odata/{Entity}({id})`) to the batch.
  """
  @spec add_delete(t(), String.t(), String.t(), keyword()) :: t()
  def add_delete(%__MODULE__{} = batch, entity, id, opts \\ []) do
    add(batch, "DELETE", "#{entity}(#{id})", opts)
  end

  @doc """
  Converts the batch to the JSON payload map expected by `/0/odata/$batch`.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{requests: requests}) do
    %{"requests" => requests}
  end

  @doc """
  Executes the batch request against the Creatio `/0/odata/$batch` endpoint.
  """
  @spec execute(Client.t() | Req.Request.t(), t() | map() | list(), keyword()) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  def execute(client_or_req, batch, opts \\ [])

  def execute(client_or_req, %__MODULE__{} = batch, opts) do
    client = Client.ensure_client(client_or_req)
    url = Keyword.get(opts, :url, "/0/odata/$batch")
    payload = to_payload(batch)

    req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "application/json; odata=verbose; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> Req.Request.put_header("forceusesession", "true")

    req =
      if batch.continue_on_error or Keyword.get(opts, :continue_on_error, false) do
        Req.Request.put_header(req, "prefer", "continue-on-error")
      else
        req
      end

    case Req.post(req, url: url, json: payload) do
      {:ok, %{status: 200, body: %{"responses" => raw_responses}}} when is_list(raw_responses) ->
        responses =
          Enum.map(raw_responses, fn r ->
            status =
              case r["status"] do
                s when is_integer(s) ->
                  s

                s when is_binary(s) ->
                  case Integer.parse(s) do
                    {int, _} -> int
                    _ -> s
                  end

                other ->
                  other
              end

            %Response{
              id: r["id"],
              status: status,
              headers: r["headers"] || %{},
              body: r["body"],
              atomicity_group: r["atomicityGroup"]
            }
          end)

        {:ok, responses}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        {:error, Error.new(message: Exception.message(exception), details: exception)}
    end
  end

  def execute(client_or_req, %{"requests" => _} = payload, opts) do
    batch = %__MODULE__{
      requests: payload["requests"],
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }

    execute(client_or_req, batch, opts)
  end

  def execute(client_or_req, requests, opts) when is_list(requests) do
    batch = %__MODULE__{
      requests: requests,
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }

    execute(client_or_req, batch, opts)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
