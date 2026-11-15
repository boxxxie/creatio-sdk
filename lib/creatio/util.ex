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

    max_records =
      case {Keyword.get(opts_kw, :max_records), entity_or_query} do
        {n, _} when is_integer(n) and n >= 0 -> n
        {nil, %Query{top: n}} when is_integer(n) and n >= 0 -> n
        _ -> nil
      end

    initial_skip =
      cond do
        Keyword.has_key?(opts_kw, :skip) ->
          opts_kw |> Keyword.get(:skip, 0) |> parse_non_neg_int(0)

        match?(%Query{skip: s} when is_integer(s) and s >= 0, entity_or_query) ->
          entity_or_query.skip

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
      case entity_or_query do
        %Query{} = q -> %Query{q | count: false, top: nil, skip: nil}
        entity -> entity
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
              raise Error.new(message: "Unexpected stream page response: #{inspect(other)}")

            {:error, error} ->
              raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp build_stream_page_opts(base_opts, _base_target, fetch_size, nil, state, _protocol) do
    base_opts
    |> Keyword.put(:top, fetch_size)
    |> Keyword.put(:skip, state.offset)
  end

  defp build_stream_page_opts(base_opts, base_target, fetch_size, cursor_field, state, protocol) do
    base_filter =
      case base_target do
        %Query{} = q -> Query.to_params(q)["$filter"] || Keyword.get(base_opts, :filter)
        _ -> Keyword.get(base_opts, :filter)
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

  defp strip_query_filter_if_overridden(%Query{} = q, cursor_field)
       when is_binary(cursor_field) do
    %Query{q | filter: nil, filters_rev: [], orderby: nil, orderby_rev: []}
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

      {emitted,
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
end
