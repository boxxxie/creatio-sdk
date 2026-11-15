defmodule Creatio.Batch do
  @moduledoc """
  Constructs and executes OData 4 batch requests (`/0/odata/$batch`).

  Supports both JSON batch format (standard in OData 4) and multipart/mixed MIME format,
  atomicity groups (changesets), `Prefer: continue-on-error`, and `Prefer: return=minimal`.

  `Creatio.Batch.t()` is an `@opaque` builder struct; inspect or serialize it via
  `size/1`, `requests/1`, `to_payload/1`, `to_multipart/2`, and `to_multipart_iodata/2`.

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

  alias Creatio.{Client, Error, Telemetry, Util}

  defmodule Response do
    @moduledoc """
    Individual response item inside a batch response.
    """
    defstruct [:id, :status, :headers, :body, :atomicity_group]

    @type t :: %__MODULE__{
            id: String.t() | nil,
            status: integer() | String.t() | nil,
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

  defstruct ops: [], count: 0, continue_on_error: false, return: nil

  @opaque t :: %__MODULE__{
            ops: [map()],
            count: non_neg_integer(),
            continue_on_error: boolean(),
            return: :minimal | :representation | nil
          }

  @doc """
  Initializes a new batch request.

  ## Options

    * `:continue_on_error` - boolean. If `true`, adds header `Prefer: continue-on-error`.
    * `:return` - `:minimal` or `:representation`. Sets `Prefer: return=minimal` or `return=representation`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      continue_on_error: Keyword.get(opts, :continue_on_error, false),
      return: Keyword.get(opts, :return)
    }
  end

  @doc """
  Adds a generic request to the batch.
  """
  @spec add(t(), String.t() | atom(), String.t(), keyword()) :: t()
  def add(%__MODULE__{} = batch, method, url, opts \\ []) do
    url = validate_batch_url!(url)
    next_count = batch.count + 1
    id = Keyword.get(opts, :id) || "req_#{next_count}"
    id_str = validate_item_id!(id)
    body = Keyword.get(opts, :body)

    atomicity_group =
      case Keyword.fetch(opts, :atomicity_group) do
        {:ok, nil} -> nil
        {:ok, group} -> validate_boundary!("atomicity_group", group)
        :error -> nil
      end

    method_str = method |> to_string() |> String.upcase()

    prefer =
      build_prefer(
        batch.continue_on_error or Keyword.get(opts, :continue_on_error, false),
        Keyword.get(opts, :return, batch.return)
      )

    base_headers =
      %{
        "Accept" => "application/json; odata.metadata=minimal"
      }
      |> maybe_put_body_content_type(body)
      |> maybe_put("Prefer", prefer)

    headers = merge_headers_case_insensitive(base_headers, Keyword.get(opts, :headers))

    item =
      %{
        "id" => id_str,
        "method" => method_str,
        "url" => url,
        "headers" => headers
      }
      |> maybe_put("body", body)
      |> maybe_put("atomicityGroup", atomicity_group)

    %__MODULE__{batch | ops: [item | batch.ops], count: next_count}
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
    entity = Util.require_entity_name!(entity, :add_get)
    add(batch, "GET", "#{entity}(#{Util.clean_guid(id)})", [])
  end

  @doc """
  Adds a single entity retrieval operation with options to the batch.
  """
  @spec add_get(t(), String.t(), String.t(), keyword()) :: t()
  def add_get(%__MODULE__{} = batch, entity, id, opts)
      when is_binary(entity) and is_binary(id) and is_list(opts) do
    entity = Util.require_entity_name!(entity, :add_get)
    add(batch, "GET", "#{entity}(#{Util.clean_guid(id)})", opts)
  end

  @doc """
  Adds an entity creation operation (`POST /0/odata/{Entity}`) to the batch.
  """
  @spec add_create(t(), String.t(), map(), keyword()) :: t()
  def add_create(%__MODULE__{} = batch, entity, attrs, opts \\ []) do
    entity = Util.require_entity_name!(entity, :add_create)
    add(batch, "POST", entity, Keyword.put(opts, :body, attrs))
  end

  @doc """
  Adds an entity update operation (`PATCH /0/odata/{Entity}({id})`) to the batch.
  """
  @spec add_update(t(), String.t(), String.t(), map(), keyword()) :: t()
  def add_update(%__MODULE__{} = batch, entity, id, attrs, opts \\ []) do
    entity = Util.require_entity_name!(entity, :add_update)
    add(batch, "PATCH", "#{entity}(#{Util.clean_guid(id)})", Keyword.put(opts, :body, attrs))
  end

  @doc """
  Adds an entity deletion operation (`DELETE /0/odata/{Entity}({id})`) to the batch.
  """
  @spec add_delete(t(), String.t(), String.t(), keyword()) :: t()
  def add_delete(%__MODULE__{} = batch, entity, id, opts \\ []) do
    entity = Util.require_entity_name!(entity, :add_delete)
    add(batch, "DELETE", "#{entity}(#{Util.clean_guid(id)})", opts)
  end

  @doc """
  Returns the number of queued operations in the batch.

  ## Examples

      iex> batch = Creatio.Batch.new() |> Creatio.Batch.add_get("Contact", "1")
      iex> Creatio.Batch.size(batch)
      1

  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{count: count}), do: count

  @doc """
  Returns the queued operations in insertion order.

  ## Examples

      iex> batch = Creatio.Batch.new() |> Creatio.Batch.add_get("Contact", "1")
      iex> [%{"method" => "GET", "url" => "Contact(1)"}] = Creatio.Batch.requests(batch)

  """
  @spec requests(t()) :: [map()]
  def requests(%__MODULE__{} = batch), do: ordered_requests(batch)

  @doc """
  Converts the batch to the JSON payload map expected by `/0/odata/$batch`.
  """
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = batch) do
    %{"requests" => ordered_requests(batch)}
  end

  @doc """
  Serializes the batch into `{boundary, iodata}` without copying intermediate payload buffers.
  """
  @spec to_multipart_iodata(t(), keyword()) :: {String.t(), iodata()}
  def to_multipart_iodata(%__MODULE__{} = batch, opts \\ []) do
    batch_boundary = resolve_batch_boundary!(opts)
    requests = ordered_requests(batch)
    parts = build_multipart_iodata(requests, batch_boundary)
    iodata = [Enum.intersperse(parts, "\r\n"), "\r\n--", batch_boundary, "--\r\n"]
    {batch_boundary, iodata}
  end

  @doc """
  Serializes the batch to a multipart/mixed MIME body string.
  Returns `{boundary, body}`.
  """
  @spec to_multipart(t(), keyword()) :: {String.t(), String.t()}
  def to_multipart(%__MODULE__{} = batch, opts \\ []) do
    {boundary, iodata} = to_multipart_iodata(batch, opts)
    {boundary, IO.iodata_to_binary(iodata)}
  end

  @doc """
  Executes the batch request against the Creatio `/0/odata/$batch` endpoint.

  ## Options

    * `:format` - `:json` (default) or `:multipart`.
    * `:continue_on_error` - boolean. If `true`, sets `Prefer: continue-on-error`.
    * `:return` - `:minimal` or `:representation`. Sets `Prefer: return=minimal` or `return=representation`.
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
    format = validate_batch_format!(opts, :json)

    Telemetry.span(
      :batch,
      %{format: format, operation_count: length(requests), base_url: client.base_url},
      fn ->
        do_execute_requests(
          client,
          requests,
          batch.continue_on_error or Keyword.get(opts, :continue_on_error, false),
          Keyword.get(opts, :return, batch.return),
          format,
          opts
        )
      end
    )
  end

  def execute(client_or_req, %{"requests" => requests}, opts) when is_list(requests) do
    execute(client_or_req, requests, opts)
  end

  def execute(client_or_req, %{requests: requests}, opts) when is_list(requests) do
    execute(client_or_req, requests, opts)
  end

  def execute(client_or_req, requests, opts) when is_list(requests) do
    client = Client.ensure_client(client_or_req)
    format = validate_batch_format!(opts, :json)

    Telemetry.span(
      :batch,
      %{format: format, operation_count: length(requests), base_url: client.base_url},
      fn ->
        normalized = Enum.map(requests, &normalize_raw_request/1)

        do_execute_requests(
          client,
          normalized,
          Keyword.get(opts, :continue_on_error, false),
          Keyword.get(opts, :return),
          format,
          opts
        )
      end
    )
  end

  def execute(client_or_req, body, opts) when is_binary(body) do
    _format = validate_batch_format!(opts, :multipart)
    client = Client.ensure_client(client_or_req)
    operation_count = count_multipart_operations(body)

    Telemetry.span(
      :batch,
      %{format: :multipart, operation_count: operation_count, base_url: client.base_url},
      fn ->
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
            case Keyword.fetch(opts, :boundary) do
              {:ok, nil} -> extract_boundary(body) || "batch_default"
              {:ok, b} -> validate_boundary!("boundary", b)
              :error -> extract_boundary(body) || "batch_default"
            end
            |> then(&validate_boundary!("boundary", &1))

          req =
            client.req
            |> Req.Request.put_header(
              "content-type",
              "multipart/mixed; boundary=#{boundary}; IEEE754Compatible=true"
            )
            |> Req.Request.put_header("accept", "application/json")

          Req.post(req, url: url, body: body)
          |> handle_batch_response()
        end
      end
    )
  end

  defp do_execute_requests(client, requests, continue_on_error?, return_pref, format, opts) do
    if client.read_only and has_mutation?(requests) do
      {:error,
       Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode. Batch contains mutation requests."
       )}
    else
      url = Keyword.get(opts, :url, "/0/odata/$batch")
      prefer = build_prefer(continue_on_error?, return_pref)

      case format do
        :multipart -> execute_multipart(client, requests, url, prefer, opts)
        :json -> execute_json(client, requests, url, prefer)
      end
    end
  end

  defp validate_batch_format!(opts, default) do
    case Keyword.get(opts, :format, default) do
      :json ->
        :json

      :multipart ->
        :multipart

      other ->
        raise ArgumentError,
              "invalid batch :format option #{inspect(other)}, expected :json or :multipart"
    end
  end

  defp count_multipart_operations(body) when is_binary(body) do
    length(Regex.scan(~r/content-type:\s*application\/http\b/i, body))
  end

  defp execute_json(client, requests, url, prefer) do
    req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "application/json; odata.metadata=minimal; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> maybe_put_req_header("prefer", prefer)

    Req.post(req, url: url, json: %{"requests" => requests})
    |> handle_batch_response()
  end

  defp execute_multipart(client, requests, url, prefer, opts) do
    batch_boundary = resolve_batch_boundary!(opts)
    parts = build_multipart_iodata(requests, batch_boundary)
    iodata = [Enum.intersperse(parts, "\r\n"), "\r\n--", batch_boundary, "--\r\n"]

    req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "multipart/mixed; boundary=#{batch_boundary}; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> maybe_put_req_header("prefer", prefer)

    Req.post(req, url: url, body: iodata)
    |> handle_batch_response()
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
        parse_multipart_response(resp_body, extract_boundary_from_header(content_type))

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
        %Response{
          id: r["id"],
          status: parse_status_code(r["status"]),
          headers: r["headers"] || %{},
          body: r["body"],
          atomicity_group: r["atomicityGroup"]
        }
      end)

    {:ok, responses}
  end

  defp parse_json_batch_response(%Req.Response{body: body_str} = resp) when is_binary(body_str) do
    cleaned_body = String.trim_leading(body_str, "\uFEFF")

    case Jason.decode(cleaned_body, strings: :copy) do
      {:ok, %{} = map} ->
        parse_json_batch_response(%Req.Response{resp | body: map})

      _ ->
        if String.starts_with?(String.trim_leading(cleaned_body), "--") do
          parse_multipart_response(cleaned_body, nil)
        else
          {:error,
           Error.new(
             status: resp.status,
             message: "Unexpected non-JSON batch response",
             details: :binary.copy(body_str),
             response: resp
           )}
        end
    end
  end

  defp parse_json_batch_response(%Req.Response{body: %{} = entity} = resp) do
    {:ok,
     [
       %Response{
         id: entity["Id"] || entity["id"] || "1",
         status: resp.status,
         headers: resp.headers,
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
      if is_binary(boundary) and String.trim(boundary) != "" do
        clean_boundary_str(boundary)
      else
        extract_boundary(body)
      end

    if is_nil(detected_boundary) or detected_boundary == "" do
      {:ok, []}
    else
      {:ok, do_parse_multipart(body, detected_boundary, nil)}
    end
  end

  defp do_parse_multipart(body, boundary, current_group) do
    clean_boundary = clean_boundary_str(boundary)

    case String.split(body, "--" <> clean_boundary) do
      [_preamble | parts] ->
        Enum.flat_map(parts, &parse_multipart_part(&1, current_group))

      _ ->
        []
    end
  end

  defp parse_multipart_part(raw_part, current_group) do
    part = strip_part_crlf(raw_part)

    if part == "" or String.starts_with?(part, "--") do
      []
    else
      {mime_head, mime_body} = split_blank_line(part)
      mime_headers = parse_headers(mime_head)
      mime_ct = mime_headers["content-type"] || ""

      if String.contains?(String.downcase(mime_ct), "multipart/mixed") do
        case extract_boundary_from_header(mime_ct) do
          nil ->
            []

          inner_boundary ->
            group = extract_group_name(inner_boundary)
            do_parse_multipart(mime_body || "", inner_boundary, group)
        end
      else
        parse_http_response_part(mime_headers, mime_body || "", current_group)
      end
    end
  end

  defp parse_http_response_part(mime_headers, http_payload, current_group) do
    {http_head, http_body} = split_blank_line(http_payload)
    {status_line, raw_headers} = split_first_line(http_head)

    case parse_http_status_line(status_line) do
      {:ok, status} ->
        headers = parse_headers(raw_headers)
        raw_id = headers["content-id"] || mime_headers["content-id"]
        id = if is_binary(raw_id), do: :binary.copy(raw_id), else: nil

        parsed_body =
          cond do
            is_nil(http_body) or http_body == "" ->
              nil

            String.contains?(String.downcase(headers["content-type"] || ""), "application/json") ->
              case Jason.decode(http_body, strings: :copy) do
                {:ok, json} -> json
                _ -> :binary.copy(http_body)
              end

            true ->
              :binary.copy(http_body)
          end

        [
          %Response{
            id: id,
            status: status,
            headers: headers,
            body: parsed_body,
            atomicity_group: current_group && :binary.copy(current_group)
          }
        ]

      :error ->
        []
    end
  end

  # O(1) byte-level CRLF / LF trimming around boundary delimiters (zero UTF-8 grapheme scan)
  defp strip_part_crlf(bin) do
    bin =
      case bin do
        <<"\r\n", rest::binary>> -> rest
        <<"\n", rest::binary>> -> rest
        other -> other
      end

    size = byte_size(bin)

    cond do
      size >= 2 and binary_part(bin, size - 2, 2) == "\r\n" ->
        binary_part(bin, 0, size - 2)

      size >= 1 and :binary.last(bin) == ?\n ->
        binary_part(bin, 0, size - 1)

      true ->
        bin
    end
  end

  # Splits at the first header/body blank line using compiled binary search (never scans into body)
  defp split_blank_line(bin) do
    case :binary.match(bin, ["\r\n\r\n", "\n\n"]) do
      {pos, len} ->
        head = binary_part(bin, 0, pos)
        body_start = pos + len
        body = binary_part(bin, body_start, byte_size(bin) - body_start)
        {head, body}

      :nomatch ->
        {bin, nil}
    end
  end

  defp split_first_line(bin) do
    case :binary.match(bin, ["\r\n", "\n"]) do
      {pos, len} ->
        first = binary_part(bin, 0, pos)
        rest_start = pos + len
        {first, binary_part(bin, rest_start, byte_size(bin) - rest_start)}

      :nomatch ->
        {bin, ""}
    end
  end

  defp parse_http_status_line(<<"HTTP/", rest::binary>>) do
    case String.split(rest, " ", parts: 3, trim: true) do
      [_ver, code_str | _] ->
        case Integer.parse(code_str) do
          {code, ""} when code in 100..599 -> {:ok, code}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_http_status_line(_), do: :error

  defp parse_headers(""), do: %{}

  defp parse_headers(raw) do
    raw
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case :binary.split(line, ":") do
        [k, v] ->
          key = k |> String.trim() |> String.downcase() |> :binary.copy()
          val = v |> String.trim() |> :binary.copy()
          Map.put(acc, key, val)

        _ ->
          acc
      end
    end)
  end

  # Preserves request order; reads stay top-level, grouped writes share a changeset at first occurrence
  defp build_multipart_iodata(requests, batch_boundary) do
    {entries, group_buckets} =
      Enum.reduce(requests, {[], %{}}, fn req, {acc, groups} ->
        if mutation_request?(req) do
          case req["atomicityGroup"] || req[:atomicityGroup] do
            nil ->
              {[{:single_changeset, req} | acc], groups}

            "" ->
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
        [
          "--",
          batch_boundary,
          "\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\n",
          build_raw_http_iodata(req)
        ]

      {:single_changeset, req} ->
        group_name = "op_#{req["id"] || req[:id] || random_id()}"
        build_changeset_iodata(group_name, [req], batch_boundary)

      {:group, group_name} ->
        group_reqs = group_buckets |> Map.fetch!(group_name) |> Enum.reverse()
        build_changeset_iodata(group_name, group_reqs, batch_boundary)
    end)
  end

  defp build_changeset_iodata(group_name, reqs, batch_boundary) do
    validate_boundary!("atomicity_group", group_name)
    cs_boundary = "changeset_#{group_name}_#{random_id()}"
    validate_boundary!("changeset boundary", cs_boundary)

    inner =
      Enum.map(reqs, fn req ->
        [
          "--",
          cs_boundary,
          "\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\n",
          build_raw_http_iodata(req)
        ]
      end)

    [
      "--",
      batch_boundary,
      "\r\nContent-Type: multipart/mixed; boundary=",
      cs_boundary,
      "\r\n\r\n",
      Enum.intersperse(inner, "\r\n"),
      "\r\n--",
      cs_boundary,
      "--\r\n"
    ]
  end

  defp build_raw_http_iodata(req) do
    method = extract_method(req)
    url = validate_batch_url!(to_string(req["url"] || req[:url] || ""))
    id = req["id"] || req[:id]
    body = req["body"] || req[:body]
    req_headers = req["headers"] || req[:headers] || %{}

    body_iodata =
      cond do
        is_nil(body) -> nil
        is_binary(body) -> body
        true -> Jason.encode_to_iodata!(body)
      end

    headers_map =
      %{"Accept" => "application/json; odata.metadata=minimal"}
      |> maybe_put_body_content_type(body_iodata)
      |> merge_headers_case_insensitive(req_headers)
      |> maybe_put_content_id(id)

    header_iodata =
      Enum.map(headers_map, fn {k, v} -> [k, ": ", v, "\r\n"] end)

    [method, " ", url, " HTTP/1.1\r\n", header_iodata, "\r\n", body_iodata || ""]
  end

  defp ordered_requests(%__MODULE__{ops: ops}), do: Enum.reverse(ops)

  defp has_mutation?(requests), do: Enum.any?(requests, &mutation_request?/1)

  defp mutation_request?(req) when is_map(req) do
    extract_method(req) not in ["GET", "HEAD", "OPTIONS"]
  end

  defp extract_method(r) when is_map(r) do
    (r["method"] || r[:method] || "GET")
    |> to_string()
    |> String.upcase()
  end

  defp normalize_raw_request(req) when is_map(req) do
    normalized =
      Enum.reduce(req, %{}, fn
        {:atomicity_group, v}, acc -> Map.put(acc, "atomicityGroup", v)
        {:method, v}, acc -> Map.put(acc, "method", v |> to_string() |> String.upcase())
        {"method", v}, acc -> Map.put(acc, "method", v |> to_string() |> String.upcase())
        {k, v}, acc -> Map.put(acc, to_string(k), v)
      end)

    url = validate_batch_url!(normalized["url"])

    if Map.has_key?(normalized, "id") and not is_nil(normalized["id"]) do
      validate_item_id!(normalized["id"])
    end

    case normalized["atomicityGroup"] do
      nil -> :ok
      "" -> :ok
      group -> validate_boundary!("atomicity_group", group)
    end

    Map.put(normalized, "url", url)
  end

  defp resolve_batch_boundary!(opts) do
    case Keyword.fetch(opts, :boundary) do
      {:ok, nil} -> "batch_#{random_id()}"
      {:ok, boundary} -> validate_boundary!("boundary", boundary)
      :error -> "batch_#{random_id()}"
    end
  end

  defp validate_boundary!(name, boundary) when is_binary(boundary) do
    if boundary == "" or byte_size(boundary) > 70 or
         not Regex.match?(~r/^[A-Za-z0-9_.-]+$/, boundary) do
      raise ArgumentError,
            "invalid #{name} #{inspect(boundary)}: expected non-empty ASCII token [A-Za-z0-9_.-] of at most 70 bytes"
    end

    boundary
  end

  defp validate_boundary!(name, other) do
    raise ArgumentError, "invalid #{name}: expected string, got #{inspect(other)}"
  end

  defp validate_batch_url!(url) when is_binary(url) do
    trimmed = String.trim(url)
    down = String.downcase(trimmed)
    trimmed_no_slash = String.trim_leading(down, "/")

    if trimmed == "" or String.contains?(url, ["\r", "\n", "..", "://"]) or
         String.starts_with?(trimmed, "//") or String.contains?(down, "%2e%2e") or
         String.contains?(down, "/0/rest/") or String.starts_with?(trimmed_no_slash, "0/rest/") or
         trimmed_no_slash == "0/rest" do
      raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
    end

    url
  end

  defp validate_batch_url!(other) do
    raise ArgumentError, "invalid batch sub-request URL: expected string, got #{inspect(other)}"
  end

  defp validate_item_id!(id) do
    id_str = to_string(id)

    if String.contains?(id_str, ["\r", "\n"]) do
      raise ArgumentError, "invalid batch item id: contains CR/LF characters"
    end

    id_str
  end

  defp build_prefer(continue_on_error?, return_pref) do
    prefs = []
    prefs = if continue_on_error?, do: ["continue-on-error" | prefs], else: prefs

    prefs =
      case return_pref do
        :minimal -> ["return=minimal" | prefs]
        :representation -> ["return=representation" | prefs]
        _ -> prefs
      end

    case Enum.reverse(prefs) do
      [] -> nil
      list -> Enum.join(list, ", ")
    end
  end

  defp maybe_put_body_content_type(headers, nil), do: headers

  defp maybe_put_body_content_type(headers, _body) do
    Map.put(
      headers,
      "Content-Type",
      "application/json; odata.metadata=minimal; IEEE754Compatible=true"
    )
  end

  defp maybe_put_content_id(headers, nil), do: headers

  defp maybe_put_content_id(headers, id) do
    if Enum.any?(headers, fn {k, _} -> String.downcase(k) == "content-id" end) do
      headers
    else
      Map.put(headers, "Content-ID", to_string(id))
    end
  end

  defp merge_headers_case_insensitive(base, nil), do: base

  defp merge_headers_case_insensitive(base, overrides) do
    Enum.reduce(overrides, base, fn {k, v}, acc ->
      key_str = to_string(k)
      down = String.downcase(key_str)

      acc
      |> Map.reject(fn {existing_k, _} -> String.downcase(existing_k) == down end)
      |> Map.put(key_str, to_string(v))
    end)
  end

  defp parse_status_code(s) when is_integer(s), do: s

  defp parse_status_code(s) when is_binary(s) do
    case Integer.parse(s) do
      {int, _} -> int
      _ -> s
    end
  end

  defp parse_status_code(other), do: other

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

  defp extract_boundary(str) when is_binary(str) do
    case Regex.run(~r/(?:^|\r?\n)--([A-Za-z0-9_.-]+)/, str) do
      [_, boundary] -> clean_boundary_str(boundary)
      _ -> extract_boundary_from_header(str)
    end
  end

  defp extract_boundary_from_header(header) when is_binary(header) do
    case Regex.run(~r/boundary="?([^";\s\r\n]+)"?/i, header) do
      [_, boundary] -> clean_boundary_str(boundary)
      _ -> nil
    end
  end

  defp clean_boundary_str(boundary) do
    boundary |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  defp get_resp_content_type(%Req.Response{headers: headers}) when is_map(headers) do
    case headers["content-type"] || headers["Content-Type"] || "" do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> ""
    end
  end

  defp random_id do
    6 |> :crypto.strong_rand_bytes() |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp maybe_put_req_header(req, _key, nil), do: req
  defp maybe_put_req_header(req, key, val), do: Req.Request.put_header(req, key, val)
end
