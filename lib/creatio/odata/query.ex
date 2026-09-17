defmodule Creatio.OData.Query do
  @moduledoc """
  Composable query builder for Creatio OData 4 requests.

  Supports `$select`, `$filter`, `$orderby`, `$top`, `$skip`, `$expand`, and `$count`.
  Provides chainable filter helpers for standard OData functions and operators
  (`eq`, `ne`, `gt`, `ge`, `lt`, `le`, `contains`, `startswith`, `endswith`, `day`, `length`, `not`, `in`).

  ## Examples

      query =
        Creatio.OData.Query.new("Contact")
        |> Creatio.OData.Query.select(["Id", "Name", "Email"])
        |> Creatio.OData.Query.filter_eq("Active", true)
        |> Creatio.OData.Query.filter_contains("Name", "Smith")
        |> Creatio.OData.Query.order_by("Name asc")
        |> Creatio.OData.Query.top(25)
        |> Creatio.OData.Query.skip(50)
        |> Creatio.OData.Query.expand("Account")
        |> Creatio.OData.Query.count()

      {:ok, records} = Creatio.OData.execute(client, query)
  """

  defstruct [
    :entity,
    :filter,
    :select,
    :orderby,
    :top,
    :skip,
    :expand,
    count: false,
    custom_params: %{}
  ]

  @type t :: %__MODULE__{
          entity: String.t(),
          filter: String.t() | nil,
          select: [String.t()] | String.t() | nil,
          orderby: [String.t()] | String.t() | nil,
          top: integer() | nil,
          skip: integer() | nil,
          expand: [String.t()] | String.t() | nil,
          count: boolean(),
          custom_params: map()
        }

  @doc """
  Initializes a new query for an entity collection.
  """
  @spec new(String.t()) :: t()
  def new(entity) when is_binary(entity) do
    %__MODULE__{entity: entity}
  end

  @doc """
  Specifies the fields to retrieve (`$select`).
  Can be called multiple times to accumulate fields.
  """
  @spec select(t(), [String.t() | atom()] | String.t() | atom()) :: t()
  def select(%__MODULE__{} = query, fields) when is_list(fields) do
    new_fields = Enum.map(fields, &to_string/1)

    existing =
      case query.select do
        nil -> []
        list when is_list(list) -> list
        str when is_binary(str) -> String.split(str, ",")
      end

    %{query | select: Enum.uniq(existing ++ new_fields)}
  end

  def select(%__MODULE__{} = query, field) when is_binary(field) or is_atom(field) do
    select(query, [to_string(field)])
  end

  @doc """
  Specifies or replaces the filter expression (`$filter`).
  """
  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = query, filter_expr) when is_binary(filter_expr) do
    %{query | filter: filter_expr}
  end

  @doc """
  Combines an additional filter expression with `and`. Alias for `and_filter/2`.
  """
  @spec where(t(), String.t()) :: t()
  def where(%__MODULE__{} = query, filter_expr) when is_binary(filter_expr) do
    and_filter(query, filter_expr)
  end

  @doc """
  Combines an additional filter expression with `and`.
  """
  @spec and_filter(t(), String.t()) :: t()
  def and_filter(%__MODULE__{filter: nil} = query, filter_expr) when is_binary(filter_expr) do
    %{query | filter: filter_expr}
  end

  def and_filter(%__MODULE__{filter: current} = query, filter_expr) when is_binary(filter_expr) do
    %{query | filter: "(#{current}) and (#{filter_expr})"}
  end

  @doc """
  Combines an additional filter expression with `or`.
  """
  @spec or_filter(t(), String.t()) :: t()
  def or_filter(%__MODULE__{filter: nil} = query, filter_expr) when is_binary(filter_expr) do
    %{query | filter: filter_expr}
  end

  def or_filter(%__MODULE__{filter: current} = query, filter_expr) when is_binary(filter_expr) do
    %{query | filter: "(#{current}) or (#{filter_expr})"}
  end

  @doc """
  Combines an additional filter expression with `or`. Alias for `or_filter/2`.
  """
  @spec or_where(t(), String.t()) :: t()
  def or_where(%__MODULE__{} = query, filter_expr) when is_binary(filter_expr) do
    or_filter(query, filter_expr)
  end

  # ---------------------------------------------------------------------------
  # Filter Builder Helpers (Operators & Functions)
  # ---------------------------------------------------------------------------

  @doc """
  Adds an equality condition (`{field} eq {value}`).
  Literals (numbers, booleans, null) are formatted automatically without quotes.
  Pass `quoted: false` for unquoted GUIDs / IDs.
  """
  @spec filter_eq(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_eq(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} eq #{format_literal(value, opts)}")
  end

  @doc """
  Alias for `filter_eq/4`.
  """
  def where_eq(query, field, value, opts \\ []), do: filter_eq(query, field, value, opts)

  @doc """
  Adds an equality condition combined with `or` (`{field} eq {value}`).
  """
  @spec or_filter_eq(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_eq(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} eq #{format_literal(value, opts)}")
  end

  @doc """
  Adds an inequality condition (`{field} ne {value}`).
  """
  @spec filter_ne(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_ne(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} ne #{format_literal(value, opts)}")
  end

  @doc """
  Adds an inequality condition combined with `or` (`{field} ne {value}`).
  """
  @spec or_filter_ne(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_ne(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} ne #{format_literal(value, opts)}")
  end

  @doc """
  Adds a greater-than condition (`{field} gt {value}`).
  """
  @spec filter_gt(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_gt(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} gt #{format_literal(value, opts)}")
  end

  @doc """
  Adds a greater-than condition combined with `or` (`{field} gt {value}`).
  """
  @spec or_filter_gt(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_gt(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} gt #{format_literal(value, opts)}")
  end

  @doc """
  Adds a greater-than-or-equal condition (`{field} ge {value}`).
  """
  @spec filter_ge(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_ge(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} ge #{format_literal(value, opts)}")
  end

  @doc """
  Adds a greater-than-or-equal condition combined with `or` (`{field} ge {value}`).
  """
  @spec or_filter_ge(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_ge(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} ge #{format_literal(value, opts)}")
  end

  @doc """
  Adds a less-than condition (`{field} lt {value}`).
  """
  @spec filter_lt(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_lt(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} lt #{format_literal(value, opts)}")
  end

  @doc """
  Adds a less-than-or-equal condition combined with `or` (`{field} lt {value}`).
  """
  @spec or_filter_lt(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_lt(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} lt #{format_literal(value, opts)}")
  end

  @doc """
  Adds a less-than-or-equal condition (`{field} le {value}`).
  """
  @spec filter_le(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_le(%__MODULE__{} = query, field, value, opts \\ []) do
    and_filter(query, "#{field} le #{format_literal(value, opts)}")
  end

  @doc """
  Adds a less-than-or-equal condition combined with `or` (`{field} le {value}`).
  """
  @spec or_filter_le(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_le(%__MODULE__{} = query, field, value, opts \\ []) do
    or_filter(query, "#{field} le #{format_literal(value, opts)}")
  end

  @doc """
  Adds an OData 4 string `contains` condition (`contains({field}, '{value}')`).
  """
  @spec filter_contains(t(), String.t() | atom(), any()) :: t()
  def filter_contains(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    and_filter(query, "contains(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData 4 string `contains` condition combined with `or`.
  """
  @spec or_filter_contains(t(), String.t() | atom(), any()) :: t()
  def or_filter_contains(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    or_filter(query, "contains(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData string `startswith` condition (`startswith({field}, '{value}')`).
  """
  @spec filter_startswith(t(), String.t() | atom(), any()) :: t()
  def filter_startswith(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    and_filter(query, "startswith(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData string `startswith` condition combined with `or`.
  """
  @spec or_filter_startswith(t(), String.t() | atom(), any()) :: t()
  def or_filter_startswith(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    or_filter(query, "startswith(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData string `endswith` condition (`endswith({field}, '{value}')`).
  """
  @spec filter_endswith(t(), String.t() | atom(), any()) :: t()
  def filter_endswith(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    and_filter(query, "endswith(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData string `endswith` condition combined with `or`.
  """
  @spec or_filter_endswith(t(), String.t() | atom(), any()) :: t()
  def or_filter_endswith(%__MODULE__{} = query, field, value) do
    escaped = String.replace(to_string(value), "'", "''")
    or_filter(query, "endswith(#{field},'#{escaped}')")
  end

  @doc """
  Adds an OData `day` date function condition (`day({field}) {op} {value}`).
  """
  @spec filter_day(t(), String.t() | atom(), any(), String.t()) :: t()
  def filter_day(%__MODULE__{} = query, field, day_value, op \\ "eq") do
    and_filter(query, "day(#{field}) #{op} #{day_value}")
  end

  @doc """
  Adds an OData `day` date function condition combined with `or` (`day({field}) {op} {value}`).
  """
  @spec or_filter_day(t(), String.t() | atom(), any(), String.t()) :: t()
  def or_filter_day(%__MODULE__{} = query, field, day_value, op \\ "eq") do
    or_filter(query, "day(#{field}) #{op} #{day_value}")
  end

  @doc """
  Adds an OData `length` string function condition (`length({field}) {op} {value}`).
  """
  @spec filter_length(t(), String.t() | atom(), any(), String.t()) :: t()
  def filter_length(%__MODULE__{} = query, field, len_value, op \\ "eq") do
    and_filter(query, "length(#{field}) #{op} #{len_value}")
  end

  @doc """
  Adds an OData `length` string function condition combined with `or` (`length({field}) {op} {value}`).
  """
  @spec or_filter_length(t(), String.t() | atom(), any(), String.t()) :: t()
  def or_filter_length(%__MODULE__{} = query, field, len_value, op \\ "eq") do
    or_filter(query, "length(#{field}) #{op} #{len_value}")
  end

  @doc """
  Negates the current filter (`not ({current})`) or an explicitly provided expression.
  """
  @spec filter_not(t(), String.t() | nil) :: t()
  def filter_not(query, expr \\ nil)
  def filter_not(%__MODULE__{filter: nil} = query, nil), do: query

  def filter_not(%__MODULE__{filter: current} = query, nil) do
    %{query | filter: "not (#{current})"}
  end

  def filter_not(%__MODULE__{} = query, expr) when is_binary(expr) do
    and_filter(query, "not (#{expr})")
  end

  @doc """
  Builds an OData filter condition checking if a field equals any of a list of values.
  Since Creatio OData 4 does not support the `in` operator, this constructs
  `(Field eq 'v1' or Field eq 'v2')`.

  ## Options

    * `:quoted` - boolean indicating whether to wrap values in single quotes (default `true`).
  """
  @spec filter_in(t(), String.t() | atom(), [any()], keyword()) :: t()
  def filter_in(%__MODULE__{} = query, field, values, opts \\ []) do
    quoted? = Keyword.get(opts, :quoted, true)

    conditions =
      values
      |> Enum.uniq()
      |> Enum.map(fn
        nil ->
          "#{field} eq null"

        val ->
          formatted =
            if quoted? do
              escaped = String.replace(to_string(val), "'", "''")
              "'#{escaped}'"
            else
              to_string(val)
            end

          "#{field} eq #{formatted}"
      end)

    case conditions do
      [] ->
        # No values matching
        and_filter(query, "1 eq 0")

      [single] ->
        and_filter(query, single)

      multiple ->
        and_filter(query, "(#{Enum.join(multiple, " or ")})")
    end
  end

  @doc """
  Builds an OData filter condition checking if a field equals any of a list of values, combined with `or`.
  """
  @spec or_filter_in(t(), String.t() | atom(), [any()], keyword()) :: t()
  def or_filter_in(%__MODULE__{} = query, field, values, opts \\ []) do
    quoted? = Keyword.get(opts, :quoted, true)

    conditions =
      values
      |> Enum.uniq()
      |> Enum.map(fn
        nil ->
          "#{field} eq null"

        val ->
          formatted =
            if quoted? do
              escaped = String.replace(to_string(val), "'", "''")
              "'#{escaped}'"
            else
              to_string(val)
            end

          "#{field} eq #{formatted}"
      end)

    case conditions do
      [] ->
        query

      [single] ->
        or_filter(query, single)

      multiple ->
        or_filter(query, "(#{Enum.join(multiple, " or ")})")
    end
  end

  @doc """
  Builds an OData filter condition for a list of UUID / GUID primary keys.
  Since GUIDs in OData 4 are unquoted literals, this formats as `(Id eq uuid1 or Id eq uuid2)`.
  """
  @spec filter_in_ids(t(), String.t() | atom(), [any()]) :: t()
  def filter_in_ids(%__MODULE__{} = query, field, ids) when is_list(ids) do
    filter_in(query, field, ids, quoted: false)
  end

  @doc """
  Adds a GUID equality condition (`{field} eq {guid}`).
  In OData 4, GUIDs are unquoted literals.
  In OData 3 (pass `protocol: :odata3` or `odata3: true`), GUIDs are formatted as `guid'{guid}'`.
  """
  @spec filter_guid(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_guid(%__MODULE__{} = query, field, guid, opts \\ []) do
    formatted = format_guid_literal(guid, opts)
    and_filter(query, "#{field} eq #{formatted}")
  end

  @doc """
  Adds a GUID equality condition combined with `or` (`{field} eq {guid}`).
  """
  @spec or_filter_guid(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_guid(%__MODULE__{} = query, field, guid, opts \\ []) do
    formatted = format_guid_literal(guid, opts)
    or_filter(query, "#{field} eq #{formatted}")
  end

  # ---------------------------------------------------------------------------
  # OrderBy, Top, Skip, Expand, Count & Serialization
  # ---------------------------------------------------------------------------

  @doc """
  Specifies the ordering clause (`$orderby`).
  Accepts a string, atom, keyword list (e.g. `[Name: :asc, CreatedOn: :desc]`), or list of strings.
  Can be called multiple times to append ordering clauses.
  """
  @spec order_by(t(), [String.t() | atom() | tuple()] | String.t() | atom()) :: t()
  def order_by(%__MODULE__{} = query, order_expr) when is_list(order_expr) do
    formatted =
      Enum.map(order_expr, fn
        {col, dir} -> "#{col} #{dir}"
        col -> to_string(col)
      end)

    existing =
      case query.orderby do
        nil -> []
        list when is_list(list) -> list
        str when is_binary(str) -> [str]
      end

    %{query | orderby: existing ++ formatted}
  end

  def order_by(%__MODULE__{} = query, order_expr)
      when is_binary(order_expr) or is_atom(order_expr) do
    str = to_string(order_expr)

    existing =
      case query.orderby do
        nil -> []
        list when is_list(list) -> list
        prev when is_binary(prev) -> [prev]
      end

    %{query | orderby: existing ++ [str]}
  end

  @doc """
  Specifies the ordering clause with a field and direction (e.g. `order_by(query, :Name, :asc)`).
  """
  @spec order_by(t(), String.t() | atom(), String.t() | atom()) :: t()
  def order_by(%__MODULE__{} = query, field, direction)
      when (is_binary(field) or is_atom(field)) and (is_binary(direction) or is_atom(direction)) do
    order_by(query, "#{field} #{direction}")
  end

  @doc """
  Specifies maximum records to return (`$top`).
  """
  @spec top(t(), non_neg_integer()) :: t()
  def top(%__MODULE__{} = query, n) when is_integer(n) and n >= 0 do
    %{query | top: n}
  end

  @doc """
  Specifies number of records to skip (`$skip`).
  """
  @spec skip(t(), non_neg_integer()) :: t()
  def skip(%__MODULE__{} = query, n) when is_integer(n) and n >= 0 do
    %{query | skip: n}
  end

  @doc """
  Specifies navigation properties to expand (`$expand`).
  Can be called multiple times to accumulate properties.
  """
  @spec expand(t(), [String.t() | atom()] | String.t() | atom()) :: t()
  def expand(%__MODULE__{} = query, nav_props) when is_list(nav_props) do
    new_props = Enum.map(nav_props, &to_string/1)

    existing =
      case query.expand do
        nil -> []
        list when is_list(list) -> list
        str when is_binary(str) -> String.split(str, ",")
      end

    %{query | expand: Enum.uniq(existing ++ new_props)}
  end

  def expand(%__MODULE__{} = query, nav_prop) when is_binary(nav_prop) or is_atom(nav_prop) do
    expand(query, [to_string(nav_prop)])
  end

  @doc """
  Toggles whether to request total inline count (`$count=true`).
  """
  @spec count(t(), boolean()) :: t()
  def count(%__MODULE__{} = query, enabled? \\ true) when is_boolean(enabled?) do
    %{query | count: enabled?}
  end

  @doc """
  Adds an arbitrary custom query parameter.
  """
  @spec param(t(), String.t() | atom(), any()) :: t()
  def param(%__MODULE__{custom_params: params} = query, key, value) do
    %{query | custom_params: Map.put(params, to_string(key), to_string(value))}
  end

  @doc """
  Returns the URL query string representation for the query.
  """
  @spec to_query_string(t()) :: String.t()
  def to_query_string(%__MODULE__{} = query) do
    query |> to_params() |> URI.encode_query()
  end

  @doc """
  Serializes the query into a map of query parameters ready for the HTTP request.
  """
  @spec to_params(t()) :: map()
  def to_params(%__MODULE__{} = query) do
    params = %{}

    params =
      case query.select do
        nil ->
          params

        [] ->
          params

        "" ->
          params

        list when is_list(list) ->
          case Enum.reject(list, &(&1 in [nil, ""])) do
            [] -> params
            non_empty -> Map.put(params, "$select", Enum.join(non_empty, ","))
          end

        str when is_binary(str) ->
          Map.put(params, "$select", str)
      end

    params =
      if query.filter && query.filter != "",
        do: Map.put(params, "$filter", query.filter),
        else: params

    params =
      case query.orderby do
        nil ->
          params

        [] ->
          params

        "" ->
          params

        list when is_list(list) ->
          case Enum.reject(list, &(&1 in [nil, ""])) do
            [] -> params
            non_empty -> Map.put(params, "$orderby", Enum.join(non_empty, ","))
          end

        str when is_binary(str) ->
          Map.put(params, "$orderby", str)
      end

    params =
      if query.top, do: Map.put(params, "$top", to_string(query.top)), else: params

    params =
      if query.skip, do: Map.put(params, "$skip", to_string(query.skip)), else: params

    params =
      case query.expand do
        nil ->
          params

        [] ->
          params

        "" ->
          params

        list when is_list(list) ->
          case Enum.reject(list, &(&1 in [nil, ""])) do
            [] -> params
            non_empty -> Map.put(params, "$expand", Enum.join(non_empty, ","))
          end

        str when is_binary(str) ->
          Map.put(params, "$expand", str)
      end

    params =
      if query.count, do: Map.put(params, "$count", "true"), else: params

    Map.merge(params, query.custom_params)
  end

  defp format_literal(nil, _opts), do: "null"
  defp format_literal(true, _opts), do: "true"
  defp format_literal(false, _opts), do: "false"

  defp format_literal(%DateTime{} = val, opts) do
    if Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false) do
      "datetime'#{DateTime.to_iso8601(val)}'"
    else
      DateTime.to_iso8601(val)
    end
  end

  defp format_literal(%NaiveDateTime{} = val, opts) do
    if Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false) do
      "datetime'#{NaiveDateTime.to_iso8601(val)}'"
    else
      NaiveDateTime.to_iso8601(val) <> "Z"
    end
  end

  defp format_literal(%Date{} = val, opts) do
    if Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false) do
      "datetime'#{Date.to_iso8601(val)}T00:00:00'"
    else
      Date.to_iso8601(val)
    end
  end

  defp format_literal(%Time{} = val, opts) do
    if Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false) do
      "time'#{Time.to_iso8601(val)}'"
    else
      Time.to_iso8601(val)
    end
  end

  defp format_literal(val, opts) when is_integer(val) or is_float(val) do
    if Keyword.get(opts, :quoted, false) do
      "'#{val}'"
    else
      to_string(val)
    end
  end

  defp format_literal(val, opts) do
    str = to_string(val)

    cond do
      Keyword.get(opts, :guid, false) or Keyword.get(opts, :type) == :guid ->
        format_guid_literal(val, opts)

      String.starts_with?(str, "guid'") and String.ends_with?(str, "'") ->
        str

      Keyword.get(opts, :quoted, true) ->
        escaped = String.replace(str, "'", "''")
        "'#{escaped}'"

      true ->
        str
    end
  end

  defp format_guid_literal(guid, opts) do
    clean = Creatio.Util.clean_guid(guid)

    if Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false) do
      "guid'#{clean}'"
    else
      clean
    end
  end
end
