defmodule Creatio.Util do
  @moduledoc false

  alias Creatio.OData.Query

  @max_creatio_page_size 20_000

  @doc """
  Sanitizes a GUID string by removing braces, quotes, `guid'...'` wrappers, and whitespace.
  """
  @spec clean_guid(String.t() | atom()) :: String.t()
  def clean_guid(guid) do
    str =
      guid
      |> to_string()
      |> String.trim()

    str =
      if Regex.match?(~r/^guid'/i, str) do
        str
        |> then(&Regex.replace(~r/^guid'/i, &1, ""))
        |> String.replace_suffix("'", "")
      else
        str
      end

    str
    |> String.replace_prefix("{", "")
    |> String.replace_suffix("}", "")
    |> String.replace_prefix("'", "")
    |> String.replace_suffix("'", "")
    |> String.trim()
  end

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
  Shared lazy pagination stream for OData 4 and OData 3 collections.
  """
  @spec paginate_stream(
          Creatio.Client.t(),
          String.t() | Query.t(),
          keyword(),
          (Creatio.Client.t(), String.t() | Query.t(), keyword() ->
             {:ok, list() | map()} | {:error, Creatio.Error.t()})
        ) :: Enumerable.t()
  def paginate_stream(client, entity_or_query, opts, list_fun) do
    page_size = opts |> Keyword.get(:page_size, 100) |> parse_non_neg_int(100) |> max(1)
    base_opts = Keyword.drop(opts, [:page_size, :top, :skip, :count])

    initial_skip =
      cond do
        Keyword.has_key?(opts, :skip) ->
          opts |> Keyword.get(:skip, 0) |> parse_non_neg_int(0)

        match?(%Query{skip: s} when is_integer(s) and s >= 0, entity_or_query) ->
          entity_or_query.skip

        true ->
          0
      end

    initial_remaining =
      case entity_or_query do
        %Query{top: t} when is_integer(t) and t >= 0 -> t
        _ -> nil
      end

    cleaned_entity_or_query =
      case entity_or_query do
        %Query{} = q -> %{q | count: false, top: nil, skip: nil}
        other -> other
      end

    Stream.resource(
      fn -> {initial_skip, initial_remaining, initial_remaining == 0} end,
      fn
        {_offset, _remaining, true} ->
          {:halt, nil}

        {offset, remaining, false} ->
          req_top =
            if is_integer(remaining), do: min(page_size, remaining), else: page_size

          page_opts =
            base_opts
            |> Keyword.put(:top, req_top)
            |> Keyword.put(:skip, offset)

          case list_fun.(client, cleaned_entity_or_query, page_opts) do
            {:ok, records} when is_list(records) ->
              emit_stream_page(records, false, offset, req_top, remaining)

            {:ok, %{records: records} = meta} when is_list(records) ->
              has_next? =
                is_map(meta[:raw]) and
                  (Map.has_key?(meta[:raw], "@odata.nextLink") or
                     Map.has_key?(meta[:raw], "__next"))

              emit_stream_page(records, has_next?, offset, req_top, remaining)

            {:ok, other} ->
              raise Creatio.Error.new(
                      message: "Unexpected stream page response: #{inspect(other)}"
                    )

            {:error, error} ->
              raise error
          end
      end,
      fn _ -> :ok end
    )
  end

  defp emit_stream_page([], _has_next?, _offset, _req_top, _remaining), do: {:halt, nil}

  defp emit_stream_page(records, has_next?, offset, req_top, remaining) do
    {emitted, next_remaining, cap_reached?} =
      if is_integer(remaining) do
        sliced = Enum.take(records, remaining)
        new_rem = remaining - length(sliced)
        {sliced, new_rem, new_rem <= 0}
      else
        {records, nil, false}
      end

    len = length(emitted)

    done? =
      cap_reached? or
        (not has_next? and len < req_top and req_top <= @max_creatio_page_size)

    {emitted, {offset + len, next_remaining, done?}}
  end

  defp parse_non_neg_int(val, _default) when is_integer(val) and val >= 0, do: val

  defp parse_non_neg_int(val, default) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, _} when int >= 0 -> int
      _ -> default
    end
  end

  defp parse_non_neg_int(_, default), do: default
end
