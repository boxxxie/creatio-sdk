defmodule Creatio.OData.Query do
  @moduledoc """
  Composable query builder for Creatio OData 4 requests.

  Supports `$select`, `$filter`, `$orderby`, `$top`, `$skip`, `$expand`, and `$count`.

  ## Examples

      query =
        Creatio.OData.Query.new("Contact")
        |> Creatio.OData.Query.select(["Id", "Name", "Email"])
        |> Creatio.OData.Query.filter("Age gt 21 and City/Name eq 'Toronto'")
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
      Enum.map(values, fn
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
        and_filter(query, Enum.join(multiple, " or "))
    end
  end

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
        nil -> params
        list when is_list(list) -> Map.put(params, "$select", Enum.join(list, ","))
        str when is_binary(str) -> Map.put(params, "$select", str)
      end

    params =
      if query.filter, do: Map.put(params, "$filter", query.filter), else: params

    params =
      case query.orderby do
        nil -> params
        list when is_list(list) -> Map.put(params, "$orderby", Enum.join(list, ","))
        str when is_binary(str) -> Map.put(params, "$orderby", str)
      end

    params =
      if query.top, do: Map.put(params, "$top", to_string(query.top)), else: params

    params =
      if query.skip, do: Map.put(params, "$skip", to_string(query.skip)), else: params

    params =
      case query.expand do
        nil -> params
        list when is_list(list) -> Map.put(params, "$expand", Enum.join(list, ","))
        str when is_binary(str) -> Map.put(params, "$expand", str)
      end

    params =
      if query.count, do: Map.put(params, "$count", "true"), else: params

    Map.merge(params, query.custom_params)
  end
end
