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

  alias Creatio.Batch.Response
  alias Creatio.{Client, Error, Telemetry, Util, Validation}

  defstruct ops: [], count: 0, continue_on_error: false, return: nil

  @opaque t :: %__MODULE__{
            ops: [map()],
            count: non_neg_integer(),
            continue_on_error: boolean(),
            return: :minimal | :representation | nil
          }

  @type payload ::
          t()
          | %{required(:requests) => [map()]}
          | %{required(String.t()) => [map()]}
          | [map()]
          | binary()

  defguardp is_record_id(id)
            when is_binary(id) or is_integer(id) or
                   (is_atom(id) and id not in [nil, true, false])

  @doc """
  Initializes a new batch request.

  ## Options

    * `:continue_on_error` - boolean. If `true`, adds header `Prefer: continue-on-error`.
    * `:return` - `:minimal` or `:representation`. Sets `Prefer: return=minimal` or `return=representation`.
  """
  @spec new() :: t()
  @spec new(Creatio.opts()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      continue_on_error: Util.get_opt(opts, :continue_on_error, false) == true,
      return: Util.get_opt(opts, :return)
    }
  end

  @doc """
  Adds a generic request to the batch.
  """
  @spec add(t(), String.t() | atom(), String.t()) :: t()
  @spec add(t(), String.t() | atom(), String.t(), Creatio.opts()) :: t()
  def add(%__MODULE__{} = batch, method, url, opts \\ []) do
    method_str = validate_http_method!(method)
    url = validate_batch_url!(url)
    url = if method_str == "GET", do: append_odata_query(url, opts), else: url

    next_count = batch.count + 1
    id = Util.get_opt(opts, :id) || "req_#{next_count}"
    id_str = validate_item_id!(id)
    body = Util.get_opt(opts, :body)

    atomicity_group =
      if method_str in ["GET", "HEAD", "OPTIONS"] do
        nil
      else
        case Util.get_opt(opts, :atomicity_group) do
          nil -> nil
          group -> validate_atomicity_group!(group)
        end
      end

    ensure_contiguous_atomicity_group!(batch.ops, atomicity_group)

    prefer =
      build_prefer(
        resolve_continue_on_error(batch, opts),
        Util.get_opt(opts, :return, batch.return)
      )

    base_headers =
      %{
        "Accept" => "application/json; odata.metadata=minimal"
      }
      |> maybe_put_body_content_type(body)
      |> maybe_put("Prefer", prefer)

    headers = merge_headers_case_insensitive(base_headers, Util.get_opt(opts, :headers))

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
  - An entity collection or path: `add_get(batch, "Contact")` or `add_get(batch, "Contact", select: ["Id", "Name"])`
  - A single entity by ID: `add_get(batch, "Contact", "some-uuid")` or `add_get(batch, "Contact", "some-uuid", select: ["Id"])`
  """
  @spec add_get(t(), String.t()) :: t()
  @spec add_get(t(), String.t(), Creatio.opts() | Creatio.record_id()) :: t()
  def add_get(batch, entity_or_path, opts_or_id \\ [])

  def add_get(%__MODULE__{} = batch, entity_or_path, opts)
      when is_binary(entity_or_path) and (is_list(opts) or is_map(opts)) do
    add(batch, "GET", entity_or_path, opts)
  end

  def add_get(%__MODULE__{} = batch, entity, id)
      when is_binary(entity) and is_record_id(id) do
    add(batch, "GET", build_entity_key_url!(entity, id, "add_get/3"), [])
  end

  @doc """
  Adds a single entity retrieval operation with options to the batch.
  """
  @spec add_get(t(), String.t(), Creatio.record_id(), Creatio.opts()) :: t()
  def add_get(%__MODULE__{} = batch, entity, id, opts)
      when is_binary(entity) and is_record_id(id) and (is_list(opts) or is_map(opts)) do
    add(batch, "GET", build_entity_key_url!(entity, id, "add_get/4"), opts)
  end

  @doc """
  Adds an entity creation operation (`POST /0/odata/{Entity}`) to the batch.
  """
  @spec add_create(t(), String.t(), map()) :: t()
  @spec add_create(t(), String.t(), map(), Creatio.opts()) :: t()
  def add_create(%__MODULE__{} = batch, entity, attrs, opts \\ []) do
    entity = Util.require_entity_name!(entity, "add_create/4")
    add(batch, "POST", entity, Util.put_opt(opts, :body, attrs))
  end

  @doc """
  Adds an entity update operation (`PATCH /0/odata/{Entity}({id})`, or `PATCH $1` for Content-ID references) to the batch.
  """
  @spec add_update(t(), String.t(), map()) :: t()
  @spec add_update(t(), String.t(), Creatio.record_id() | map() | nil, map() | Creatio.opts()) ::
          t()
  @spec add_update(t(), String.t(), Creatio.record_id() | nil, map(), Creatio.opts()) :: t()
  def add_update(%__MODULE__{} = batch, ref, attrs)
      when is_binary(ref) and is_map(attrs) do
    url = validate_content_id_ref!(ref, "add_update/3")
    add(batch, "PATCH", url, Util.put_opt([], :body, attrs))
  end

  def add_update(%__MODULE__{} = batch, ref, attrs, opts)
      when is_binary(ref) and is_map(attrs) and (is_list(opts) or is_map(opts)) do
    url = validate_content_id_ref!(ref, "add_update/4")
    add(batch, "PATCH", url, Util.put_opt(opts, :body, attrs))
  end

  def add_update(%__MODULE__{} = batch, entity, id, attrs) do
    add_update(batch, entity, id, attrs, [])
  end

  def add_update(%__MODULE__{} = batch, ref, nil, attrs, opts)
      when is_binary(ref) and is_map(attrs) do
    url = validate_content_id_ref!(ref, "add_update/5")
    add(batch, "PATCH", url, Util.put_opt(opts, :body, attrs))
  end

  def add_update(%__MODULE__{} = batch, entity, id, attrs, opts) do
    add(
      batch,
      "PATCH",
      build_entity_key_url!(entity, id, "add_update/5"),
      Util.put_opt(opts, :body, attrs)
    )
  end

  @doc """
  Adds an entity deletion operation (`DELETE /0/odata/{Entity}({id})`, or `DELETE $1` for Content-ID references) to the batch.
  """
  @spec add_delete(t(), String.t()) :: t()
  @spec add_delete(t(), String.t(), Creatio.record_id() | Creatio.opts() | nil) :: t()
  @spec add_delete(t(), String.t(), Creatio.record_id() | nil, Creatio.opts()) :: t()
  def add_delete(%__MODULE__{} = batch, ref) when is_binary(ref) do
    url = validate_content_id_ref!(ref, "add_delete/2")
    add(batch, "DELETE", url, [])
  end

  def add_delete(%__MODULE__{} = batch, ref, opts)
      when is_binary(ref) and (is_list(opts) or is_map(opts)) do
    url = validate_content_id_ref!(ref, "add_delete/3")
    add(batch, "DELETE", url, opts)
  end

  def add_delete(%__MODULE__{} = batch, entity, id) do
    add_delete(batch, entity, id, [])
  end

  def add_delete(%__MODULE__{} = batch, ref, nil, opts) when is_binary(ref) do
    url = validate_content_id_ref!(ref, "add_delete/4")
    add(batch, "DELETE", url, opts)
  end

  def add_delete(%__MODULE__{} = batch, entity, id, opts) do
    add(batch, "DELETE", build_entity_key_url!(entity, id, "add_delete/4"), opts)
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
  @spec to_multipart_iodata(t()) :: {String.t(), iodata()}
  @spec to_multipart_iodata(t(), Creatio.opts()) :: {String.t(), iodata()}
  def to_multipart_iodata(%__MODULE__{} = batch, opts \\ []) do
    batch_boundary = resolve_batch_boundary!(opts)
    requests = ordered_requests(batch)
    parts = build_multipart_iodata(requests, batch_boundary)
    {batch_boundary, wrap_multipart_body(parts, batch_boundary)}
  end

  @doc """
  Serializes the batch to a multipart/mixed MIME body string.
  Returns `{boundary, body}`.
  """
  @spec to_multipart(t()) :: {String.t(), String.t()}
  @spec to_multipart(t(), Creatio.opts()) :: {String.t(), String.t()}
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
    * `:req_options` - Extra `Req` options forwarded to the request.

  When the client is in read-only mode (`client.read_only == true`), batches containing
  mutation requests (POST, PATCH, PUT, DELETE) or binary batch payloads are rejected with
  `{:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}}`.
  """
  @spec execute(Client.t() | Req.Request.t(), payload()) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  @spec execute(Client.t() | Req.Request.t(), payload(), Creatio.opts()) ::
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
          resolve_continue_on_error(batch, opts),
          Util.get_opt(opts, :return, batch.return),
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
        normalized =
          requests
          |> Enum.with_index(1)
          |> Enum.map(fn {req, idx} -> normalize_raw_request(req, idx) end)

        validate_contiguous_atomicity_groups!(normalized)

        do_execute_requests(
          client,
          normalized,
          Util.get_opt(opts, :continue_on_error, false),
          Util.get_opt(opts, :return),
          format,
          opts
        )
      end
    )
  end

  def execute(client_or_req, body, opts) when is_binary(body) do
    format = validate_batch_format!(opts, :multipart)
    client = Client.ensure_client(client_or_req)
    raw_url = Util.get_opt(opts, :url, "/0/odata/$batch")
    url = Util.validate_crm_url!(raw_url, client.base_url, "batch endpoint URL")

    operation_count =
      case format do
        :json -> count_json_operations(body)
        :multipart -> count_multipart_operations(body)
      end

    Telemetry.span(
      :batch,
      %{format: format, operation_count: operation_count, base_url: client.base_url},
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
          prefer =
            build_prefer(
              Util.get_opt(opts, :continue_on_error, false),
              Util.get_opt(opts, :return)
            )

          content_type =
            case format do
              :json ->
                "application/json; odata.metadata=minimal; IEEE754Compatible=true"

              :multipart ->
                boundary =
                  case Util.get_opt(opts, :boundary) do
                    nil -> extract_boundary(body) || "batch_default"
                    b -> validate_boundary!("boundary", b)
                  end
                  |> then(&validate_boundary!("boundary", &1))

                "multipart/mixed; boundary=#{boundary}; IEEE754Compatible=true"
            end

          base_req =
            client.req
            |> Req.Request.put_header("content-type", content_type)
            |> Req.Request.put_header("accept", "application/json")
            |> maybe_put_req_header("prefer", prefer)

          {req, req_opts} =
            Util.prepare_req_call(
              base_req,
              opts,
              [url: url, body: body],
              %{},
              [:url, :method, :json, :body]
            )

          Req.post(req, req_opts)
          |> handle_batch_response()
        end
      end
    )
  end

  defp do_execute_requests(client, requests, continue_on_error?, return_pref, format, opts) do
    raw_url = Util.get_opt(opts, :url, "/0/odata/$batch")
    url = Util.validate_crm_url!(raw_url, client.base_url, "batch endpoint URL")

    if client.read_only and has_mutation?(requests) do
      {:error,
       Error.new(
         status: 403,
         code: "ReadOnlyMode",
         message: "Client is in read-only mode. Batch contains mutation requests."
       )}
    else
      prefer = build_prefer(continue_on_error?, return_pref)

      case format do
        :multipart -> execute_multipart(client, requests, url, prefer, opts)
        :json -> execute_json(client, requests, url, prefer, opts)
      end
    end
  end

  defp validate_batch_format!(opts, default) do
    case Util.get_opt(opts, :format, default) do
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

  defp count_json_operations(body) when is_binary(body) do
    case Jason.decode(String.trim_leading(body, "\uFEFF")) do
      {:ok, %{"requests" => reqs}} when is_list(reqs) -> length(reqs)
      _ -> 0
    end
  end

  defp execute_json(client, requests, url, prefer, opts) do
    base_req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "application/json; odata.metadata=minimal; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> maybe_put_req_header("prefer", prefer)

    {req, req_opts} =
      Util.prepare_req_call(
        base_req,
        opts,
        [url: url, json: %{"requests" => requests}],
        %{},
        [:url, :method, :json, :body]
      )

    Req.post(req, req_opts)
    |> handle_batch_response()
  end

  defp execute_multipart(client, requests, url, prefer, opts) do
    batch_boundary = resolve_batch_boundary!(opts)
    parts = build_multipart_iodata(requests, batch_boundary)
    iodata = wrap_multipart_body(parts, batch_boundary)

    base_req =
      client.req
      |> Req.Request.put_header(
        "content-type",
        "multipart/mixed; boundary=#{batch_boundary}; IEEE754Compatible=true"
      )
      |> Req.Request.put_header("accept", "application/json")
      |> maybe_put_req_header("prefer", prefer)

    {req, req_opts} =
      Util.prepare_req_call(
        base_req,
        opts,
        [url: url, body: iodata],
        %{},
        [:url, :method, :json, :body]
      )

    Req.post(req, req_opts)
    |> handle_batch_response()
  end

  defp wrap_multipart_body([], batch_boundary), do: ["--", batch_boundary, "--\r\n"]

  defp wrap_multipart_body(parts, batch_boundary) do
    [Enum.intersperse(parts, "\r\n"), "\r\n--", batch_boundary, "--\r\n"]
  end

  defp handle_batch_response({:ok, %Req.Response{status: status} = raw_resp})
       when status in 200..299 do
    case Util.decode_api_response(raw_resp) do
      {:html_or_xml, resp} ->
        content_type = resp |> get_resp_content_type() |> String.downcase()

        if String.contains?(content_type, "multipart/mixed") and is_binary(resp.body) do
          parse_multipart_with_resp(resp, extract_boundary_from_header(content_type))
        else
          {:error, Error.from_response(resp)}
        end

      {:ok, %Req.Response{body: %{"responses" => _}} = resp} ->
        parse_json_batch_response(resp)

      {:ok, %Req.Response{body: resp_body} = resp} when is_binary(resp_body) ->
        content_type = resp |> get_resp_content_type() |> String.downcase()

        cond do
          String.contains?(content_type, "multipart/mixed") ->
            parse_multipart_with_resp(resp, extract_boundary_from_header(content_type))

          Util.blank_body?(resp_body) ->
            {:ok, []}

          true ->
            parse_json_batch_response(resp)
        end

      {:ok, %Req.Response{body: %{}} = resp} ->
        parse_json_batch_response(resp)

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_batch_response({:ok, %Req.Response{} = resp}) do
    {:error, Error.from_response(resp)}
  end

  defp handle_batch_response({:error, exception}) do
    Error.wrap_error(exception)
  end

  defp parse_multipart_with_resp(%Req.Response{} = resp, boundary) do
    case parse_multipart_response(resp.body, boundary) do
      {:ok, responses} ->
        {:ok, responses}

      {:error, %Error{} = err} ->
        {:error,
         %Error{
           err
           | status: err.status || resp.status,
             response: err.response || Error.from_response(resp).response
         }}
    end
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
          parse_multipart_with_resp(%Req.Response{resp | body: cleaned_body}, nil)
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
    if Util.error_payload?(entity) do
      {:error, Error.from_response(resp)}
    else
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
  end

  @doc """
  Parses a multipart/mixed MIME response body into a list of `%Creatio.Batch.Response{}` structs.
  """
  @spec parse_multipart_response(String.t()) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  @spec parse_multipart_response(String.t(), String.t() | nil) ::
          {:ok, [Response.t()]} | {:error, Error.t()}
  def parse_multipart_response(body, boundary \\ nil) when is_binary(body) do
    if Util.html_or_xml_markup?(%Req.Response{body: body}) do
      {:error,
       Error.new(
         message: "Unexpected HTML/XML response in multipart batch",
         details: :binary.copy(body)
       )}
    else
      detected_boundary =
        if is_binary(boundary) and String.trim(boundary) != "" do
          clean_boundary_str(boundary)
        else
          extract_boundary(body)
        end

      cond do
        not is_binary(detected_boundary) or detected_boundary == "" ->
          if String.starts_with?(String.trim_leading(body), "--") do
            {:error,
             Error.new(
               message: "Malformed multipart batch response: missing or invalid boundary",
               details: :binary.copy(body)
             )}
          else
            {:ok, []}
          end

        true ->
          do_parse_multipart(body, detected_boundary, nil)
      end
    end
  end

  defp do_parse_multipart(body, boundary, current_group) do
    if has_closing_boundary?(body, boundary) do
      body
      |> Validation.split_multipart_parts(boundary)
      |> Enum.reduce_while({:ok, []}, fn raw_part, {:ok, acc} ->
        case parse_multipart_part(raw_part, current_group) do
          {:ok, items} -> {:cont, {:ok, Enum.reverse(items, acc)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, rev_items} -> {:ok, Enum.reverse(rev_items)}
        {:error, _} = err -> err
      end
    else
      {:error,
       Error.new(
         message:
           "Malformed or truncated multipart batch response: missing closing boundary --#{boundary}--",
         details: :binary.copy(body)
       )}
    end
  end

  defp has_closing_boundary?(body, boundary) do
    Regex.match?(
      ~r/(?:\r\n|\n|\A)--#{Regex.escape(boundary)}--[ \t]*(?=\r\n|\n|\z)/,
      body
    )
  end

  defp parse_multipart_part(raw_part, current_group) do
    part = strip_part_crlf(raw_part)

    if part == "" or String.starts_with?(part, "--") do
      {:ok, []}
    else
      {mime_head, mime_body} = split_blank_line(part)
      mime_headers = parse_headers(mime_head)
      mime_ct = mime_headers["content-type"] || ""

      if String.contains?(String.downcase(mime_ct), "multipart/mixed") do
        case extract_boundary_from_header(mime_ct) do
          nil ->
            {:error, Error.new(message: "Malformed nested multipart changeset: missing boundary")}

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
              cleaned_json = http_body |> String.trim_leading("\uFEFF") |> String.trim_leading()

              case Jason.decode(cleaned_json, strings: :copy) do
                {:ok, json} -> json
                _ -> :binary.copy(http_body)
              end

            true ->
              :binary.copy(http_body)
          end

        {:ok,
         [
           %Response{
             id: id,
             status: status,
             headers: headers,
             body: parsed_body,
             atomicity_group: current_group && :binary.copy(current_group)
           }
         ]}

      :error ->
        {:error,
         Error.new(
           message: "Malformed HTTP response part in multipart batch: #{inspect(status_line)}"
         )}
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
        cs_boundary = build_single_op_boundary(req["id"] || req[:id])
        format_changeset_iodata(cs_boundary, [req], batch_boundary)

      {:group, group_name} ->
        group_reqs = group_buckets |> Map.fetch!(group_name) |> Enum.reverse()
        build_changeset_iodata(group_name, group_reqs, batch_boundary)
    end)
  end

  defp build_single_op_boundary(id) do
    suffix = random_id()

    safe_prefix =
      id
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.slice(0, 32)
      |> String.trim("_")

    if safe_prefix == "" do
      "changeset_op_#{suffix}"
    else
      "changeset_op_#{safe_prefix}_#{suffix}"
    end
  end

  defp build_changeset_iodata(group_name, reqs, batch_boundary) do
    validate_atomicity_group!(group_name)
    cs_boundary = "changeset_#{group_name}_#{random_id()}"
    validate_boundary!("changeset boundary", cs_boundary)
    format_changeset_iodata(cs_boundary, reqs, batch_boundary)
  end

  defp format_changeset_iodata(cs_boundary, reqs, batch_boundary) do
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
    method = validate_http_method!(extract_method(req))
    url = validate_batch_url!(to_string(req["url"] || req[:url] || ""))
    id = req["id"] || req[:id]
    if not is_nil(id), do: validate_item_id!(id)
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

  defp normalize_raw_request(req, idx) when is_map(req) do
    normalized =
      Enum.reduce(req, %{}, fn
        {:atomicity_group, v}, acc -> Map.put(acc, "atomicityGroup", v)
        {:method, nil}, acc -> Map.put(acc, "method", nil)
        {"method", nil}, acc -> Map.put(acc, "method", nil)
        {:method, v}, acc -> Map.put(acc, "method", validate_http_method!(v))
        {"method", v}, acc -> Map.put(acc, "method", validate_http_method!(v))
        {k, v}, acc -> Map.put(acc, to_string(k), v)
      end)

    method = validate_http_method!(normalized["method"] || "GET")
    url = validate_batch_url!(normalized["url"])

    id_str =
      case normalized["id"] do
        nil -> "req_#{idx}"
        "" -> "req_#{idx}"
        id -> validate_item_id!(id)
      end

    case normalized["atomicityGroup"] do
      nil -> :ok
      "" -> :ok
      group -> validate_atomicity_group!(group)
    end

    normalized =
      if method in ["GET", "HEAD", "OPTIONS"] or normalized["atomicityGroup"] == "" do
        Map.delete(normalized, "atomicityGroup")
      else
        normalized
      end

    base_headers =
      %{"Accept" => "application/json; odata.metadata=minimal"}
      |> maybe_put_body_content_type(normalized["body"])

    headers = merge_headers_case_insensitive(base_headers, normalized["headers"])

    normalized
    |> Map.put("id", id_str)
    |> Map.put("method", method)
    |> Map.put("url", url)
    |> Map.put("headers", headers)
  end

  defp build_entity_key_url!(entity, id, fun_name) do
    entity = Util.require_entity_name!(entity, fun_name)

    key_segment =
      if is_binary(id) and single_content_id_ref?(id) do
        String.trim(id)
      else
        Util.format_record_key(id, :odata4)
      end

    "#{entity}(#{key_segment})"
  end

  defp validate_content_id_ref!(ref, fun_name) when is_binary(ref) do
    trimmed = String.trim(ref)

    if trimmed != "" and not String.contains?(trimmed, "..") and
         Regex.match?(~r/\A\$[A-Za-z0-9_.-]+(?:\/[A-Za-z_][A-Za-z0-9_]*)*\z/, trimmed) do
      trimmed
    else
      raise ArgumentError,
            "invalid Content-ID reference #{inspect(ref)} in #{fun_name}; expected \"$id\" or valid entity name"
    end
  end

  defp single_content_id_ref?(id) when is_binary(id) do
    trimmed = String.trim(id)

    trimmed != "" and not String.contains?(trimmed, "..") and
      Regex.match?(~r/\A\$[A-Za-z0-9_.-]+\z/, trimmed)
  end

  defp ensure_contiguous_atomicity_group!(_ops_rev, nil), do: :ok

  defp ensure_contiguous_atomicity_group!(ops_rev, group) do
    prev_group =
      case ops_rev do
        [prev | _] -> Map.get(prev, "atomicityGroup")
        _ -> nil
      end

    if prev_group != group and Enum.any?(ops_rev, &(Map.get(&1, "atomicityGroup") == group)) do
      raise ArgumentError,
            "atomicity_group #{inspect(group)} operations must be contiguous (cannot interleave other requests or groups)"
    end

    :ok
  end

  defp validate_contiguous_atomicity_groups!(requests) do
    do_validate_contiguous_atomicity_groups!(requests, [])
  end

  defp do_validate_contiguous_atomicity_groups!([], _seen_rev), do: :ok

  defp do_validate_contiguous_atomicity_groups!([req | rest], seen_rev) do
    group = Map.get(req, "atomicityGroup")
    ensure_contiguous_atomicity_group!(seen_rev, group)
    do_validate_contiguous_atomicity_groups!(rest, [req | seen_rev])
  end

  defp resolve_batch_boundary!(opts) do
    case Util.get_opt(opts, :boundary) do
      nil -> "batch_#{random_id()}"
      boundary -> validate_boundary!("boundary", boundary)
    end
  end

  defp validate_atomicity_group!(group) when is_binary(group) do
    if group == "" or byte_size(group) > 49 or
         not Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, group) do
      raise ArgumentError,
            "invalid atomicity_group #{inspect(group)}: expected non-empty ASCII token [A-Za-z0-9_.-] of at most 49 bytes"
    end

    group
  end

  defp validate_atomicity_group!(other) do
    raise ArgumentError, "invalid atomicity_group: expected string, got #{inspect(other)}"
  end

  defp validate_boundary!(name, boundary) when is_binary(boundary) do
    if boundary == "" or byte_size(boundary) > 70 or
         not Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, boundary) do
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

    if trimmed == "" or Regex.match?(~r/\s/, trimmed) or
         String.contains?(url, ["\r", "\n", <<0>>, "://"]) or
         String.starts_with?(trimmed, ["//", "\\"]) do
      raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
    end

    authority_and_path = trimmed |> String.split(["?", "#"], parts: 2) |> hd()

    if String.contains?(authority_and_path, "\\") do
      raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
    end

    uri = URI.parse(trimmed)

    if not is_nil(uri.scheme) or not is_nil(uri.host) do
      raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
    end

    case Util.safe_normalized_path(uri.path || "") do
      {:ok, norm_path} ->
        down = String.downcase(norm_path)
        trimmed_no_slash = String.trim_leading(down, "/")

        if String.contains?(down, "/0/rest/") or String.starts_with?(trimmed_no_slash, "0/rest/") or
             trimmed_no_slash == "0/rest" do
          raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
        end

        trimmed

      {:error, :invalid_path} ->
        raise ArgumentError, "invalid batch sub-request URL: #{inspect(url)}"
    end
  end

  defp validate_batch_url!(other) do
    raise ArgumentError, "invalid batch sub-request URL: expected string, got #{inspect(other)}"
  end

  defp validate_http_method!(method) when is_binary(method) or is_atom(method) do
    method_str = method |> to_string() |> String.trim() |> String.upcase()

    if method_str == "" or not Regex.match?(~r/\A[A-Z0-9_-]+\z/, method_str) do
      raise ArgumentError, "invalid batch HTTP method: #{inspect(method)}"
    end

    method_str
  end

  defp validate_http_method!(other) do
    raise ArgumentError, "invalid batch HTTP method: #{inspect(other)}"
  end

  defp validate_header_name!(name) do
    if name == "" or not Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) do
      raise ArgumentError, "invalid batch header name: #{inspect(name)}"
    end

    name
  end

  defp validate_header_value!(val) do
    if String.contains?(val, ["\r", "\n", <<0>>]) do
      raise ArgumentError, "invalid batch header value: contains CR/LF/NUL characters"
    end

    val
  end

  @odata_query_opt_keys [
    :select,
    :filter,
    :orderby,
    :order_by,
    :top,
    :skip,
    :expand,
    :count,
    :inlinecount,
    :params,
    "select",
    "filter",
    "orderby",
    "order_by",
    "top",
    "skip",
    "expand",
    "count",
    "inlinecount",
    "params"
  ]

  defp append_odata_query(url, opts) when is_list(opts) or is_map(opts) do
    odata_opts =
      if is_list(opts) do
        Keyword.take(opts, @odata_query_opt_keys)
      else
        Map.take(opts, @odata_query_opt_keys)
      end

    params = Util.normalize_odata_params(odata_opts, %{}, {"$count", "true"})

    if map_size(params) == 0 do
      url
    else
      sep = if String.contains?(url, "?"), do: "&", else: "?"
      "#{url}#{sep}#{URI.encode_query(params)}"
    end
  end

  defp append_odata_query(url, _opts), do: url

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
      key_str = k |> to_string() |> validate_header_name!()
      val_str = v |> to_string() |> validate_header_value!()
      down = String.downcase(key_str)

      acc
      |> Map.reject(fn {existing_k, _} -> String.downcase(existing_k) == down end)
      |> Map.put(key_str, val_str)
    end)
  end

  defp parse_status_code(s) when is_integer(s), do: s

  defp parse_status_code(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {int, ""} -> int
      _ -> s
    end
  end

  defp parse_status_code(other), do: other

  defp resolve_continue_on_error(%__MODULE__{continue_on_error: default}, opts) do
    case Util.get_opt(opts, :continue_on_error) do
      val when is_boolean(val) -> val
      _ -> default
    end
  end

  defp extract_group_name(boundary) do
    case Regex.run(~r/\Achangeset_([A-Za-z0-9_.-]+)_[A-Za-z0-9]+\z/i, boundary) do
      [_, group] ->
        group

      _ ->
        case Regex.run(~r/\Achangeset_([A-Za-z0-9_.-]+)\z/i, boundary) do
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

  defp extract_boundary_from_header(header), do: Validation.extract_boundary_from_header(header)

  defp clean_boundary_str(boundary), do: Validation.clean_boundary_str(boundary)

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
