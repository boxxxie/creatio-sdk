defmodule Creatio.Util do
  @moduledoc false

  alias Creatio.{Client, Error, Validation}
  alias Creatio.OData.Query

  @doc """
  Sanitizes a record ID / GUID string case-insensitively by removing `guid'...'`,
  braces, quotes, and outer whitespace, and rejects path traversal or separator characters.
  """
  @spec clean_guid(any()) :: String.t()
  defdelegate clean_guid(guid), to: Validation

  @doc false
  @spec strip_guid_syntax(any()) :: String.t()
  defdelegate strip_guid_syntax(guid), to: Validation

  @doc false
  @spec format_record_key(any(), :odata4 | :odata3) :: String.t()
  defdelegate format_record_key(id, protocol), to: Validation

  @doc false
  @spec extract_created_entity(map() | list()) :: map()
  def extract_created_entity(headers) do
    entity_id =
      response_header(headers, "odata-entityid") ||
        response_header(headers, "location")

    case entity_id do
      nil ->
        %{}

      uri ->
        case Regex.run(~r/\(([^()]+)\)\s*$/, uri) do
          [_, raw_id] ->
            cleaned = strip_guid_syntax(raw_id)

            if cleaned != "" and not String.contains?(raw_id, ["=", ","]) do
              %{"@odata.id" => uri, "Id" => cleaned}
            else
              %{"@odata.id" => uri}
            end

          _ ->
            %{"@odata.id" => uri}
        end
    end
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
  defdelegate require_entity_name!(entity, fun_name), to: Validation

  @doc """
  Validates and trims a Creatio OData field or navigation property name.
  """
  @spec require_field_name!(any(), String.t()) :: String.t()
  defdelegate require_field_name!(field, fun_name), to: Validation

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
    case decode_api_response(raw_resp) do
      {:html_or_xml, resp} ->
        {:error, Error.from_response(resp)}

      {:ok, resp} ->
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
  Normalizes a JSON response once and checks whether the response is HTML/XML or a WAF
  interstitial without running `Jason.decode/1` a second time on invalid JSON payloads.
  """
  @spec decode_api_response(Req.Response.t()) ::
          {:ok, Req.Response.t()} | {:html_or_xml, Req.Response.t()}
  def decode_api_response(%Req.Response{body: body} = resp) when is_map(body) or is_list(body) do
    {:ok, resp}
  end

  def decode_api_response(%Req.Response{body: body} = resp) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    cond do
      start >= size ->
        {:ok, resp}

      :binary.at(body, start) in [?{, ?[] ->
        case decode_json_slice(body, start, size) do
          {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
            {:ok, %Req.Response{resp | body: decoded}}

          {:ok, decoded} ->
            normalized = %Req.Response{resp | body: decoded}

            if html_or_xml_content_type?(resp.headers),
              do: {:html_or_xml, normalized},
              else: {:ok, normalized}

          :error ->
            if html_or_xml_markup_or_ct?(resp, body, start, size) do
              {:html_or_xml, resp}
            else
              {:ok, resp}
            end
        end

      true ->
        if html_or_xml_markup_or_ct?(resp, body, start, size) do
          {:html_or_xml, resp}
        else
          {:ok, resp}
        end
    end
  end

  def decode_api_response(%Req.Response{} = resp), do: {:ok, resp}

  @doc """
  Decodes JSON object or array responses even when Creatio/IIS returns a non-JSON
  content type (such as `text/html; charset=utf-8`) or a leading UTF-8 BOM.
  """
  @spec normalize_json_response(Req.Response.t()) :: Req.Response.t()
  def normalize_json_response(%Req.Response{body: body} = resp) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    if start < size and :binary.at(body, start) in [?{, ?[] do
      case decode_json_slice(body, start, size) do
        {:ok, decoded} -> %Req.Response{resp | body: decoded}
        :error -> resp
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

  def html_or_xml_response?(%Req.Response{body: body} = resp) when is_binary(body) do
    size = byte_size(body)
    start = skip_leading_ws_and_bom(body, 0, size)

    if start >= size do
      false
    else
      if :binary.at(body, start) in [?{, ?[] and json_object_or_array?(body, start, size) do
        false
      else
        html_or_xml_markup_or_ct?(resp, body, start, size)
      end
    end
  end

  def html_or_xml_response?(_), do: false

  defp html_or_xml_markup_or_ct?(%Req.Response{headers: headers}, body, start, size) do
    prefix_down =
      body
      |> binary_part(start, min(size - start, 512))
      |> String.downcase()

    String.starts_with?(prefix_down, @html_xml_prefixes) or
      has_waf_marker?(body) or
      html_or_xml_content_type?(headers)
  end

  defp json_object_or_array?(body, start, size) do
    case decode_json_slice(body, start, size) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> true
      _ -> false
    end
  end

  defp decode_json_slice(body, start, size) do
    trimmed =
      body
      |> binary_part(start, size - start)
      |> String.trim_trailing()

    case Jason.decode(trimmed) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> :error
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
    Enum.reduce(opts, base_params, fn
      {raw_key, val}, acc ->
        case {normalize_odata_opt_key(raw_key), val} do
          {:select, select_val} ->
            put_non_empty_csv_opt(acc, "$select", select_val)

          {:filter, bin} when is_binary(bin) ->
            if String.trim(bin) == "", do: acc, else: Map.put(acc, "$filter", bin)

          {key, order_val} when key in [:orderby, :order_by] ->
            orderby_str = format_orderby_opt(order_val)

            if is_binary(orderby_str) and String.trim(orderby_str) != "",
              do: Map.put(acc, "$orderby", orderby_str),
              else: acc

          {:top, top_val} when not is_nil(top_val) ->
            Map.put(acc, "$top", to_string(top_val))

          {:skip, skip_val} when not is_nil(skip_val) ->
            Map.put(acc, "$skip", to_string(skip_val))

          {:expand, expand_val} ->
            put_non_empty_csv_opt(acc, "$expand", expand_val)

          {:count, true} ->
            Map.put(acc, count_key, count_val)

          {:count, false} ->
            acc
            |> Map.delete("$count")
            |> Map.delete("$inlinecount")

          {:inlinecount, ic_val} when not is_nil(ic_val) ->
            trimmed = ic_val |> to_string() |> String.trim()
            if trimmed == "", do: acc, else: Map.put(acc, "$inlinecount", trimmed)

          {:params, map} when is_map(map) ->
            merge_param_entries(acc, Map.to_list(map))

          {:params, list} when is_list(list) ->
            merge_param_entries(acc, list)

          {:ignore, _} ->
            acc

          {key, nil} when is_binary(key) ->
            acc

          {key, []} when is_binary(key) ->
            acc

          {key, list} when is_binary(key) and is_list(list) ->
            Map.put(acc, key, Enum.map_join(list, ",", &to_string/1))

          {key, str_val} when is_binary(key) ->
            Map.put(acc, key, to_string(str_val))

          _ ->
            acc
        end

      _, acc ->
        acc
    end)
  end

  def normalize_odata_params(map, base_params, count_kv) when is_map(map) do
    map
    |> Map.to_list()
    |> normalize_odata_params(base_params, count_kv)
  end

  defp put_non_empty_csv_opt(acc, key, list) when is_list(list) do
    items =
      list
      |> Enum.reject(&(&1 in [nil, true, false]))
      |> Enum.map(&(&1 |> to_string() |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    if items == [], do: acc, else: Map.put(acc, key, Enum.join(items, ","))
  end

  defp put_non_empty_csv_opt(acc, key, bin_or_atom)
       when is_binary(bin_or_atom) or
              (is_atom(bin_or_atom) and bin_or_atom not in [nil, true, false]) do
    trimmed = bin_or_atom |> to_string() |> String.trim()
    if trimmed == "", do: acc, else: Map.put(acc, key, trimmed)
  end

  defp put_non_empty_csv_opt(acc, _key, _other), do: acc

  defp merge_param_entries(acc, entries) when is_list(entries) do
    Enum.reduce(entries, acc, fn
      {_k, nil}, a -> a
      {k, v}, a -> Map.put(a, to_string(k), format_extra_param_val(v))
      _, a -> a
    end)
  end

  defp normalize_odata_opt_key("select"), do: :select
  defp normalize_odata_opt_key("$select"), do: :select
  defp normalize_odata_opt_key("filter"), do: :filter
  defp normalize_odata_opt_key("$filter"), do: :filter
  defp normalize_odata_opt_key("orderby"), do: :orderby
  defp normalize_odata_opt_key("order_by"), do: :order_by
  defp normalize_odata_opt_key("$orderby"), do: :orderby
  defp normalize_odata_opt_key("top"), do: :top
  defp normalize_odata_opt_key("$top"), do: :top
  defp normalize_odata_opt_key("skip"), do: :skip
  defp normalize_odata_opt_key("$skip"), do: :skip
  defp normalize_odata_opt_key("expand"), do: :expand
  defp normalize_odata_opt_key("$expand"), do: :expand
  defp normalize_odata_opt_key("count"), do: :count
  defp normalize_odata_opt_key("inlinecount"), do: :inlinecount
  defp normalize_odata_opt_key("$inlinecount"), do: :inlinecount
  defp normalize_odata_opt_key("params"), do: :params
  defp normalize_odata_opt_key("req_options"), do: :ignore
  defp normalize_odata_opt_key("return"), do: :ignore
  defp normalize_odata_opt_key("strategy"), do: :ignore
  defp normalize_odata_opt_key("content_type"), do: :ignore
  defp normalize_odata_opt_key("raw"), do: :ignore
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

    cursor_field =
      case Keyword.get(opts_kw, :cursor_field) do
        nil -> nil
        val -> require_field_name!(val, "stream/3")
      end

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
          saw_next_link?: false,
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
              emit_stream_page(records, nil, cursor_field, state, client)

            {:ok, %{records: records} = meta} when is_list(records) ->
              next_link = extract_next_link(meta[:raw])
              emit_stream_page(records, next_link, cursor_field, state, client)

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

  defp upgrade_stream_list_fun(list_fun) when is_function(list_fun, 3) do
    info = Function.info(list_fun)

    case {Keyword.get(info, :module), Keyword.get(info, :name), Keyword.get(info, :arity)} do
      {mod, :list, 3} when mod in [:"Elixir.Creatio.OData", :"Elixir.Creatio.OData3"] ->
        Function.capture(mod, :list_page, 3)

      _ ->
        list_fun
    end
  end

  defp upgrade_stream_list_fun(list_fun), do: list_fun

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
    Enum.reduce(val, acc_params, fn
      {_k, nil}, a -> a
      {k, v}, a -> Map.put(a, to_string(k), format_extra_param_val(v))
    end)
  end

  defp merge_extra_params(acc_params, val) when is_list(val) do
    Enum.reduce(val, acc_params, fn
      {_k, nil}, a -> a
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
    sanitized_params =
      base_opts
      |> Keyword.get(:params, %{})
      |> Map.drop(["$top", "$skip", "$count", "$inlinecount", "$skiptoken", "$deltatoken"])

    next_params = Map.get(state, :next_params, %{})

    {cleaned_base, tail_opts} =
      if map_size(next_params) > 0 do
        merged_params = Map.merge(sanitized_params, next_params)

        {Keyword.drop(base_opts, [:params, :top, :skip]),
         [params: merged_params, top: fetch_size]}
      else
        base_without_pagination = Keyword.drop(base_opts, [:params, :top, :skip])
        prefix = if map_size(sanitized_params) > 0, do: [params: sanitized_params], else: []
        {base_without_pagination, prefix ++ [top: fetch_size, skip: state.offset]}
      end

    cleaned_base ++ tail_opts
  end

  defp build_stream_page_opts(base_opts, base_target, fetch_size, cursor_field, state, protocol) do
    user_params = Keyword.get(base_opts, :params, %{})
    query_params = if is_binary(base_target), do: %{}, else: Query.to_params(base_target)

    base_filter =
      Keyword.get(base_opts, :filter) || user_params["$filter"] || query_params["$filter"]

    requested_orderby =
      Keyword.get(base_opts, :orderby) || user_params["$orderby"] || query_params["$orderby"]

    {orderby, cursor_op} = resolve_cursor_orderby!(cursor_field, requested_orderby)

    combined_filter =
      case {base_filter, state.cursor} do
        {f, nil} ->
          f

        {nil, cur} ->
          cursor_predicate(cursor_field, cur, protocol, cursor_op)

        {"", cur} ->
          cursor_predicate(cursor_field, cur, protocol, cursor_op)

        {f, cur} ->
          "(#{f}) and (#{cursor_predicate(cursor_field, cur, protocol, cursor_op)})"
      end

    sanitized_params =
      Map.drop(user_params, ["$top", "$skip", "$count", "$inlinecount", "$filter", "$orderby"])

    cleaned_base = Keyword.drop(base_opts, [:params, :top, :orderby, :filter])
    params_prefix = if map_size(sanitized_params) > 0, do: [params: sanitized_params], else: []

    filter_tail =
      if is_binary(combined_filter) and String.trim(combined_filter) != "",
        do: [filter: combined_filter],
        else: []

    cleaned_base ++ params_prefix ++ [top: fetch_size, orderby: orderby] ++ filter_tail
  end

  defp resolve_cursor_orderby!(cursor_field, nil),
    do: {default_cursor_orderby(cursor_field, :asc), "gt"}

  defp resolve_cursor_orderby!(cursor_field, requested) do
    formatted = format_orderby_opt(requested)

    if is_nil(formatted) or String.trim(formatted) == "" do
      {default_cursor_orderby(cursor_field, :asc), "gt"}
    else
      clauses =
        formatted
        |> String.split(",", trim: true)
        |> Enum.map(&parse_orderby_clause/1)

      case clauses do
        [{^cursor_field, dir}] ->
          {default_cursor_orderby(cursor_field, dir), dir_to_cursor_op(dir)}

        [{^cursor_field, dir}, {"Id", dir}] when cursor_field != "Id" ->
          {default_cursor_orderby(cursor_field, dir), dir_to_cursor_op(dir)}

        _ ->
          raise ArgumentError,
                "keyset pagination with cursor_field #{inspect(cursor_field)} requires :orderby to start with #{cursor_field} (and optional Id tie-breaker in the same direction), got: #{inspect(requested)}"
      end
    end
  end

  defp parse_orderby_clause(clause) do
    case String.split(String.trim(clause), ~r/\s+/, trim: true) do
      [field] ->
        {field, :asc}

      [field, dir] ->
        case String.downcase(dir) do
          "asc" -> {field, :asc}
          "desc" -> {field, :desc}
          _ -> {field, :invalid}
        end

      _ ->
        {"", :invalid}
    end
  end

  defp default_cursor_orderby("Id", :asc), do: "Id asc"
  defp default_cursor_orderby("Id", :desc), do: "Id desc"
  defp default_cursor_orderby(cursor_field, :asc), do: "#{cursor_field} asc, Id asc"
  defp default_cursor_orderby(cursor_field, :desc), do: "#{cursor_field} desc, Id desc"

  defp dir_to_cursor_op(:asc), do: "gt"
  defp dir_to_cursor_op(:desc), do: "lt"

  defp ensure_cursor_select_in_opts(opts, nil), do: opts

  defp ensure_cursor_select_in_opts(opts, cursor_field) do
    required = required_cursor_fields(cursor_field)

    opts =
      case Keyword.fetch(opts, :select) do
        :error ->
          opts

        {:ok, select_val} ->
          case append_missing_fields(select_val, required) do
            nil -> Keyword.delete(opts, :select)
            updated -> Keyword.put(opts, :select, updated)
          end
      end

    case Keyword.get(opts, :params) do
      %{"$select" => raw_select} = params ->
        case append_missing_fields(raw_select, required) do
          nil ->
            updated_params = Map.delete(params, "$select")

            if updated_params == %{},
              do: Keyword.delete(opts, :params),
              else: Keyword.put(opts, :params, updated_params)

          updated ->
            Keyword.put(opts, :params, Map.put(params, "$select", updated))
        end

      _ ->
        opts
    end
  end

  defp ensure_cursor_select_in_query(query, _opts, nil), do: query

  defp ensure_cursor_select_in_query(query, opts, cursor_field) do
    has_params_select? =
      case Keyword.get(opts, :params) do
        %{"$select" => s} when is_binary(s) -> String.trim(s) != ""
        _ -> false
      end

    if Query.has_select?(query) and not Keyword.has_key?(opts, :select) and not has_params_select? do
      Query.select(query, required_cursor_fields(cursor_field))
    else
      query
    end
  end

  defp required_cursor_fields("Id"), do: ["Id"]
  defp required_cursor_fields(cursor_field), do: [cursor_field, "Id"]

  defp append_missing_fields(select_val, required) when is_list(select_val) do
    cleaned =
      select_val
      |> Enum.reject(&(&1 in [nil, true, false]))
      |> Enum.map(&(&1 |> to_string() |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    if cleaned == [] do
      nil
    else
      missing = Enum.reject(required, &(&1 in cleaned))
      cleaned ++ missing
    end
  end

  defp append_missing_fields(select_val, required)
       when is_binary(select_val) or
              (is_atom(select_val) and select_val not in [nil, true, false]) do
    parts =
      select_val
      |> to_string()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if parts == [] do
      nil
    else
      missing = Enum.reject(required, &(&1 in parts))
      Enum.join(parts ++ missing, ",")
    end
  end

  defp append_missing_fields(_, _), do: nil

  defp cursor_predicate(cursor_field, {:composite_cursor, cur_val, cur_id}, protocol, cursor_op) do
    build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol, cursor_op)
  end

  defp cursor_predicate(cursor_field, {cur_val, cur_id}, protocol, cursor_op) do
    build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol, cursor_op)
  end

  defp cursor_predicate(cursor_field, cur_val, protocol, cursor_op) do
    "#{cursor_field} #{cursor_op} #{format_cursor(cur_val, protocol)}"
  end

  defp build_composite_cursor_predicate(cursor_field, cur_val, cur_id, protocol, cursor_op) do
    formatted_val = format_cursor(cur_val, protocol)
    formatted_id = format_cursor(cur_id, protocol)

    "(#{cursor_field} #{cursor_op} #{formatted_val} or (#{cursor_field} eq #{formatted_val} and Id #{cursor_op} #{formatted_id}))"
  end

  defp strip_query_filter_if_overridden(entity, _cursor_field) when is_binary(entity), do: entity

  defp strip_query_filter_if_overridden(query, cursor_field) when is_binary(cursor_field) do
    Query.strip_filter_and_order(query)
  end

  defp strip_query_filter_if_overridden(other, _cursor_field), do: other

  defp emit_stream_page([], _next_link, _cursor_field, _state, _client),
    do: {:halt, nil}

  defp emit_stream_page(records, next_link, cursor_field, state, client) do
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

      cursor_val =
        case {cursor_field, last_record} do
          {field, %{} = rec} when is_binary(field) -> Map.get(rec, field)
          _ -> nil
        end

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

        has_next? =
          is_binary(next_link) and next_link != "" and trusted_next_link?(next_link, client)

        next_params =
          if is_nil(cursor_field) and has_next?,
            do: next_link_query_params(next_link, client),
            else: %{}

        saw_next_link? = state.saw_next_link? or has_next?
        done? = cap_reached? or (saw_next_link? and not has_next?)

        wrapped = Enum.map(emitted, &{:ok, &1})

        {wrapped,
         %{
           offset: state.offset + len,
           cursor: next_cursor,
           remaining: next_remaining,
           next_params: next_params,
           saw_next_link?: saw_next_link?,
           halt?: done?
         }}
      end
    end
  end

  defp trusted_next_link?(next_link, %Client{base_url: base_url}) when is_binary(next_link) do
    case URI.parse(next_link) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) ->
        same_origin_or_tls_downgrade?(base_url, scheme, host, port)

      %URI{} ->
        true
    end
  end

  defp next_link_query_params(nil, _client), do: %{}

  defp next_link_query_params(next_link, %Client{base_url: base_url}) when is_binary(next_link) do
    case URI.parse(next_link) do
      %URI{scheme: scheme, host: host, port: port, query: query}
      when is_binary(scheme) and is_binary(host) ->
        if same_origin_or_tls_downgrade?(base_url, scheme, host, port) do
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

  defp same_origin_or_tls_downgrade?(base_url, scheme, host, port)
       when is_binary(base_url) and base_url != "" do
    same_origin?(base_url, scheme, host, port) or
      case URI.parse(base_url) do
        %URI{scheme: b_scheme, host: b_host, port: b_port}
        when is_binary(b_scheme) and is_binary(b_host) ->
          String.downcase(b_scheme) == "https" and String.downcase(scheme) == "http" and
            String.downcase(b_host) == String.downcase(host) and
            (b_port || 443) == 443 and
            port in [nil, 80, 443]

        _ ->
          false
      end
  end

  defp same_origin_or_tls_downgrade?(_, _, _, _), do: false

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
    if protocol == :odata3, do: "datetimeoffset'#{iso}'", else: iso
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

      ms_date = parse_ms_ajax_datetime(val) ->
        format_ms_ajax_cursor(ms_date, protocol)

      iso_datetime_like?(val) ->
        format_iso_datetime_cursor(val, protocol)

      true ->
        "'#{String.replace(val, "'", "''")}'"
    end
  end

  defp format_cursor(val, _protocol), do: to_string(val)

  defp format_iso_datetime_cursor(val, :odata3) do
    if Regex.match?(~r/(?:Z|[+-]\d{2}:\d{2})\z/, val) do
      "datetimeoffset'#{val}'"
    else
      "datetime'#{val}'"
    end
  end

  defp format_iso_datetime_cursor(val, _protocol), do: val

  defp parse_ms_ajax_datetime(val) do
    case Regex.run(~r/\A\/Date\((-?\d+)(?:([+-])(\d{2})(\d{2}))?\)\/\z/, val) do
      [_, ms_str] ->
        {:naive, String.to_integer(ms_str)}

      [_, ms_str, sign, hh, mm] ->
        {:offset, String.to_integer(ms_str), sign, String.to_integer(hh), String.to_integer(mm)}

      _ ->
        nil
    end
  end

  defp format_ms_ajax_cursor({:naive, ms}, protocol) do
    naive_iso = ms |> ms_to_utc_datetime() |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    if protocol == :odata3, do: "datetime'#{naive_iso}'", else: "#{naive_iso}Z"
  end

  defp format_ms_ajax_cursor({:offset, ms, sign, hh, mm}, protocol) do
    offset_seconds = (hh * 3600 + mm * 60) * if(sign == "-", do: -1, else: 1)

    local_iso =
      ms
      |> ms_to_utc_datetime()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()

    hh_str = String.pad_leading(Integer.to_string(hh), 2, "0")
    mm_str = String.pad_leading(Integer.to_string(mm), 2, "0")
    iso_with_offset = "#{local_iso}#{sign}#{hh_str}:#{mm_str}"

    if protocol == :odata3, do: "datetimeoffset'#{iso_with_offset}'", else: iso_with_offset
  end

  defp ms_to_utc_datetime(ms) do
    secs = Integer.floor_div(ms, 1000)
    rem_ms = Integer.mod(ms, 1000)
    %DateTime{} = dt = DateTime.add(~U[1970-01-01 00:00:00Z], secs, :second)

    if rem_ms == 0 do
      dt
    else
      %DateTime{dt | microsecond: {rem_ms * 1000, 3}}
    end
  end

  defp iso_datetime_like?(val) do
    Regex.match?(
      ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\z/,
      val
    )
  end

  defp uuid_like?(bin), do: Validation.uuid_like?(bin)

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
        if Map.get(resp.private, :creatio_stream_rejected) == true or
             html_or_xml_response?(resp) or json_error_envelope?(resp) do
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

  defp json_error_envelope?(%Req.Response{body: body, headers: headers})
       when is_binary(body) do
    if html_or_xml_content_type?(headers) and starts_with_json_delimiter?(body) do
      size = byte_size(body)
      start = skip_leading_ws_and_bom(body, 0, size)

      case decode_json_slice(body, start, size) do
        {:ok, %{"error" => _}} -> true
        {:ok, %{"errorInfo" => %{} = info}} when map_size(info) > 0 -> true
        {:ok, %{"ErrorInfo" => %{} = info}} when map_size(info) > 0 -> true
        {:ok, %{"Exception" => %{} = ex}} when map_size(ex) > 0 -> true
        {:ok, %{"success" => val}} when val in [false, "false"] -> true
        {:ok, %{"Success" => val}} when val in [false, "false"] -> true
        _ -> false
      end
    else
      false
    end
  end

  defp json_error_envelope?(_), do: false

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
      {attempt_ref, %Req.Response{} = resp_acc} = ensure_stream_attempt(state_ref, resp_acc)

      cond do
        status == 204 ->
          {:cont, {req_acc, resp_acc}}

        status in [200, 206] ->
          handle_collectable_chunk(state_ref, attempt_ref, collectable, chunk, req_acc, resp_acc)

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
      halt_and_delete_collector(state_ref)
    end
  end

  defp ensure_stream_attempt(state_ref, %Req.Response{private: private} = resp_acc) do
    case Map.get(private, :creatio_stream_attempt) do
      nil ->
        attempt_ref = make_ref()
        halt_and_delete_collector(state_ref)
        Process.put(state_ref, {attempt_ref, nil})
        {attempt_ref, Req.Response.put_private(resp_acc, :creatio_stream_attempt, attempt_ref)}

      attempt_ref ->
        {attempt_ref, resp_acc}
    end
  end

  defp halt_and_delete_collector(state_ref) do
    case Process.delete(state_ref) do
      {_attempt_ref, {:opened, acc, collector}} -> collector.(acc, :halt)
      _ -> :ok
    end
  end

  defp handle_collectable_chunk(
         state_ref,
         attempt_ref,
         collectable,
         chunk,
         req_acc,
         %Req.Response{} = resp_acc
       ) do
    current_state =
      case Process.get(state_ref) do
        {^attempt_ref, state} -> state
        _ -> nil
      end

    case current_state do
      {:opened, acc, collector} ->
        next_acc = collector.(acc, {:cont, chunk})
        Process.put(state_ref, {attempt_ref, {:opened, next_acc, collector}})
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
          waf_or_html_stream_prefix?(probe_resp) ->
            Process.put(state_ref, {attempt_ref, :rejected})

            rejected_resp =
              %Req.Response{resp_acc | body: combined}
              |> Req.Response.put_private(:creatio_stream_rejected, true)

            {:cont, {req_acc, rejected_resp}}

          byte_size(combined) >= 1024 ->
            {acc, collector} = Collectable.into(collectable)
            Process.put(state_ref, {attempt_ref, {:opened, acc, collector}})
            next_acc = collector.(acc, {:cont, combined})
            Process.put(state_ref, {attempt_ref, {:opened, next_acc, collector}})
            {:cont, {req_acc, resp_acc}}

          true ->
            Process.put(state_ref, {attempt_ref, {:pending, combined}})
            {:cont, {req_acc, resp_acc}}
        end
    end
  end

  defp finalize_gated_collectable(state_ref, collectable, %Req.Response{} = resp) do
    resp_attempt = Map.get(resp.private, :creatio_stream_attempt)

    entry =
      case Process.delete(state_ref) do
        {^resp_attempt, state} when not is_nil(resp_attempt) ->
          state

        {_other_attempt, {:opened, old_acc, old_collector}} ->
          old_collector.(old_acc, :halt)
          nil

        _ ->
          nil
      end

    case entry do
      {:opened, acc, collector} ->
        final_body = collector.(acc, :done)
        {:ok, %Req.Response{resp | body: final_body}}

      :rejected ->
        {:ok, Req.Response.put_private(resp, :creatio_stream_rejected, true)}

      {:pending, buf} ->
        probe_resp = %Req.Response{resp | body: buf}

        if html_or_xml_response?(probe_resp) or json_error_envelope?(probe_resp) do
          {:ok, Req.Response.put_private(probe_resp, :creatio_stream_rejected, true)}
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

  defp waf_or_html_stream_prefix?(%Req.Response{headers: headers} = resp) do
    html_or_xml_markup?(resp) or html_or_xml_content_type?(headers)
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
    case get_opt(opts, :req_options, []) do
      nil -> []
      val -> val |> to_keyword_opts() |> Keyword.drop(drop_keys)
    end
  end

  @doc false
  @spec prepare_req_call(Req.Request.t(), keyword() | map(), keyword(), map(), [atom()]) ::
          {Req.Request.t(), keyword()}
  def prepare_req_call(
        %Req.Request{} = req,
        opts,
        call_opts,
        params \\ %{},
        drop_keys \\ [:url, :method]
      ) do
    raw_req_opts = extract_req_options(opts, drop_keys)
    {req_headers_list, extra_req_opts} = Keyword.pop_values(raw_req_opts, :headers)
    {req_params_list, extra_req_opts} = Keyword.pop_values(extra_req_opts, :params)

    req_with_headers = Enum.reduce(req_headers_list, req, &maybe_merge_headers(&2, &1))
    merged_params = merge_query_params_list(req_params_list, params)

    merged_call_opts =
      if merged_params == %{} or merged_params == [] do
        Keyword.merge(extra_req_opts, call_opts)
      else
        Keyword.merge(extra_req_opts, Keyword.put(call_opts, :params, merged_params))
      end

    {req_with_headers, merged_call_opts}
  end

  @doc false
  @spec pop_opt(keyword() | map(), atom()) :: {any(), keyword() | map()}
  def pop_opt(opts, key) when is_list(opts), do: Keyword.pop(opts, key)

  def pop_opt(opts, key) when is_map(opts) do
    str_key = Atom.to_string(key)

    case Map.pop(opts, key) do
      {nil, map_after} ->
        if Map.has_key?(opts, key) do
          {nil, Map.delete(map_after, str_key)}
        else
          Map.pop(map_after, str_key)
        end

      {val, map_after} ->
        {val, Map.delete(map_after, str_key)}
    end
  end

  @doc false
  @spec drop_opt(keyword() | map(), atom()) :: keyword() | map()
  def drop_opt(opts, key) when is_list(opts), do: Keyword.drop(opts, [key, Atom.to_string(key)])
  def drop_opt(opts, key) when is_map(opts), do: Map.drop(opts, [key, Atom.to_string(key)])

  @doc false
  @spec put_opt(keyword() | map(), atom(), any()) :: keyword() | map()
  def put_opt(opts, key, val) when is_list(opts), do: Keyword.put(opts, key, val)

  def put_opt(opts, key, val) when is_map(opts) do
    opts
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, val)
  end

  @doc false
  @spec safe_normalized_path(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_path}
  defdelegate safe_normalized_path(path), to: Validation

  @doc false
  @spec validate_crm_url(any(), String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def validate_crm_url(url, base_url, label \\ "CRM request URL")

  def validate_crm_url(url, base_url, label) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" or String.contains?(trimmed, ["\r", "\n", <<0>>]) do
      {:error, Error.new(message: "Invalid #{label}: #{inspect(url)}")}
    else
      authority_and_path = trimmed |> String.split(["?", "#"], parts: 2) |> hd()

      if String.starts_with?(trimmed, ["//", "\\"]) or
           String.contains?(authority_and_path, "\\") do
        {:error, Error.new(message: "Invalid #{label}: #{inspect(url)}")}
      else
        uri = URI.parse(trimmed)

        has_origin? =
          not is_nil(uri.scheme) or not is_nil(uri.host) or String.contains?(trimmed, "://")

        cond do
          has_origin? and
              not (uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
                     is_nil(uri.userinfo) and is_binary(base_url) and base_url != "" and
                       same_origin?(base_url, uri.scheme, uri.host, uri.port)) ->
            {:error,
             Error.new(
               message: "Invalid #{label}: external or mismatched origin #{inspect(url)} rejected"
             )}

          true ->
            case safe_normalized_path(uri.path || "") do
              {:ok, _norm_path} ->
                {:ok, trimmed}

              {:error, :invalid_path} ->
                {:error, Error.new(message: "Invalid #{label}: #{inspect(url)}")}
            end
        end
      end
    end
  end

  def validate_crm_url(other, _base_url, label) do
    {:error, Error.new(message: "Invalid #{label}: #{inspect(other)}")}
  end

  @doc false
  @spec validate_crm_url!(any(), String.t() | nil, String.t()) :: String.t()
  def validate_crm_url!(url, base_url, label \\ "CRM request URL") do
    case validate_crm_url(url, base_url, label) do
      {:ok, valid_url} -> valid_url
      {:error, %Error{message: msg}} -> raise ArgumentError, msg
    end
  end

  @doc false
  @spec to_keyword_opts(any()) :: keyword()
  defdelegate to_keyword_opts(opts), to: Validation

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
