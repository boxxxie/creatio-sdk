defmodule Creatio.Util do
  @moduledoc false

  alias Creatio.{Client, Error}
  alias Creatio.OData.Query

  @max_creatio_page_size 20_000

  @doc """
  Sanitizes a GUID string case-insensitively by removing `guid'...'`, braces, quotes, and whitespace.
  """
  @spec clean_guid(any()) :: String.t()
  def clean_guid(guid) do
    trimmed = guid |> to_string() |> String.trim()

    unprefixed =
      if byte_size(trimmed) >= 5 and String.downcase(binary_part(trimmed, 0, 5)) == "guid'" do
        trimmed
        |> binary_part(5, byte_size(trimmed) - 5)
        |> String.replace_suffix("'", "")
      else
        trimmed
      end

    unprefixed
    |> String.replace_prefix("{", "")
    |> String.replace_suffix("}", "")
    |> String.replace_prefix("'", "")
    |> String.replace_suffix("'", "")
    |> String.trim()
  end

  @doc """
  Wraps an exception or preserves an existing `%Creatio.Error{}` into `{:error, %Creatio.Error{}}`.
  """
  @spec wrap_error(any()) :: {:error, Error.t()}
  def wrap_error(error_or_exception), do: Error.wrap_error(error_or_exception)

  @doc """
  Retrieves an option from a keyword list or map by atom or string key.
  """
  @spec get_opt(keyword() | map(), atom(), any()) :: any()
  def get_opt(opts, key, default \\ nil)

  def get_opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  def get_opt(opts, key, default) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, val} -> val
      :error -> Map.get(opts, to_string(key), default)
    end
  end

  @doc """
  Extracts the first non-empty header value matching `target_name` case-insensitively.
  """
  @spec response_header(map() | keyword() | [{String.t() | atom(), any()}] | any(), String.t()) ::
          String.t() | nil
  def response_header(headers, target_name) when is_map(headers) and is_binary(target_name) do
    headers
    |> Map.to_list()
    |> response_header(target_name)
  end

  def response_header(headers, target_name) when is_list(headers) and is_binary(target_name) do
    target = String.downcase(target_name)

    Enum.find_value(headers, fn
      {key, val} ->
        if String.downcase(to_string(key)) == target do
          first_header_value(val)
        end

      _ ->
        nil
    end)
  end

  def response_header(_, _), do: nil

  defp first_header_value([val | rest]) do
    case first_header_value(val) do
      nil -> first_header_value(rest)
      found -> found
    end
  end

  defp first_header_value([]), do: nil

  defp first_header_value(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp first_header_value(_), do: nil

  @doc """
  Decodes JSON object or array responses even when Creatio/IIS returns a non-JSON
  content type (such as `text/html; charset=utf-8`) or a leading UTF-8 BOM.
  """
  @spec normalize_json_response(Req.Response.t()) :: Req.Response.t()
  def normalize_json_response(%Req.Response{body: body} = resp) when is_binary(body) do
    trimmed =
      body
      |> String.trim_leading("\uFEFF")
      |> String.trim()

    if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
      case Jason.decode(trimmed) do
        {:ok, decoded} -> %Req.Response{resp | body: decoded}
        _ -> resp
      end
    else
      resp
    end
  end

  def normalize_json_response(%Req.Response{} = resp), do: resp

  @doc """
  Returns `true` when an HTTP response contains an HTML/XML document or WAF interstitial
  (such as an Imperva Incapsula challenge) rather than a valid API payload.
  """
  @spec html_or_xml_response?(Req.Response.t()) :: boolean()
  def html_or_xml_response?(%Req.Response{} = resp) do
    case normalize_json_response(resp) do
      %Req.Response{body: body} when is_map(body) or is_list(body) ->
        false

      %Req.Response{body: body, headers: headers} when is_binary(body) ->
        trimmed_down =
          body
          |> String.trim_leading("\uFEFF")
          |> String.trim_leading()
          |> String.downcase()

        content_type =
          headers
          |> response_header("content-type")
          |> then(&((&1 && String.downcase(&1)) || ""))

        html_prefix? =
          String.starts_with?(trimmed_down, [
            "<!doctype html",
            "<html",
            "<?xml",
            "<iframe",
            "<head",
            "<body",
            "<script"
          ])

        waf_marker? = String.contains?(trimmed_down, "/_incapsula_resource")

        html_ct? =
          trimmed_down != "" and
            String.contains?(content_type, [
              "text/html",
              "application/xhtml",
              "text/xml",
              "application/xml"
            ])

        html_prefix? or waf_marker? or html_ct?

      _ ->
        false
    end
  end

  @doc """
  Normalizes OData query options (keyword list or map) into wire query parameters.
  """
  @spec normalize_odata_params(keyword() | map(), map(), {String.t(), String.t()}) :: map()
  def normalize_odata_params(opts, base_params \\ %{}, count_kv \\ {"$count", "true"})

  def normalize_odata_params(opts, base_params, {count_key, count_val}) when is_list(opts) do
    Enum.reduce(opts, base_params, fn
      {:select, []}, acc ->
        acc

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

      {:expand, []}, acc ->
        acc

      {:expand, val}, acc when is_list(val) ->
        Map.put(acc, "$expand", Enum.map_join(val, ",", &to_string/1))

      {:expand, val}, acc when is_binary(val) or is_atom(val) ->
        Map.put(acc, "$expand", to_string(val))

      {:count, true}, acc ->
        Map.put(acc, count_key, count_val)

      {:count, false}, acc ->
        acc
        |> Map.delete("$count")
        |> Map.delete("$inlinecount")

      {:inlinecount, val}, acc when not is_nil(val) ->
        Map.put(acc, "$inlinecount", to_string(val))

      {:params, map}, acc when is_map(map) ->
        Map.merge(acc, Map.new(map, fn {k, v} -> {to_string(k), v} end))

      {:params, list}, acc when is_list(list) ->
        Enum.reduce(list, acc, fn {k, v}, a -> Map.put(a, to_string(k), to_string(v)) end)

      {key, val}, acc when is_binary(key) and is_list(val) ->
        Map.put(acc, key, Enum.map_join(val, ",", &to_string/1))

      {key, val}, acc when is_binary(key) ->
        Map.put(acc, key, to_string(val))

      _, acc ->
        acc
    end)
  end

  def normalize_odata_params(map, base_params, count_kv) when is_map(map) do
    map
    |> Map.to_list()
    |> normalize_odata_params(base_params, count_kv)
  end

  @doc """
  Shared lazy pagination stream supporting both `$skip` offset pagination and `$skip`-free
  keyset pagination (`cursor_field: "Id"`, `after_cursor: "..."`).

  Emits `{:ok, record}` tuples and yields `{:error, %Creatio.Error{}}` followed by
  halting if a page request or response fails.
  """
  @spec paginate_stream(
          Client.t() | Req.Request.t(),
          String.t() | Query.t(),
          keyword() | map(),
          atom(),
          (Client.t(), String.t() | Query.t(), keyword() ->
             {:ok, list() | map()} | {:error, Error.t()})
        ) :: Enumerable.t()
  def paginate_stream(client_or_req, entity_or_query, opts, protocol \\ :odata4, list_fun) do
    # Resolve %Req.Request{} -> %Client{} once up front instead of once per page
    client = Client.ensure_client(client_or_req)
    opts_kw = if is_map(opts), do: Map.to_list(opts), else: opts

    page_size = opts_kw |> Keyword.get(:page_size, 100) |> parse_non_neg_int(100) |> max(1)
    cursor_field = opts_kw |> Keyword.get(:cursor_field) |> then(&(&1 && to_string(&1)))
    after_cursor = Keyword.get(opts_kw, :after_cursor)

    query_top = if is_binary(entity_or_query), do: nil, else: Query.get_top(entity_or_query)
    query_skip = if is_binary(entity_or_query), do: nil, else: Query.get_skip(entity_or_query)

    max_records =
      case Keyword.get(opts_kw, :max_records) do
        n when is_integer(n) and n >= 0 -> n
        nil when is_integer(query_top) and query_top >= 0 -> query_top
        _ -> nil
      end

    initial_skip =
      cond do
        Keyword.has_key?(opts_kw, :skip) ->
          opts_kw |> Keyword.get(:skip, 0) |> parse_non_neg_int(0)

        is_integer(query_skip) and query_skip >= 0 ->
          query_skip

        true ->
          0
      end

    base_opts =
      Keyword.drop(opts_kw, [
        :page_size,
        :top,
        :skip,
        :count,
        :cursor_field,
        :after_cursor,
        :max_records
      ])

    base_target =
      if is_binary(entity_or_query) do
        entity_or_query
      else
        Query.reset_stream_target(entity_or_query)
      end

    Stream.resource(
      fn ->
        %{
          offset: initial_skip,
          cursor: after_cursor,
          remaining: max_records,
          halt?: max_records == 0
        }
      end,
      fn
        %{halt?: true} ->
          {:halt, nil}

        %{remaining: 0} ->
          {:halt, nil}

        state ->
          fetch_size =
            case state.remaining do
              nil -> page_size
              rem -> min(page_size, rem)
            end

          page_opts =
            build_stream_page_opts(
              base_opts,
              base_target,
              fetch_size,
              cursor_field,
              state,
              protocol
            )

          target = strip_query_filter_if_overridden(base_target, cursor_field)

          case list_fun.(client, target, page_opts) do
            {:ok, records} when is_list(records) ->
              emit_stream_page(records, false, fetch_size, cursor_field, state)

            {:ok, %{records: records} = meta} when is_list(records) ->
              has_next? =
                is_map(meta[:raw]) and
                  (Map.has_key?(meta[:raw], "@odata.nextLink") or
                     Map.has_key?(meta[:raw], "__next"))

              emit_stream_page(records, has_next?, fetch_size, cursor_field, state)

            {:ok, other} ->
              err = Error.new(message: "Unexpected stream page response: #{inspect(other)}")
              {[{:error, err}], %{state | halt?: true}}

            {:error, error} ->
              {[{:error, error}], %{state | halt?: true}}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc """
  Same as `paginate_stream/5`, but unwraps `{:ok, record}` tuples to plain maps
  and raises `%Creatio.Error{}` if a page fetch or response fails.
  """
  @spec paginate_stream!(
          Client.t() | Req.Request.t(),
          String.t() | Query.t(),
          keyword() | map(),
          atom(),
          (Client.t(), String.t() | Query.t(), keyword() ->
             {:ok, list() | map()} | {:error, Error.t()})
        ) :: Enumerable.t()
  def paginate_stream!(client_or_req, entity_or_query, opts, protocol \\ :odata4, list_fun) do
    client_or_req
    |> paginate_stream(entity_or_query, opts, protocol, list_fun)
    |> Stream.map(fn
      {:ok, record} -> record
      {:error, error} -> raise error
    end)
  end

  defp build_stream_page_opts(base_opts, _base_target, fetch_size, nil, state, _protocol) do
    base_opts
    |> Keyword.put(:top, fetch_size)
    |> Keyword.put(:skip, state.offset)
  end

  defp build_stream_page_opts(base_opts, base_target, fetch_size, cursor_field, state, protocol) do
    base_filter =
      if is_binary(base_target) do
        Keyword.get(base_opts, :filter)
      else
        Query.to_params(base_target)["$filter"] || Keyword.get(base_opts, :filter)
      end

    combined_filter =
      case {base_filter, state.cursor} do
        {f, nil} ->
          f

        {nil, cur} ->
          "#{cursor_field} gt #{format_cursor(cur, protocol)}"

        {"", cur} ->
          "#{cursor_field} gt #{format_cursor(cur, protocol)}"

        {f, cur} ->
          "(#{f}) and (#{cursor_field} gt #{format_cursor(cur, protocol)})"
      end

    base_opts
    |> Keyword.put(:top, fetch_size)
    |> Keyword.put(:orderby, "#{cursor_field} asc")
    |> maybe_put_kw(:filter, combined_filter)
  end

  defp strip_query_filter_if_overridden(entity, _cursor_field) when is_binary(entity), do: entity

  defp strip_query_filter_if_overridden(query, cursor_field) when is_binary(cursor_field) do
    Query.strip_filter_and_order(query)
  end

  defp strip_query_filter_if_overridden(other, _cursor_field), do: other

  defp emit_stream_page([], _has_next?, _fetch_size, _cursor_field, _state), do: {:halt, nil}

  defp emit_stream_page(records, has_next?, fetch_size, cursor_field, state) do
    {emitted, next_remaining, cap_reached?} =
      if is_integer(state.remaining) do
        sliced = Enum.take(records, state.remaining)
        new_rem = state.remaining - length(sliced)
        {sliced, new_rem, new_rem <= 0}
      else
        {records, nil, false}
      end

    len = length(emitted)

    if len == 0 do
      {:halt, nil}
    else
      next_cursor = cursor_field && Map.get(List.last(emitted), cursor_field)

      done? =
        cap_reached? or
          (cursor_field != nil and is_nil(next_cursor)) or
          (not has_next? and len < fetch_size and fetch_size <= @max_creatio_page_size)

      wrapped = Enum.map(emitted, &{:ok, &1})

      {wrapped,
       %{
         offset: state.offset + len,
         cursor: next_cursor,
         remaining: next_remaining,
         halt?: done?
       }}
    end
  end

  defp format_cursor(val, protocol) when is_binary(val) do
    cleaned = clean_guid(val)

    if uuid_like?(cleaned) do
      if protocol == :odata3, do: "guid'#{cleaned}'", else: cleaned
    else
      "'#{String.replace(val, "'", "''")}'"
    end
  end

  defp format_cursor(val, _protocol), do: to_string(val)

  defp uuid_like?(bin) when byte_size(bin) == 36 do
    binary_part(bin, 8, 1) == "-" and binary_part(bin, 13, 1) == "-" and
      binary_part(bin, 18, 1) == "-" and binary_part(bin, 23, 1) == "-"
  end

  defp uuid_like?(_), do: false

  defp parse_non_neg_int(val, _default) when is_integer(val) and val >= 0, do: val

  defp parse_non_neg_int(val, default) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, _} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_neg_int(_, default), do: default

  defp maybe_put_kw(kw, _k, nil), do: Keyword.delete(kw, :filter)
  defp maybe_put_kw(kw, _k, ""), do: Keyword.delete(kw, :filter)
  defp maybe_put_kw(kw, k, v), do: Keyword.put(kw, k, v)

  @transport_opt_keys [:into, :headers, :req_options, "into", "headers", "req_options"]

  @doc """
  Executes a `$value` scalar/binary download request while forwarding `:into`, `:headers`,
  `:req_options`, and query options, always enforcing `decode_body: false`.
  """
  @spec fetch_field_value(
          Req.Request.t(),
          String.t(),
          keyword() | map(),
          {String.t(), String.t()}
        ) ::
          {:ok, any()} | {:error, Error.t()}
  def fetch_field_value(%Req.Request{} = req, url, opts, count_kv \\ {"$count", "true"}) do
    {req_with_headers, req_opts} = prepare_field_value_request(req, url, opts, count_kv)

    case Req.get(req_with_headers, req_opts) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc false
  @spec prepare_field_value_request(
          Req.Request.t(),
          String.t(),
          keyword() | map(),
          {String.t(), String.t()}
        ) :: {Req.Request.t(), keyword()}
  def prepare_field_value_request(
        %Req.Request{} = req,
        url,
        opts,
        count_kv \\ {"$count", "true"}
      ) do
    into_sink = get_opt(opts, :into)
    extra_headers = get_opt(opts, :headers)

    raw_req_opts =
      opts
      |> get_opt(:req_options, [])
      |> to_keyword_opts()

    {req_headers, extra_req_opts} = Keyword.pop(raw_req_opts, :headers)
    {req_params, extra_req_opts} = Keyword.pop(extra_req_opts, :params)

    req_with_headers =
      req
      |> maybe_merge_headers(req_headers)
      |> maybe_merge_headers(extra_headers)

    normalized_query =
      opts
      |> drop_transport_opts()
      |> normalize_odata_params(%{}, count_kv)

    merged_params = merge_query_params(req_params, normalized_query)

    enforced_opts =
      [url: url, decode_body: false]
      |> maybe_put_opt(:into, into_sink)
      |> maybe_put_non_empty_params(merged_params)

    {req_with_headers, Keyword.merge(extra_req_opts, enforced_opts)}
  end

  defp drop_transport_opts(opts) when is_map(opts), do: Map.drop(opts, @transport_opt_keys)
  defp drop_transport_opts(opts) when is_list(opts), do: Keyword.drop(opts, @transport_opt_keys)

  defp to_keyword_opts(list) when is_list(list), do: list

  defp to_keyword_opts(map) when is_map(map) do
    Enum.map(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} -> {String.to_existing_atom(to_string(k)), v}
    end)
  end

  defp maybe_merge_headers(req, nil), do: req
  defp maybe_merge_headers(req, []), do: req
  defp maybe_merge_headers(req, headers) when headers == %{}, do: req
  defp maybe_merge_headers(req, headers), do: Req.merge(req, headers: headers)

  defp merge_query_params(nil, query_params), do: query_params

  defp merge_query_params(req_params, query_params)
       when is_map(req_params) or is_list(req_params) do
    req_params
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.merge(query_params)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_non_empty_params(opts, params) when params == %{}, do: opts
  defp maybe_put_non_empty_params(opts, params), do: Keyword.put(opts, :params, params)
end
