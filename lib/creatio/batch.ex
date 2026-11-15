defmodule Creatio.Batch do
  @moduledoc """
  Constructs and executes OData 4 batch requests (`/0/odata/$batch`).

  Supports both JSON batch format (standard in OData 4) and multipart/mixed MIME format,
  atomicity groups (changesets), and `Prefer: continue-on-error`.

  ## Examples

  ### JSON Batch (Default)

      batch =
        Creatio.Batch.new(continue_on_error: true)
        |> Creatio.Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "g1")
        |> Creatio.Batch.add_update("Contact", "c31c7862-fe...", %{"JobTitle" => "VP"}, atomicity_group: "g1")
        |> Creatio.Batch.add_delete("Contact", "b6a05348-55...")

      {:ok, responses} = Creatio.Batch.execute(client, batch)

  ### Multipart/Mixed MIME Batch

      {:ok, responses} = Creatio.Batch.execute(client, batch, format: :multipart)
  """

  alias Creatio.{Client, Error, Util}

  defmodule Response do
    @moduledoc """
    Individual response item inside a batch response.
    """
    defstruct [:id, :status, :headers, :body, :atomicity_group]

    @type t :: %__MODULE__{
            id: String.t() | nil,
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

  defstruct requests: [], continue_on_error: false, reversed?: false, count: 0

  @type t :: %__MODULE__{
          requests: [map()],
          continue_on_error: boolean(),
          reversed?: boolean(),
          count: non_neg_integer()
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
      continue_on_error: Keyword.get(opts, :continue_on_error, false),
      reversed?: true,
      count: 0
    }
  end

  @doc """
  Adds a generic request to the batch.
  """
  @spec add(t(), String.t() | atom(), String.t(), keyword()) :: t()
  def add(%__MODULE__{} = batch, method, url, opts \\ []) do
    {reversed_reqs, current_count} =
      if batch.reversed? do
        {batch.requests, batch.count}
      else
        {Enum.reverse(batch.requests), length(batch.requests)}
      end

    next_count = current_count + 1
    id = Keyword.get(opts, :id) || "req_#{next_count}"
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

    user_headers = Keyword.get(opts, :headers)

    headers =
      if user_headers do
        normalized_user = Map.new(user_headers, fn {k, v} -> {to_string(k), to_string(v)} end)
        user_downcased = MapSet.new(normalized_user, fn {k, _v} -> String.downcase(k) end)

        default_headers
        |> Map.reject(fn {k, _v} -> MapSet.member?(user_downcased, String.downcase(k)) end)
        |> Map.merge(normalized_user)
      else
        default_headers
      end

    item =
      %{
        "id" => to_string(id),
        "method" => method |> to_string() |> String.upcase(),
        "url" => url,
        "headers" => headers
      }
      |> maybe_put("body", body)
      |> maybe_put("atomicityGroup", atomicity_group)

    %{batch | requests: [item | reversed_reqs], reversed?: true, count: next_count}
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
    add(batch, "GET", "#{entity}(#{Util.clean_guid(id)})", [])
  end

  @doc """
  Adds a single entity retrieval operation with options to the batch.
  """
  @spec add_get(t(), String.t(), String.t(), keyword()) :: t()
  def add_get(%__MODULE__{} = batch, entity, id, opts)
      when is_binary(entity) and is_binary(id) and is_list(opts) do
    add(batch, "GET", "#{entity}(#{Util.clean_guid(id)})", opts)
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
    add(batch, "PATCH", "#{entity}(#{Util.clean_guid(id)})", Keyword.put(opts, :body, attrs))
  end

  @doc """
  Adds an entity deletion operation (`DELETE /0/odata/{Entity}({id})`) to the batch.
  """
  @spec add_delete(t(), String.t(), String.t(), keyword()) :: t()
  def add_delete(%__MODULE__{} = batch, entity, id, opts \\ []) do
    add(batch, "DELETE", "#{entity}(#{Util.clean_guid(id)})", opts)
  end

  @doc """
  Converts the batch to the JSON payload map expected by `/0/odata/$batch`.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = batch) do
    %{"requests" => ordered_requests(batch)}
  end

  @doc """
  Serializes the batch to a multipart/mixed MIME body string.
  Returns `{boundary, body}`.
  """
  @spec to_multipart(t(), keyword()) :: {String.t(), String.t()}
  def to_multipart(%__MODULE__{} = batch, opts \\ []) do
    batch_boundary = Keyword.get(opts, :boundary) || "batch_#{random_id()}"
    parts = build_multipart_parts(ordered_requests(batch), batch_boundary)
    body = Enum.join(parts, "\r\n") <> "\r\n--#{batch_boundary}--\r\n"

    {batch_boundary, body}
  end

  @doc """
  Executes the batch request against the Creatio `/0/odata/$batch` endpoint.

  ## Options

    * `:format` - `:json` (default) or `:multipart`.
    * `:continue_on_error` - boolean. If `true`, sets `Prefer: continue-on-error`.
    * `:url` - Overrides endpoint URL (defaults to `"/0/odata/$batch"`).

  When the client is in read-only mode (`client.read_only == true`), batches containing
  mutation requests (POST, PATCH, PUT, DELETE) or binary batch payloads are rejected with
  `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}`.
  """
  @spec execute(Client.t() | Req.Request.t(), t() | map() | list() | binary(), keyword()) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  def execute(client_or_req, batch, opts \\ [])

  def execute(client_or_req, %__MODULE__{} = batch, opts) do
    client = Client.ensure_client(client_or_req)
    requests = ordered_requests(batch)

    if client.read_only and Enum.any?(requests, &mutation_request?/1) do
      {:error,
       Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode. Batch contains mutation requests."
       )}
    else
      normalized_batch = %{batch | requests: requests, reversed?: false}
      url = Keyword.get(opts, :url, "/0/odata/$batch")
      format = Keyword.get(opts, :format, :json)

      continue_on_error =
        batch.continue_on_error or Keyword.get(opts, :continue_on_error, false)

      case format do
        :multipart ->
          execute_multipart(client, normalized_batch, url, continue_on_error, opts)

        _ ->
          execute_json(client, normalized_batch, url, continue_on_error)
      end
    end
  end

  def execute(client_or_req, %{"requests" => requests}, opts) when is_list(requests) do
    batch = %__MODULE__{
      requests: Enum.map(requests, &normalize_raw_request/1),
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }

    execute(client_or_req, batch, opts)
  end

  def execute(client_or_req, %{requests: requests}, opts) when is_list(requests) do
    batch = %__MODULE__{
      requests: Enum.map(requests, &normalize_raw_request/1),
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }

    execute(client_or_req, batch, opts)
  end

  def execute(client_or_req, requests, opts) when is_list(requests) do
    batch = %__MODULE__{
      requests: Enum.map(requests, &normalize_raw_request/1),
      continue_on_error: Keyword.get(opts, :continue_on_error, false)
    }

    execute(client_or_req, batch, opts)
  end

  def execute(client_or_req, body, opts) when is_binary(body) do
    client = Client.ensure_client(client_or_req)

    if client.read_only do
      {:error,
       Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message:
           "Client is in read-only mode. Binary batch requests are not supported in read-only mode."
       )}
    else
      url = Keyword.get(opts, :url, "/0/odata/$batch")

      boundary =
        Keyword.get(opts, :boundary) ||
          extract_boundary(body) ||
          "batch_default"

      req =
        client.req
        |> Req.Request.put_header(
          "content-type",
          "multipart/mixed; boundary=#{boundary}; IEEE754Compatible=true"
        )
        |> Req.Request.put_header("accept", "application/json")
        |> Req.Request.put_header("forceusesession", "true")

      handle_batch_response(Req.post(req, url: url, body: body))
    end
  end

  defp execute_json(client, batch, url, continue_on_error) do
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
      if continue_on_error do
        Req.Request.put_header(req, "prefer", "continue-on-error")
      else
        req
      end

    handle_batch_response(Req.post(req, url: url, json: payload))
  end

  defp execute_multipart(client, batch, url, continue_on_error, opts) do
    {boundary, body} = to_multipart(batch, opts)

    req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "multipart/mixed; boundary=#{boundary}; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> Req.Request.put_header("forceusesession", "true")

    req =
      if continue_on_error do
        Req.Request.put_header(req, "prefer", "continue-on-error")
      else
        req
      end

    handle_batch_response(Req.post(req, url: url, body: body))
  end

  defp handle_batch_response(
         {:ok, %Req.Response{status: status, body: %{"responses" => _}} = resp}
       )
       when status in 200..299 do
    parse_json_batch_response(resp)
  end

  defp handle_batch_response({:ok, %Req.Response{status: status, body: resp_body} = resp})
       when status in 200..299 and is_binary(resp_body) do
    content_type = resp |> get_resp_content_type() |> String.downcase()

    cond do
      String.contains?(content_type, "multipart/mixed") ->
        resp_boundary = extract_boundary_from_header(content_type)
        parse_multipart_response(resp_body, resp_boundary)

      String.trim(resp_body) == "" ->
        {:ok, []}

      true ->
        parse_json_batch_response(resp)
    end
  end

  defp handle_batch_response({:ok, %Req.Response{status: status, body: %{}} = resp})
       when status in 200..299 do
    parse_json_batch_response(resp)
  end

  defp handle_batch_response({:ok, %Req.Response{} = resp}) do
    {:error, Error.from_response(resp)}
  end

  defp handle_batch_response({:error, exception}) do
    Error.wrap_error(exception)
  end

  defp parse_json_batch_response(%Req.Response{body: %{"responses" => raw_responses}}) do
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
  end

  defp parse_json_batch_response(%Req.Response{body: body_str} = resp) when is_binary(body_str) do
    case Jason.decode(body_str) do
      {:ok, %{"responses" => _} = map} ->
        parse_json_batch_response(%Req.Response{resp | body: map})

      {:ok, %{} = entity} ->
        parse_json_batch_response(%Req.Response{resp | body: entity})

      _ ->
        {:error,
         Error.new(
           status: resp.status,
           message: "Unexpected non-JSON batch response",
           details: body_str,
           response: resp
         )}
    end
  end

  defp parse_json_batch_response(%Req.Response{body: %{} = entity} = resp) do
    {:ok,
     [
       %Response{
         id: entity["Id"] || entity["id"] || "1",
         status: resp.status || 200,
         headers: resp.headers || %{},
         body: entity,
         atomicity_group: nil
       }
     ]}
  end

  @doc """
  Parses a multipart/mixed MIME response body into a list of `%Creatio.Batch.Response{}` structs.
  """
  @spec parse_multipart_response(String.t(), String.t() | nil) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  def parse_multipart_response(body, boundary \\ nil) when is_binary(body) do
    detected_boundary =
      if boundary && String.trim(boundary) != "" do
        clean_boundary_str(boundary)
      else
        extract_boundary(body)
      end

    if is_nil(detected_boundary) or detected_boundary == "" do
      {:ok, []}
    else
      responses = do_parse_multipart(body, detected_boundary, nil)
      {:ok, responses}
    end
  end

  defp do_parse_multipart(body, boundary, current_group) do
    clean_boundary = clean_boundary_str(boundary)

    case String.split(body, "--#{clean_boundary}") do
      [_preamble | parts] ->
        Enum.flat_map(parts, fn part ->
          stripped = strip_boundary_framing(part)
          trimmed_check = String.trim(stripped)

          cond do
            trimmed_check == "" or trimmed_check == "--" or
                String.starts_with?(trimmed_check, "--") ->
              []

            true ->
              {mime_headers, _mime_body} = split_mime_headers(stripped)

              case Regex.run(
                     ~r/Content-Type:\s*multipart\/mixed;\s*boundary="?([^";\s\r\n]+)"?/i,
                     mime_headers
                   ) do
                [_, inner_boundary] ->
                  clean_inner = clean_boundary_str(inner_boundary)
                  group = extract_group_name(clean_inner)
                  do_parse_multipart(stripped, clean_inner, group)

                nil ->
                  parse_http_response_part(stripped, current_group)
              end
          end
        end)

      _ ->
        []
    end
  end

  defp strip_boundary_framing(part) do
    part
    |> String.replace_prefix("\r\n", "")
    |> String.replace_prefix("\n", "")
    |> then(fn s ->
      cond do
        String.ends_with?(s, "\r\n") -> String.replace_suffix(s, "\r\n", "")
        String.ends_with?(s, "\n") -> String.replace_suffix(s, "\n", "")
        true -> s
      end
    end)
  end

  defp split_mime_headers(part) do
    case String.split(part, ~r/\r?\n\r?\n/, parts: 2) do
      [headers, body] -> {headers, body}
      [headers] -> {headers, ""}
    end
  end

  defp extract_group_name(boundary) do
    case Regex.run(~r/changeset_([A-Za-z0-9]+)_[A-Za-z0-9]+/i, boundary) do
      [_, group] ->
        group

      _ ->
        case Regex.run(~r/changeset_([A-Za-z0-9_]+)/i, boundary) do
          [_, group] -> group
          _ -> "changeset"
        end
    end
  end

  defp parse_http_response_part(part, current_group) do
    case Regex.run(~r/HTTP\/(?:1\.[01]|2(?:\.0)?)\s+(\d{3})[^\r\n]*/i, part) do
      [status_line, status_str] ->
        status = String.to_integer(status_str)
        [mime_headers_part, rest] = String.split(part, status_line, parts: 2)
        {headers, body} = split_http_headers_body(rest)

        id =
          headers["content-id"] ||
            case Regex.run(~r/(?i)content-id:\s*([^\r\n]+)/, mime_headers_part) do
              [_, val] -> String.trim(val)
              _ -> nil
            end

        parsed_body =
          cond do
            is_nil(body) or body == "" ->
              nil

            String.contains?(headers["content-type"] || "", "application/json") ->
              case Jason.decode(body) do
                {:ok, json} -> json
                _ -> body
              end

            true ->
              body
          end

        [
          %Response{
            id: id,
            status: status,
            headers: headers,
            body: parsed_body,
            atomicity_group: current_group
          }
        ]

      _ ->
        []
    end
  end

  defp split_http_headers_body(text) do
    clean_text =
      text
      |> String.replace_prefix("\r\n", "")
      |> String.replace_prefix("\n", "")

    case String.split(clean_text, ~r/\r?\n\r?\n/, parts: 2) do
      [raw_headers, body] ->
        headers = parse_headers(raw_headers)
        {headers, body}

      [raw_headers] ->
        headers = parse_headers(raw_headers)
        {headers, nil}
    end
  end

  defp parse_headers(raw) do
    raw
    |> String.split(~r/\r?\n/)
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp build_multipart_parts(requests, batch_boundary) do
    # Preserve request order:
    # - Read requests (GET/HEAD/OPTIONS) are always direct top-level batch parts
    #   (OData 4 forbids read operations inside changesets).
    # - Grouped writes sharing an explicit `atomicityGroup` are emitted together in a
    #   changeset at the position of their first occurrence.
    # - Ungrouped writes each receive their own single-request changeset so they execute
    #   independently (matching JSON batch semantics).
    {entries, group_buckets} =
      Enum.reduce(requests, {[], %{}}, fn req, {acc, groups} ->
        if mutation_request?(req) do
          case req["atomicityGroup"] do
            nil ->
              {[{:single_changeset, req} | acc], groups}

            group_name ->
              if Map.has_key?(groups, group_name) do
                {acc, Map.update!(groups, group_name, &[req | &1])}
              else
                {[{:group, group_name} | acc], Map.put(groups, group_name, [req])}
              end
          end
        else
          {[{:direct, req} | acc], groups}
        end
      end)

    entries
    |> Enum.reverse()
    |> Enum.map(fn
      {:direct, req} ->
        build_http_request_block(req, batch_boundary)

      {:single_changeset, req} ->
        build_changeset_block("op_#{req["id"] || random_id()}", [req], batch_boundary)

      {:group, group_name} ->
        group_reqs = group_buckets |> Map.fetch!(group_name) |> Enum.reverse()
        build_changeset_block(group_name, group_reqs, batch_boundary)
    end)
  end

  defp build_changeset_block(group_name, reqs, batch_boundary) do
    changeset_boundary = "changeset_#{group_name}_#{random_id()}"

    inner_blocks =
      Enum.map(reqs, fn req ->
        "--#{changeset_boundary}\r\n" <>
          "Content-Type: application/http\r\n" <>
          "Content-Transfer-Encoding: binary\r\n\r\n" <>
          build_raw_http_message(req)
      end)

    changeset_content =
      Enum.join(inner_blocks, "\r\n") <> "\r\n--#{changeset_boundary}--\r\n"

    "--#{batch_boundary}\r\n" <>
      "Content-Type: multipart/mixed; boundary=#{changeset_boundary}\r\n\r\n" <>
      changeset_content
  end

  defp build_http_request_block(req, batch_boundary) do
    "--#{batch_boundary}\r\n" <>
      "Content-Type: application/http\r\n" <>
      "Content-Transfer-Encoding: binary\r\n\r\n" <>
      build_raw_http_message(req)
  end

  defp build_raw_http_message(req) do
    method = req["method"]
    url = req["url"]
    id = req["id"]
    body = req["body"]
    req_headers = req["headers"] || %{}

    body_str =
      cond do
        is_nil(body) -> nil
        is_binary(body) -> body
        true -> Jason.encode!(body)
      end

    headers_map =
      req_headers
      |> put_header_if_absent("Accept", "application/json;odata=verbose")
      |> maybe_put_content_type(body_str)

    headers_map =
      if id do
        put_header_if_absent(headers_map, "Content-ID", id)
      else
        headers_map
      end

    rendered_headers =
      Enum.map_join(headers_map, "\r\n", fn {k, v} -> "#{k}: #{v}" end)

    header_block = if rendered_headers != "", do: rendered_headers <> "\r\n", else: ""

    "#{method} #{url} HTTP/1.1\r\n" <>
      header_block <>
      "\r\n" <>
      (body_str || "")
  end

  defp put_header_if_absent(map, name, value) do
    downcased = String.downcase(name)

    if Enum.any?(map, fn {k, _v} -> String.downcase(to_string(k)) == downcased end) do
      map
    else
      Map.put(map, name, value)
    end
  end

  defp maybe_put_content_type(map, nil), do: map

  defp maybe_put_content_type(map, _body_str) do
    put_header_if_absent(map, "Content-Type", "application/json;odata=verbose")
  end

  defp ordered_requests(%__MODULE__{requests: requests, reversed?: true}),
    do: Enum.reverse(requests)

  defp ordered_requests(%__MODULE__{requests: requests}), do: requests

  defp mutation_request?(req) when is_map(req) do
    method =
      case Map.fetch(req, "method") do
        {:ok, m} when not is_nil(m) -> m
        _ -> Map.get(req, :method) || "GET"
      end

    normalized_method =
      method
      |> to_string()
      |> String.upcase()

    normalized_method not in ["GET", "HEAD", "OPTIONS"]
  end

  defp normalize_raw_request(req) when is_map(req) do
    Enum.reduce(req, %{}, fn
      {:atomicity_group, v}, acc -> Map.put(acc, "atomicityGroup", v)
      {:method, v}, acc -> Map.put(acc, "method", v |> to_string() |> String.upcase())
      {"method", v}, acc -> Map.put(acc, "method", v |> to_string() |> String.upcase())
      {k, v}, acc -> Map.put(acc, to_string(k), v)
    end)
  end

  defp extract_boundary(str_or_headers) when is_binary(str_or_headers) do
    case Regex.run(~r/(?:^|\r?\n)--([A-Za-z0-9_.-]+)/, str_or_headers) do
      [_, boundary] ->
        clean_boundary_str(boundary)

      _ ->
        extract_boundary_from_header(str_or_headers)
    end
  end

  defp extract_boundary_from_header(header) when is_binary(header) do
    case Regex.run(~r/boundary="?([^";\s\r\n]+)"?/i, header) do
      [_, boundary] -> clean_boundary_str(boundary)
      _ -> nil
    end
  end

  defp clean_boundary_str(boundary) when is_binary(boundary) do
    boundary
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
  end

  defp get_resp_content_type(%{headers: headers}) when is_map(headers) do
    case headers["content-type"] || headers["Content-Type"] || "" do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> ""
    end
  end

  defp random_id do
    :crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
