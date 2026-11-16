defmodule Creatio.Util do
  @moduledoc false

  alias Creatio.{Client, Error}
  alias Creatio.OData.Query

  @max_creatio_page_size 20_000

  @doc """
  Sanitizes a record ID / GUID string case-insensitively by removing `guid'...'`,
  braces, quotes, and outer whitespace, and rejects path traversal or separator characters.
  """
  @spec clean_guid(any()) :: String.t()
  def clean_guid(guid)
      when is_binary(guid) or is_integer(guid) or
             (is_atom(guid) and guid not in [nil, true, false]) do
    cleaned = strip_guid_syntax(guid)

    if valid_record_id?(cleaned) do
      cleaned
    else
      raise ArgumentError, "invalid record identifier: #{inspect(guid)}"
    end
  end

  def clean_guid(guid) do
    raise ArgumentError, "invalid record identifier: #{inspect(guid)}"
  end

  @doc false
  @spec strip_guid_syntax(any()) :: String.t()
  def strip_guid_syntax(guid) do
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

  defp valid_record_id?(id) when is_binary(id) do
    id != "" and
      id not in [".", ".."] and
      not String.contains?(id, "..") and
      Regex.match?(~r/^[A-Za-z0-9._-]+$/, id)
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
  Validates and trims a Creatio OData entity collection name.
  """
  @spec require_entity_name!(any(), String.t()) :: String.t()
  def require_entity_name!(entity, fun_name) when is_binary(entity) do
    trimmed = String.trim(entity)

    cond do
      trimmed == "" ->
        raise ArgumentError,
              "entity name must be a non-empty binary before calling #{fun_name}"

      Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, trimmed) ->
        trimmed

      true ->
        raise ArgumentError,
              "entity name must be a valid OData identifier before calling #{fun_name}, got: #{inspect(entity)}"
    end
  end

  def require_entity_name!(other, fun_name) do
    raise ArgumentError,
          "entity name must be a non-empty binary before calling #{fun_name}, got: #{inspect(other)}"
  end

  @doc """
  Validates and trims a Creatio OData field or navigation property name.
  """
  @spec require_field_name!(any(), String.t()) :: String.t()
  def require_field_name!(field, fun_name)
      when is_binary(field) or (is_atom(field) and field not in [nil, true, false]) do
    trimmed = field |> to_string() |> String.trim()

    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, trimmed) do
      trimmed
    else
      raise ArgumentError,
            "field name must be a non-empty valid OData identifier before calling #{fun_name}, got: #{inspect(field)}"
    end
  end

  def require_field_name!(other, fun_name) do
    raise ArgumentError,
          "field name must be a non-empty valid OData identifier before calling #{fun_name}, got: #{inspect(other)}"
  end

  @doc """
  Parses a non-negative integer or numeric string count response, preserving HTTP response metadata on failure.
  """
  @spec parse_integer_count(any(), Req.Response.t()) :: {:ok, integer()} | {:error, Error.t()}
  def parse_integer_count(count, _resp) when is_integer(count) and count >= 0, do: {:ok, count}

  def parse_integer_count(count, %Req.Response{} = resp) when is_binary(count) do
    cleaned = count |> String.trim() |> String.trim_leading("\uFEFF") |> String.trim()

    case Integer.parse(cleaned) do
      {int, ""} when int >= 0 ->
        {:ok, int}

      _ ->
        {:error,
         Error.new(
           status: resp.status,
           message: "Failed to parse count response: #{count}",
           response: resp
         )}
    end
  end

  def parse_integer_count(other, %Req.Response{} = resp) do
    {:error,
     Error.new(
       status: resp.status,
       message: "Failed to parse count response: #{inspect(other)}",
       response: resp
     )}
  end

  @doc """
  Validates an HTTP `200`/`201` void mutation response, rejecting HTML/XML WAF pages
  and corrupt/non-empty unexpected payloads.
  """
  @spec ok_void_response(Req.Response.t()) :: :ok | {:error, Error.t()}
  def ok_void_response(%Req.Response{} = raw_resp) do
    resp = normalize_json_response(raw_resp)

    if html_or_xml_response?(resp) do
      {:error, Error.from_response(resp)}
    else
      case resp.body do
        nil ->
          :ok

        bin when is_binary(bin) ->
          if String.trim(bin) == "", do: :ok, else: {:error, Error.from_response(resp)}

        %{"error" => _} ->
          {:error, Error.from_response(resp)}

        %{} ->
          :ok

        _other ->
          {:error, Error.from_response(resp)}
      end
    end
  end

  @doc """
  Decodes JSON object or array responses even when Creatio/IIS returns a non-JSON
  content type (such as `text/html; charset=utf-8`) or a leading UTF-8 BOM.
  """
  @spec normalize_json_response(Req.Response.t()) :: Req.Response.t()
  def normalize_json_response(%Req.Response{body: body} = resp) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    if start < size and :binary.at(body, start) in [?{, ?[] do
      trimmed =
        body
        |> binary_part(start, size - start)
        |> String.trim_trailing()

      case Jason.decode(trimmed) do
        {:ok, decoded} -> %Req.Response{resp | body: decoded}
        _ -> resp
      end
    else
      resp
    end
  end

  def normalize_json_response(%Req.Response{} = resp), do: resp

  @html_xml_prefixes [
    "<!doctype",
    "<html",
    "<?xml",
    "<iframe",
    "<head",
    "<body",
    "<script",
    "<meta",
    "<error",
    "<fault",
    "<service",
    "<feed",
    "<entry"
  ]

  @waf_markers ["_Incapsula_Resource", "_incapsula_resource"]

  @doc """
  Returns `true` when an HTTP response body contains an HTML/XML document prefix or WAF
  interstitial marker regardless of Content-Type.
  """
  @spec html_or_xml_markup?(Req.Response.t()) :: boolean()
  def html_or_xml_markup?(%Req.Response{body: body}) when is_binary(body) do
    prefix_down = leading_prefix_downcase(body)

    prefix_down != "" and
      (String.starts_with?(prefix_down, @html_xml_prefixes) or has_waf_marker?(body))
  end

  def html_or_xml_markup?(_), do: false

  @doc """
  Returns `true` when an HTTP response contains an HTML/XML document or WAF interstitial
  (such as an Imperva Incapsula challenge) rather than a valid API payload.
  """
  @spec html_or_xml_response?(Req.Response.t()) :: boolean()
  def html_or_xml_response?(%Req.Response{body: body}) when is_map(body) or is_list(body),
    do: false

  def html_or_xml_response?(%Req.Response{body: body, headers: headers}) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    if start >= size do
      false
    else
      if :binary.at(body, start) in [?{, ?[] and json_object_or_array?(body, start, size) do
        false
      else
        prefix_down =
          body
          |> binary_part(start, min(size - start, 512))
          |> String.downcase()

        content_type =
          headers
          |> response_header("content-type")
          |> then(&((&1 && String.downcase(&1)) || ""))

        html_ct? =
          String.contains?(content_type, [
            "text/html",
            "application/xhtml",
            "text/xml",
            "application/xml"
          ])

        String.starts_with?(prefix_down, @html_xml_prefixes) or
          has_waf_marker?(body) or
          html_ct?
      end
    end
  end

  def html_or_xml_response?(_), do: false

  defp json_object_or_array?(body, start, size) do
    trimmed =
      body
      |> binary_part(start, size - start)
      |> String.trim_trailing()

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> true
      _ -> false
    end
  end

  defp leading_prefix_downcase(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    if start >= size do
      ""
    else
      body
      |> binary_part(start, min(size - start, 512))
      |> String.downcase()
    end
  end

  defp skip_leading_ws_and_bom(<<0xEF, 0xBB, 0xBF, _::binary>> = body, pos, size) when pos == 0 do
    skip_leading_ws_and_bom(body, 3, size)
  end

  defp skip_leading_ws_and_bom(body, pos, size) when pos < size do
    case :binary.at(body, pos) do
      ws when ws in [?\s, ?\t, ?\r, ?\n, ?\v, ?\f] ->
        skip_leading_ws_and_bom(body, pos + 1, size)

      _ ->
        pos
    end
  end

  defp skip_leading_ws_and_bom(_body, pos, _size), do: pos

  defp has_waf_marker?(body) do
    :binary.match(body, @waf_markers) != :nomatch
  end

  @doc """
  Normalizes OData query options (keyword list or map) into wire query parameters.
  """
  @spec normalize_odata_params(keyword() | map(), map(), {String.t(), String.t()}) :: map()
  def normalize_odata_params(opts, base_params \\ %{}, count_kv \\ {"$count", "true"})

  def normalize_odata_params(opts, base_params, {count_key, count_val}) when is_list(opts) do
    Enum.reduce(opts, base_params, fn {raw_key, val}, acc ->
      case {normalize_odata_opt_key(raw_key), val} do
        {:select, []} ->
          acc

        {:select, list} when is_list(list) ->
          Map.put(acc, "$select", Enum.map_join(list, ",", &to_string/1))

        {:select, bin_or_atom} when is_binary(bin_or_atom) or is_atom(bin_or_atom) ->
          Map.put(acc, "$select", to_string(bin_or_atom))

        {:filter, bin} when is_binary(bin) ->
          Map.put(acc, "$filter", bin)

        {key, order_val} when key in [:orderby, :order_by] ->
          orderby_str = format_orderby_opt(order_val)
          if orderby_str, do: Map.put(acc, "$orderby", orderby_str), else: acc

        {:top, top_val} when not is_nil(top_val) ->
          Map.put(acc, "$top", to_string(top_val))

        {:skip, skip_val} when not is_nil(skip_val) ->
          Map.put(acc, "$skip", to_string(skip_val))

        {:expand, []} ->
          acc

        {:expand, list} when is_list(list) ->
          Map.put(acc, "$expand", Enum.map_join(list, ",", &to_string/1))

        {:expand, bin_or_atom} when is_binary(bin_or_atom) or is_atom(bin_or_atom) ->
          Map.put(acc, "$expand", to_string(bin_or_atom))

        {:count, true} ->
          Map.put(acc, count_key, count_val)

        {:count, false} ->
          acc
          |> Map.delete("$count")
          |> Map.delete("$inlinecount")

        {:inlinecount, ic_val} when not is_nil(ic_val) ->
          Map.put(acc, "$inlinecount", to_string(ic_val))

        {:params, map} when is_map(map) ->
          Map.merge(acc, Map.new(map, fn {k, v} -> {to_string(k), v} end))

        {:params, list} when is_list(list) ->
          Enum.reduce(list, acc, fn {k, v}, a -> Map.put(a, to_string(k), to_string(v)) end)

        {key, list} when is_binary(key) and is_list(list) ->
          Map.put(acc, key, Enum.map_join(list, ",", &to_string/1))

        {key, str_val} when is_binary(key) ->
          Map.put(acc, key, to_string(str_val))

        _ ->
          acc
      end
    end)
  end

  def normalize_odata_params(map, base_params, count_kv) when is_map(map) do
    map
    |> Map.to_list()
    |> normalize_odata_params(base_params, count_kv)
  end

  defp normalize_odata_opt_key("select"), do: :select
  defp normalize_odata_opt_key("filter"), do: :filter
  defp normalize_odata_opt_key("orderby"), do: :orderby
  defp normalize_odata_opt_key("order_by"), do: :order_by
  defp normalize_odata_opt_key("top"), do: :top
  defp normalize_odata_opt_key("skip"), do: :skip
  defp normalize_odata_opt_key("expand"), do: :expand
  defp normalize_odata_opt_key("count"), do: :count
  defp normalize_odata_opt_key("inlinecount"), do: :inlinecount
  defp normalize_odata_opt_key("params"), do: :params
  defp normalize_odata_opt_key(other), do: other

  defp format_orderby_opt(val) when is_list(val) do
    Enum.map_join(val, ",", fn
      {col, dir} -> "#{col} #{dir}"
      col -> to_string(col)
    end)
  end

  defp format_orderby_opt(val) when is_binary(val) or is_atom(val), do: to_string(val)
  defp format_orderby_opt(_), do: nil

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
    opts_kw = normalize_stream_opts(opts)
    page_list_fun = upgrade_stream_list_fun(list_fun)

    page_size = opts_kw |> Keyword.get(:page_size, 100) |> parse_non_neg_int(100) |> max(1)
    cursor_field = opts_kw |> Keyword.get(:cursor_field) |> then(&(&1 && to_string(&1)))
    after_cursor = Keyword.get(opts_kw, :after_cursor)

    query_top = if is_binary(entity_or_query), do: nil, else: Query.get_top(entity_or_query)
    query_skip = if is_binary(entity_or_query), do: nil, else: Query.get_skip(entity_or_query)

    opts_top = resolve_non_neg_opt!(Keyword.get(opts_kw, :top), :top)
    effective_top = opts_top || query_top
    max_records = resolve_max_records!(Keyword.get(opts_kw, :max_records), effective_top)

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
      opts_kw
      |> Keyword.drop([
        :page_size,
        :top,
        :skip,
        :count,
        :inlinecount,
        :cursor_field,
        :after_cursor,
        :max_records
      ])
      |> ensure_cursor_select_in_opts(cursor_field)

    base_target =
      if is_binary(entity_or_query) do
        entity_or_query
      else
        entity_or_query
        |> Query.reset_stream_target()
        |> ensure_cursor_select_in_query(base_opts, cursor_field)
      end

    Stream.resource(
      fn ->
        %{
          offset: initial_skip,
          cursor: after_cursor,
          remaining: max_records,
          next_params: %{},
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

          case page_list_fun.(client, target, page_opts) do
            {:ok, records} when is_list(records) ->
              emit_stream_page(records, nil, fetch_size, cursor_field, state, client)

            {:ok, %{records: records} = meta} when is_list(records) ->
              next_link = extract_next_link(meta[:raw])
              emit_stream_page(records, next_link, fetch_size, cursor_field, state, client)

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

  defp upgrade_stream_list_fun(list_fun) do
    cond do
      list_fun == (&Creatio.OData.list/3) -> &Creatio.OData.list_page/3
      list_fun == (&Creatio.OData3.list/3) -> &Creatio.OData3.list_page/3
      true -> list_fun
    end
  end

  defp extract_next_link(raw) when is_map(raw) do
    candidate =
      Map.get(raw, "@odata.nextLink") ||
        Map.get(raw, "odata.nextLink") ||
        Map.get(raw, "__next") ||
        case Map.get(raw, "d") do
          %{} = d -> Map.get(d, "__next")
          _ -> nil
        end

    if is_binary(candidate) do
      trimmed = String.trim(candidate)
      if trimmed == "", do: nil, else: trimmed
    else
      nil
    end
  end

  defp extract_next_link(_), do: nil

  @stream_known_string_opts %{
    "page_size" => :page_size,
    "cursor_field" => :cursor_field,
    "after_cursor" => :after_cursor,
    "max_records" => :max_records,
    "top" => :top,
    "$top" => :top,
    "skip" => :skip,
    "$skip" => :skip,
    "count" => :count,
    "$count" => :count,
    "inlinecount" => :inlinecount,
    "$inlinecount" => :inlinecount,
    "select" => :select,
    "$select" => :select,
    "filter" => :filter,
    "$filter" => :filter,
    "orderby" => :orderby,
    "order_by" => :orderby,
    "$orderby" => :orderby,
    "expand" => :expand,
    "$expand" => :expand,
    "params" => :params,
    "req_options" => :req_options
  }

  defp normalize_stream_opts(opts) when is_map(opts) do
    opts
    |> Map.to_list()
    |> normalize_stream_opts()
  end

  defp normalize_stream_opts(opts) when is_list(opts) do
    {kw, extra_params} =
      Enum.reduce(opts, {[], %{}}, fn
        {key, val}, {acc_kw, acc_params} when is_atom(key) ->
          normalized_key = if key == :order_by, do: :orderby, else: key

          if normalized_key == :params do
            {acc_kw, merge_extra_params(acc_params, val)}
          else
            {[{normalized_key, val} | acc_kw], acc_params}
          end

        {key, val}, {acc_kw, acc_params} when is_binary(key) ->
          case Map.fetch(@stream_known_string_opts, key) do
            {:ok, :params} ->
              {acc_kw, merge_extra_params(acc_params, val)}

            {:ok, atom_key} ->
              {[{atom_key, val} | acc_kw], acc_params}

            :error ->
              {acc_kw, Map.put(acc_params, key, format_extra_param_val(val))}
          end

        _, acc ->
          acc
      end)

    reversed = Enum.reverse(kw)
    if extra_params == %{}, do: reversed, else: Keyword.put(reversed, :params, extra_params)
  end

  defp normalize_stream_opts(_), do: []

  defp merge_extra_params(acc_params, val) when is_map(val) do
    Map.merge(
      acc_params,
      Map.new(val, fn {k, v} -> {to_string(k), format_extra_param_val(v)} end)
    )
  end

  defp merge_extra_params(acc_params, val) when is_list(val) do
    Enum.reduce(val, acc_params, fn
      {k, v}, a -> Map.put(a, to_string(k), format_extra_param_val(v))
      _, a -> a
    end)
  end

  defp merge_extra_params(acc_params, _val), do: acc_params

  defp format_extra_param_val(val) when is_list(val), do: Enum.map_join(val, ",", &to_string/1)
  defp format_extra_param_val(val), do: to_string(val)

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
    opts_with_top = Keyword.put(base_opts, :top, fetch_size)

    case Map.get(state, :next_params, %{}) do
      next_params when map_size(next_params) > 0 ->
        merged_params = Map.merge(Keyword.get(opts_with_top, :params, %{}), next_params)

        opts_with_top
        |> Keyword.delete(:skip)
        |> Keyword.put(:params, merged_params)

      _ ->
        Keyword.put(opts_with_top, :skip, state.offset)
    end
  end

  defp build_stream_page_opts(base_opts, base_target, fetch_size, cursor_field, state, protocol) do
    query_params = if is_binary(base_target), do: %{}, else: Query.to_params(base_target)
    base_filter = Keyword.get(base_opts, :filter) || query_params["$filter"]

    combined_filter =
      case {base_filter, state.cursor} do
        {f, nil} ->
          f

        {nil, cur} ->
          cursor_predicate(cursor_field, cur, protocol)

        {"", cur} ->
          cursor_predicate(cursor_field, cur, protocol)

        {f, cur} ->
          "(#{f}) and (#{cursor_predicate(cursor_field, cur, protocol)})"
      end

    default_orderby =
      if cursor_field == "Id" do
        "Id asc"
      else
        "#{cursor_field} asc, Id asc"
      end

    orderby = Keyword.get(base_opts, :orderby) || query_params["$orderby"] || default_orderby

    base_opts
    |> Keyword.put(:top, fetch_size)
    |> Keyword.put(:orderby, orderby)
    |> maybe_put_kw(:filter, combined_filter)
  end

  defp ensure_cursor_select_in_opts(opts, nil), do: opts

  defp ensure_cursor_select_in_opts(opts, cursor_field) do
    case Keyword.fetch(opts, :select) do
      :error ->
        opts

      {:ok, select_val} ->
        required = required_cursor_fields(cursor_field)
        Keyword.put(opts, :select, append_missing_fields(select_val, required))
    end
  end

  defp ensure_cursor_select_in_query(query, _opts, nil), do: query

  defp ensure_cursor_select_in_query(query, opts, cursor_field) do
    if Query.has_select?(query) and not Keyword.has_key?(opts, :select) do
      Query.select(query, required_cursor_fields(cursor_field))
    else
      query
    end
  end

  defp required_cursor_fields("Id"), do: ["Id"]
  defp required_cursor_fields(cursor_field), do: [cursor_field, "Id"]

  defp append_missing_fields(select_val, required) when is_list(select_val) do
    existing = Enum.map(select_val, &to_string/1)
    missing = Enum.reject(required, &(&1 in existing))
    select_val ++ missing
  end

  defp append_missing_fields(select_val, required)
       when is_binary(select_val) or is_atom(select_val) do
    parts =
      select_val
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    missing = Enum.reject(required, &(&1 in parts))
    Enum.join(parts ++ missing, ",")
  end

  defp cursor_predicate(cursor_field, {:composite_cursor, cur_val, cur_id}, protocol) do
    build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol)
  end

  defp cursor_predicate(cursor_field, {cur_val, cur_id}, protocol) do
    build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol)
  end

  defp cursor_predicate(cursor_field, cur_val, protocol) do
    "#{cursor_field} gt #{format_cursor(cur_val, protocol)}"
  end

  defp build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol) do
    formatted_val = format_cursor(cur_val, protocol)
    formatted_id = format_cursor(cur_id, protocol)

    "(#{cursor_field} gt #{formatted_val} or (#{cursor_field} eq #{formatted_val} and Id gt #{formatted_id}))"
  end

  defp strip_query_filter_if_overridden(entity, _cursor_field) when is_binary(entity), do: entity

  defp strip_query_filter_if_overridden(query, cursor_field) when is_binary(cursor_field) do
    Query.strip_filter_and_order(query)
  end

  defp strip_query_filter_if_overridden(other, _cursor_field), do: other

  defp emit_stream_page([], _next_link, _fetch_size, _cursor_field, _state, _client),
    do: {:halt, nil}

  defp emit_stream_page(records, next_link, fetch_size, cursor_field, state, client) do
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
      last_record = List.last(emitted)
      cursor_val = cursor_field && is_map(last_record) && Map.get(last_record, cursor_field)

      if cursor_field != nil and is_nil(cursor_val) do
        err =
          Error.new(
            message:
              "Keyset pagination cursor_field #{inspect(cursor_field)} is missing or nil in returned record"
          )

        wrapped = Enum.map(emitted, &{:ok, &1}) ++ [{:error, err}]
        {wrapped, %{state | halt?: true}}
      else
        next_cursor =
          cond do
            is_nil(cursor_field) ->
              nil

            cursor_field != "Id" and is_map(last_record) and
                not is_nil(Map.get(last_record, "Id")) ->
              {:composite_cursor, cursor_val, Map.get(last_record, "Id")}

            true ->
              cursor_val
          end

        has_next? = is_binary(next_link) and next_link != ""

        next_params =
          if is_nil(cursor_field), do: next_link_query_params(next_link, client), else: %{}

        done? =
          cap_reached? or
            (not has_next? and len < min(fetch_size, @max_creatio_page_size))

        wrapped = Enum.map(emitted, &{:ok, &1})

        {wrapped,
         %{
           offset: state.offset + len,
           cursor: next_cursor,
           remaining: next_remaining,
           next_params: next_params,
           halt?: done?
         }}
      end
    end
  end

  defp next_link_query_params(nil, _client), do: %{}

  defp next_link_query_params(next_link, %Client{base_url: base_url}) when is_binary(next_link) do
    case URI.parse(next_link) do
      %URI{scheme: scheme, host: host, port: port, query: query}
      when is_binary(scheme) and is_binary(host) ->
        if same_origin?(base_url, scheme, host, port) do
          extract_next_link_tokens(query)
        else
          %{}
        end

      %URI{query: query} ->
        extract_next_link_tokens(query)
    end
  end

  defp extract_next_link_tokens(nil), do: %{}
  defp extract_next_link_tokens(""), do: %{}

  defp extract_next_link_tokens(query) when is_binary(query) do
    query
    |> URI.decode_query()
    |> Map.take(["$skiptoken", "$deltatoken"])
  end

  defp same_origin?(base_url, scheme, host, port) when is_binary(base_url) and base_url != "" do
    case URI.parse(base_url) do
      %URI{scheme: b_scheme, host: b_host, port: b_port}
      when is_binary(b_scheme) and is_binary(b_host) ->
        String.downcase(b_scheme) == String.downcase(scheme) and
          String.downcase(b_host) == String.downcase(host) and
          (b_port || default_port(b_scheme)) == (port || default_port(scheme))

      _ ->
        false
    end
  end

  defp same_origin?(_, _, _, _), do: false

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_), do: nil

  defp format_cursor(%DateTime{} = val, protocol) do
    iso = DateTime.to_iso8601(val)
    if protocol == :odata3, do: "datetime'#{iso}'", else: iso
  end

  defp format_cursor(%NaiveDateTime{} = val, protocol) do
    iso = NaiveDateTime.to_iso8601(val)
    if protocol == :odata3, do: "datetime'#{iso}'", else: iso <> "Z"
  end

  defp format_cursor(%Date{} = val, protocol) do
    iso = Date.to_iso8601(val)
    if protocol == :odata3, do: "datetime'#{iso}T00:00:00'", else: iso
  end

  defp format_cursor(val, protocol) when is_binary(val) do
    cleaned = strip_guid_syntax(val)

    cond do
      uuid_like?(cleaned) ->
        if protocol == :odata3, do: "guid'#{cleaned}'", else: cleaned

      iso_datetime_like?(val) ->
        if protocol == :odata3, do: "datetime'#{val}'", else: val

      true ->
        "'#{String.replace(val, "'", "''")}'"
    end
  end

  defp format_cursor(val, _protocol), do: to_string(val)

  defp iso_datetime_like?(val) do
    Regex.match?(
      ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?$/,
      val
    )
  end

  defp uuid_like?(bin) when byte_size(bin) == 36 do
    binary_part(bin, 8, 1) == "-" and binary_part(bin, 13, 1) == "-" and
      binary_part(bin, 18, 1) == "-" and binary_part(bin, 23, 1) == "-"
  end

  defp uuid_like?(_), do: false

  defp resolve_non_neg_opt!(nil, _opt_name), do: nil
  defp resolve_non_neg_opt!(n, _opt_name) when is_integer(n) and n >= 0, do: n

  defp resolve_non_neg_opt!(bin, opt_name) when is_binary(bin) do
    case Integer.parse(String.trim(bin)) do
      {int, ""} when int >= 0 ->
        int

      _ ->
        raise ArgumentError,
              "expected :#{opt_name} to be a non-negative integer, got: #{inspect(bin)}"
    end
  end

  defp resolve_non_neg_opt!(other, opt_name) do
    raise ArgumentError,
          "expected :#{opt_name} to be a non-negative integer, got: #{inspect(other)}"
  end

  defp resolve_max_records!(nil, query_top) when is_integer(query_top) and query_top >= 0,
    do: query_top

  defp resolve_max_records!(nil, _query_top), do: nil
  defp resolve_max_records!(n, _query_top), do: resolve_non_neg_opt!(n, :max_records)

  defp parse_non_neg_int(val, _default) when is_integer(val) and val >= 0, do: val

  defp parse_non_neg_int(val, default) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, ""} when int >= 0 -> int
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
    into_sink = Keyword.get(req_opts, :into)

    case execute_field_value_get(req_with_headers, req_opts, into_sink) do
      {:ok, %{status: 204}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body} = resp} when status in [200, 206] ->
        if html_or_xml_response?(resp) do
          {:error, Error.from_response(resp)}
        else
          {:ok, body || ""}
        end

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  defp execute_field_value_get(req, req_opts, sink)
       when not is_nil(sink) and not is_function(sink, 2) and
              sink not in [:self, :legacy_self] do
    run_status_gated_collectable(req, req_opts, sink)
  end

  defp execute_field_value_get(req, req_opts, _sink) do
    Req.get(req, req_opts)
  end

  defp run_status_gated_collectable(req, req_opts, collectable) do
    state_ref = make_ref()

    into_fun = fn {:data, chunk}, {req_acc, %Req.Response{status: status} = resp_acc} ->
      cond do
        status == 204 ->
          {:cont, {req_acc, resp_acc}}

        status in [200, 206] ->
          handle_collectable_chunk(state_ref, collectable, chunk, req_acc, resp_acc)

        true ->
          current_body = if is_binary(resp_acc.body), do: resp_acc.body, else: ""
          {:cont, {req_acc, %Req.Response{resp_acc | body: current_body <> chunk}}}
      end
    end

    try do
      case Req.get(req, Keyword.put(req_opts, :into, into_fun)) do
        {:ok, %Req.Response{status: 204} = resp} ->
          {:ok, resp}

        {:ok, %Req.Response{status: status} = resp} when status in [200, 206] ->
          finalize_gated_collectable(state_ref, collectable, resp)

        other ->
          other
      end
    after
      case Process.delete(state_ref) do
        {:opened, acc, collector} -> collector.(acc, :halt)
        _ -> :ok
      end
    end
  end

  defp handle_collectable_chunk(
         state_ref,
         collectable,
         chunk,
         req_acc,
         %Req.Response{} = resp_acc
       ) do
    case Process.get(state_ref) do
      {:opened, acc, collector} ->
        next_acc = collector.(acc, {:cont, chunk})
        Process.put(state_ref, {:opened, next_acc, collector})
        {:cont, {req_acc, resp_acc}}

      :rejected ->
        current = if is_binary(resp_acc.body), do: resp_acc.body, else: ""
        capped = if byte_size(current) < 65_536, do: current <> chunk, else: current
        {:cont, {req_acc, %Req.Response{resp_acc | body: capped}}}

      pending ->
        buf =
          case pending do
            {:pending, existing} -> existing
            nil -> ""
          end

        combined = buf <> chunk
        probe_resp = %Req.Response{resp_acc | body: combined}

        cond do
          waf_or_html_stream_prefix?(probe_resp, combined) ->
            Process.put(state_ref, :rejected)
            {:cont, {req_acc, %Req.Response{resp_acc | body: combined}}}

          byte_size(combined) >= 1024 ->
            {acc, collector} = Collectable.into(collectable)
            Process.put(state_ref, {:opened, acc, collector})
            next_acc = collector.(acc, {:cont, combined})
            Process.put(state_ref, {:opened, next_acc, collector})
            {:cont, {req_acc, resp_acc}}

          true ->
            Process.put(state_ref, {:pending, combined})
            {:cont, {req_acc, resp_acc}}
        end
    end
  end

  defp finalize_gated_collectable(state_ref, collectable, %Req.Response{} = resp) do
    case Process.delete(state_ref) do
      {:opened, acc, collector} ->
        final_body = collector.(acc, :done)
        {:ok, %Req.Response{resp | body: final_body}}

      :rejected ->
        {:ok, resp}

      {:pending, buf} ->
        probe_resp = %Req.Response{resp | body: buf}

        if html_or_xml_response?(probe_resp) do
          {:ok, probe_resp}
        else
          {acc, collector} = Collectable.into(collectable)

          next_acc =
            try do
              if buf == "", do: acc, else: collector.(acc, {:cont, buf})
            rescue
              exception ->
                collector.(acc, :halt)
                reraise exception, __STACKTRACE__
            end

          final_body = collector.(next_acc, :done)
          {:ok, %Req.Response{resp | body: final_body}}
        end

      nil ->
        {acc, collector} = Collectable.into(collectable)
        final_body = collector.(acc, :done)
        {:ok, %Req.Response{resp | body: final_body}}
    end
  end

  defp waf_or_html_stream_prefix?(%Req.Response{headers: headers} = resp, combined) do
    html_or_xml_markup?(resp) or
      (html_or_xml_content_type?(headers) and not starts_with_json_delimiter?(combined))
  end

  defp html_or_xml_content_type?(headers) do
    ct =
      headers
      |> response_header("content-type")
      |> then(&((&1 && String.downcase(&1)) || ""))

    String.contains?(ct, ["text/html", "application/xhtml", "text/xml", "application/xml"])
  end

  defp starts_with_json_delimiter?(body) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)
    start < size and :binary.at(body, start) in [?{, ?[]
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

    {req_headers_list, extra_req_opts} = Keyword.pop_values(raw_req_opts, :headers)
    {req_params_list, extra_req_opts} = Keyword.pop_values(extra_req_opts, :params)
    extra_req_opts = Keyword.drop(extra_req_opts, [:method, :url])

    req_with_default_accept = Req.Request.put_header(req, "accept", "*/*")

    req_with_headers =
      req_headers_list
      |> Enum.reduce(req_with_default_accept, &maybe_merge_headers(&2, &1))
      |> maybe_merge_headers(extra_headers)

    normalized_query =
      opts
      |> drop_transport_opts()
      |> normalize_odata_params(%{}, count_kv)

    merged_params = merge_query_params_list(req_params_list, normalized_query)

    enforced_opts =
      [url: url, decode_body: false]
      |> maybe_put_opt(:into, into_sink)
      |> maybe_put_non_empty_params(merged_params)

    {req_with_headers, Keyword.merge(extra_req_opts, enforced_opts)}
  end

  defp drop_transport_opts(opts) when is_map(opts), do: Map.drop(opts, @transport_opt_keys)
  defp drop_transport_opts(opts) when is_list(opts), do: Keyword.drop(opts, @transport_opt_keys)

  @doc false
  @spec extract_req_options(keyword() | map(), [atom()]) :: keyword()
  def extract_req_options(opts, drop_keys \\ [:url, :method]) do
    opts
    |> get_opt(:req_options, [])
    |> to_keyword_opts()
    |> Keyword.drop(drop_keys)
  end

  defp to_keyword_opts(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
    else
      raise ArgumentError,
            "expected :req_options to be a keyword list or plain map, got: #{inspect(list)}"
    end
  end

  defp to_keyword_opts(map) when is_map(map) and not is_struct(map) do
    Enum.map(map, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError ->
            reraise ArgumentError,
                    [
                      message:
                        "unknown option key #{inspect(k)} in :req_options map; pass atom keys in a keyword list instead"
                    ],
                    __STACKTRACE__
        end

      {k, _v} ->
        raise ArgumentError,
              "invalid key #{inspect(k)} in :req_options map; expected atom or existing option string key"
    end)
  end

  defp to_keyword_opts(other) do
    raise ArgumentError,
          "expected :req_options to be a keyword list or plain map, got: #{inspect(other)}"
  end

  defp maybe_merge_headers(req, nil), do: req
  defp maybe_merge_headers(req, []), do: req
  defp maybe_merge_headers(req, headers) when headers == %{}, do: req
  defp maybe_merge_headers(req, headers), do: Req.merge(req, headers: headers)

  defp merge_query_params_list(req_params_list, query_params) do
    pairs_from_req =
      Enum.reduce(req_params_list, [], fn
        req_params, acc when is_map(req_params) or is_list(req_params) ->
          incoming = Enum.map(req_params, fn {k, v} -> {to_string(k), v} end)
          incoming_keys = MapSet.new(incoming, &elem(&1, 0))
          kept = Enum.reject(acc, fn {k, _v} -> MapSet.member?(incoming_keys, k) end)
          kept ++ incoming

        _, acc ->
          acc
      end)

    query_pairs = Enum.map(query_params, fn {k, v} -> {to_string(k), v} end)
    query_keys = MapSet.new(query_pairs, &elem(&1, 0))

    all_pairs =
      Enum.reject(pairs_from_req, fn {k, _v} -> MapSet.member?(query_keys, k) end) ++ query_pairs

    unique_key_count = all_pairs |> Enum.uniq_by(&elem(&1, 0)) |> length()

    if unique_key_count == length(all_pairs) do
      Map.new(all_pairs)
    else
      all_pairs
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_non_empty_params(opts, []), do: opts
  defp maybe_put_non_empty_params(opts, params) when params == %{}, do: opts
  defp maybe_put_non_empty_params(opts, params), do: Keyword.put(opts, :params, params)
end
