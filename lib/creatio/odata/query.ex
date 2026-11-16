defmodule Creatio.OData.Query do
  @moduledoc """
  Composable query builder for Creatio OData 4 requests.

  Supports `$select`, `$filter`, `$orderby`, `$top`, `$skip`, `$expand`, and `$count`.
  Provides chainable filter helpers for standard OData functions and operators
  (`eq`, `ne`, `gt`, `ge`, `lt`, `le`, `contains`, `startswith`, `endswith`, `day`, `length`, `not`, `in`).

  `Creatio.OData.Query.t()` is an `@opaque` builder struct; inspect or serialize it via
  `entity/1`, `get_top/1`, `get_skip/1`, `to_params/1`, and `to_query_string/1`.

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

  alias Creatio.Validation

  defstruct [
    :entity,
    :top,
    :skip,
    count: false,
    custom_params: %{},
    filters_rev: [],
    select_rev: [],
    orderby_rev: [],
    expand_rev: []
  ]

  @opaque t :: %__MODULE__{
            entity: String.t(),
            top: non_neg_integer() | nil,
            skip: non_neg_integer() | nil,
            count: boolean(),
            custom_params: %{optional(String.t()) => String.t()},
            filters_rev: [String.t()],
            select_rev: [String.t()],
            orderby_rev: [String.t()],
            expand_rev: [String.t()]
          }

  @valid_comparison_ops ~w(eq ne gt ge lt le)

  @doc """
  Initializes a new query for an entity collection.
  """
  @spec new(String.t() | nil) :: t()
  def new(nil), do: %__MODULE__{entity: ""}

  def new(entity) when is_binary(entity) do
    %__MODULE__{entity: String.trim(entity)}
  end

  def new(other) do
    raise ArgumentError,
          "expected a string or nil entity name in Creatio.OData.Query.new/1, got: #{inspect(other)}"
  end

  @doc """
  Specifies the fields to retrieve (`$select`).
  Can be called multiple times to accumulate fields.
  """
  @spec select(t(), [String.t() | atom()] | String.t() | atom()) :: t()
  def select(%__MODULE__{select_rev: rev} = query, fields) when is_list(fields) do
    next_rev = Enum.reduce(fields, rev, &prepend_split_tokens(&1, &2))
    %__MODULE__{query | select_rev: next_rev}
  end

  def select(%__MODULE__{} = query, field) when is_binary(field) or is_atom(field) do
    select(query, [field])
  end

  @doc """
  Specifies or replaces the filter expression (`$filter`).
  """
  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = query, filter_expr) when is_binary(filter_expr) do
    %__MODULE__{
      query
      | filters_rev: if(filter_expr == "", do: [], else: [filter_expr])
    }
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
  def and_filter(%__MODULE__{} = query, "") do
    query
  end

  def and_filter(%__MODULE__{filters_rev: rev} = query, filter_expr)
      when is_binary(filter_expr) do
    %__MODULE__{query | filters_rev: [filter_expr | rev]}
  end

  @doc """
  Combines an additional filter expression with `or`.
  """
  @spec or_filter(t(), String.t()) :: t()
  def or_filter(%__MODULE__{} = query, "") do
    query
  end

  def or_filter(%__MODULE__{} = query, filter_expr) when is_binary(filter_expr) do
    case compile_filter(query) do
      nil -> %__MODULE__{query | filters_rev: [filter_expr]}
      lhs -> %__MODULE__{query | filters_rev: ["(#{lhs}) or (#{filter_expr})"]}
    end
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
  @spec where_eq(t(), String.t() | atom(), any(), keyword()) :: t()
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
  Adds a less-than condition combined with `or` (`{field} lt {value}`).
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
    and_filter(query, "contains(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData 4 string `contains` condition combined with `or`.
  """
  @spec or_filter_contains(t(), String.t() | atom(), any()) :: t()
  def or_filter_contains(%__MODULE__{} = query, field, value) do
    or_filter(query, "contains(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData string `startswith` condition (`startswith({field}, '{value}')`).
  """
  @spec filter_startswith(t(), String.t() | atom(), any()) :: t()
  def filter_startswith(%__MODULE__{} = query, field, value) do
    and_filter(query, "startswith(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData string `startswith` condition combined with `or`.
  """
  @spec or_filter_startswith(t(), String.t() | atom(), any()) :: t()
  def or_filter_startswith(%__MODULE__{} = query, field, value) do
    or_filter(query, "startswith(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData string `endswith` condition (`endswith({field}, '{value}')`).
  """
  @spec filter_endswith(t(), String.t() | atom(), any()) :: t()
  def filter_endswith(%__MODULE__{} = query, field, value) do
    and_filter(query, "endswith(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData string `endswith` condition combined with `or`.
  """
  @spec or_filter_endswith(t(), String.t() | atom(), any()) :: t()
  def or_filter_endswith(%__MODULE__{} = query, field, value) do
    or_filter(query, "endswith(#{field},'#{escape_single_quotes(value)}')")
  end

  @doc """
  Adds an OData `day` date function condition (`day({field}) {op} {value}`).
  """
  @spec filter_day(
          t(),
          String.t() | atom(),
          integer() | String.t() | Date.t() | DateTime.t() | NaiveDateTime.t(),
          String.t() | atom()
        ) :: t()
  def filter_day(%__MODULE__{} = query, field, day_value, op \\ "eq") do
    op_str = validate_comparison_op!(op)
    and_filter(query, "day(#{field}) #{op_str} #{extract_day_number(day_value)}")
  end

  @doc """
  Adds an OData `day` date function condition combined with `or` (`day({field}) {op} {value}`).
  """
  @spec or_filter_day(
          t(),
          String.t() | atom(),
          integer() | String.t() | Date.t() | DateTime.t() | NaiveDateTime.t(),
          String.t() | atom()
        ) :: t()
  def or_filter_day(%__MODULE__{} = query, field, day_value, op \\ "eq") do
    op_str = validate_comparison_op!(op)
    or_filter(query, "day(#{field}) #{op_str} #{extract_day_number(day_value)}")
  end

  @doc """
  Adds an OData `length` string function condition (`length({field}) {op} {value}`).
  """
  @spec filter_length(t(), String.t() | atom(), any(), String.t() | atom()) :: t()
  def filter_length(%__MODULE__{} = query, field, len_value, op \\ "eq") do
    and_filter(query, "length(#{field}) #{op} #{len_value}")
  end

  @doc """
  Adds an OData `length` string function condition combined with `or` (`length({field}) {op} {value}`).
  """
  @spec or_filter_length(t(), String.t() | atom(), any(), String.t() | atom()) :: t()
  def or_filter_length(%__MODULE__{} = query, field, len_value, op \\ "eq") do
    or_filter(query, "length(#{field}) #{op} #{len_value}")
  end

  @doc """
  Negates the current filter (`not ({current})`) or an explicitly provided expression.
  """
  @spec filter_not(t(), String.t() | nil) :: t()
  def filter_not(query, expr \\ nil)

  def filter_not(%__MODULE__{} = query, nil) do
    case compile_filter(query) do
      nil -> query
      current -> %__MODULE__{query | filters_rev: ["not (#{current})"]}
    end
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
    case build_in_conditions(field, values, opts) do
      [] -> and_filter(query, "1 eq 0")
      [single] -> and_filter(query, single)
      multiple -> and_filter(query, "(#{Enum.join(multiple, " or ")})")
    end
  end

  @doc """
  Builds an OData filter condition checking if a field equals any of a list of values, combined with `or`.
  """
  @spec or_filter_in(t(), String.t() | atom(), [any()], keyword()) :: t()
  def or_filter_in(%__MODULE__{} = query, field, values, opts \\ []) do
    case build_in_conditions(field, values, opts) do
      [] -> if(compile_filter(query) == nil, do: and_filter(query, "1 eq 0"), else: query)
      [single] -> or_filter(query, single)
      multiple -> or_filter(query, "(#{Enum.join(multiple, " or ")})")
    end
  end

  @doc """
  Builds an OData filter condition for a list of UUID / GUID primary keys.
  Since GUIDs in OData 4 are unquoted literals, this formats as `(Id eq uuid1 or Id eq uuid2)`.
  """
  @spec filter_in_ids(t(), String.t() | atom(), [any()], keyword()) :: t()
  def filter_in_ids(%__MODULE__{} = query, field, ids, opts \\ []) when is_list(ids) do
    cleaned = Enum.map(ids, &format_guid_literal(&1, opts))
    filter_in(query, field, cleaned, Keyword.put(opts, :quoted, false))
  end

  @doc """
  Adds a GUID equality condition (`{field} eq {guid}`).
  In OData 4, GUIDs are unquoted literals.
  In OData 3 (pass `protocol: :odata3` or `odata3: true`), GUIDs are formatted as `guid'{guid}'`.
  """
  @spec filter_guid(t(), String.t() | atom(), any(), keyword()) :: t()
  def filter_guid(%__MODULE__{} = query, field, guid, opts \\ []) do
    and_filter(query, "#{field} eq #{format_guid_literal(guid, opts)}")
  end

  @doc """
  Adds a GUID equality condition combined with `or` (`{field} eq {guid}`).
  """
  @spec or_filter_guid(t(), String.t() | atom(), any(), keyword()) :: t()
  def or_filter_guid(%__MODULE__{} = query, field, guid, opts \\ []) do
    or_filter(query, "#{field} eq #{format_guid_literal(guid, opts)}")
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
  def order_by(%__MODULE__{orderby_rev: rev} = query, order_expr) when is_list(order_expr) do
    next_rev =
      Enum.reduce(order_expr, rev, fn
        {col, dir}, a -> ["#{col} #{dir}" | a]
        col, a -> prepend_non_empty(to_string(col), a)
      end)

    %__MODULE__{query | orderby_rev: next_rev}
  end

  def order_by(%__MODULE__{orderby_rev: rev} = query, order_expr)
      when is_binary(order_expr) or is_atom(order_expr) do
    %__MODULE__{query | orderby_rev: prepend_non_empty(to_string(order_expr), rev)}
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
  def top(%__MODULE__{custom_params: params} = query, n) when is_integer(n) and n >= 0 do
    %__MODULE__{query | top: n, custom_params: Map.delete(params, "$top")}
  end

  @doc """
  Specifies number of records to skip (`$skip`).
  """
  @spec skip(t(), non_neg_integer()) :: t()
  def skip(%__MODULE__{custom_params: params} = query, n) when is_integer(n) and n >= 0 do
    %__MODULE__{query | skip: n, custom_params: Map.delete(params, "$skip")}
  end

  @doc """
  Specifies navigation properties to expand (`$expand`).
  Can be called multiple times to accumulate properties.
  """
  @spec expand(t(), [String.t() | atom()] | String.t() | atom()) :: t()
  def expand(%__MODULE__{expand_rev: rev} = query, nav_props) when is_list(nav_props) do
    next_rev = Enum.reduce(nav_props, rev, &prepend_split_tokens(&1, &2))
    %__MODULE__{query | expand_rev: next_rev}
  end

  def expand(%__MODULE__{} = query, nav_prop) when is_binary(nav_prop) or is_atom(nav_prop) do
    expand(query, [nav_prop])
  end

  @doc """
  Toggles whether to request total inline count (`$count=true`).
  """
  @spec count(t(), boolean()) :: t()
  def count(%__MODULE__{} = query, enabled? \\ true) when is_boolean(enabled?) do
    %__MODULE__{query | count: enabled?}
  end

  @doc """
  Adds an arbitrary custom query parameter.
  """
  @spec param(t(), String.t() | atom(), any()) :: t()
  def param(%__MODULE__{custom_params: params} = query, key, value) do
    key_str = to_string(key)
    next_params = Map.put(params, key_str, to_string(value))

    case key_str do
      "$top" -> %__MODULE__{query | top: nil, custom_params: next_params}
      "$skip" -> %__MODULE__{query | skip: nil, custom_params: next_params}
      _ -> %__MODULE__{query | custom_params: next_params}
    end
  end

  @doc """
  Returns the target OData entity collection name configured on the query.

  ## Examples

      iex> Creatio.OData.Query.new("Contact") |> Creatio.OData.Query.entity()
      "Contact"

  """
  @spec entity(t()) :: String.t()
  def entity(%__MODULE__{entity: entity}), do: entity

  @doc """
  Returns the configured `$top` limit on the query, or `nil` if unset.

  ## Examples

      iex> Creatio.OData.Query.new("Contact") |> Creatio.OData.Query.top(25) |> Creatio.OData.Query.get_top()
      25

  """
  @spec get_top(t()) :: non_neg_integer() | nil
  def get_top(%__MODULE__{top: top_val, custom_params: custom_params}) do
    parse_non_neg_custom_param(custom_params["$top"]) || top_val
  end

  @doc """
  Returns the configured `$skip` offset on the query, or `nil` if unset.

  ## Examples

      iex> Creatio.OData.Query.new("Contact") |> Creatio.OData.Query.skip(50) |> Creatio.OData.Query.get_skip()
      50

  """
  @spec get_skip(t()) :: non_neg_integer() | nil
  def get_skip(%__MODULE__{skip: skip_val, custom_params: custom_params}) do
    parse_non_neg_custom_param(custom_params["$skip"]) || skip_val
  end

  defp parse_non_neg_custom_param(val) when is_integer(val) and val >= 0, do: val

  defp parse_non_neg_custom_param(val) when is_binary(val) do
    case Integer.parse(String.trim(val)) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end

  defp parse_non_neg_custom_param(_), do: nil

  @doc false
  @spec require_entity!(t(), String.t()) :: String.t()
  def require_entity!(%__MODULE__{entity: entity}, fun_name) when is_binary(entity) do
    Validation.require_entity_name!(entity, fun_name)
  end

  def require_entity!(other, fun_name) do
    raise ArgumentError,
          "expected a non-empty entity name binary or %Creatio.OData.Query{} in #{fun_name}, got: #{inspect(other)}"
  end

  @doc false
  @spec has_select?(t()) :: boolean()
  def has_select?(%__MODULE__{select_rev: rev}), do: rev != []

  @doc false
  @spec reset_stream_target(t()) :: t()
  def reset_stream_target(%__MODULE__{custom_params: custom_params} = query) do
    %__MODULE__{
      query
      | count: false,
        top: nil,
        skip: nil,
        custom_params: Map.drop(custom_params, ["$count", "$inlinecount", "$top", "$skip"])
    }
  end

  @doc false
  @spec strip_filter_and_order(t()) :: t()
  def strip_filter_and_order(%__MODULE__{custom_params: custom_params} = query) do
    %__MODULE__{
      query
      | filters_rev: [],
        orderby_rev: [],
        custom_params: Map.drop(custom_params, ["$filter", "$orderby"])
    }
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
    %{}
    |> maybe_put_csv("$select", finalize_list(query.select_rev))
    |> maybe_put_str("$filter", compile_filter(query))
    |> maybe_put_csv("$orderby", finalize_list(query.orderby_rev))
    |> maybe_put_str("$top", query.top && to_string(query.top))
    |> maybe_put_str("$skip", query.skip && to_string(query.skip))
    |> maybe_put_csv("$expand", finalize_list(query.expand_rev))
    |> maybe_put_str("$count", if(query.count, do: "true", else: nil))
    |> Map.merge(query.custom_params)
  end

  defp compile_filter(%__MODULE__{filters_rev: []}), do: nil
  defp compile_filter(%__MODULE__{filters_rev: [single]}), do: single

  defp compile_filter(%__MODULE__{filters_rev: rev}) do
    rev
    |> Enum.reverse()
    |> Enum.map_join(" and ", &wrap_if_contains_or/1)
  end

  defp wrap_if_contains_or(expr) do
    trimmed = String.trim(expr)

    if contains_or_outside_quotes?(trimmed) and not wrapped_in_outer_parens?(trimmed) do
      "(#{expr})"
    else
      expr
    end
  end

  defp contains_or_outside_quotes?(expr) do
    expr
    |> replace_quoted_literals(<<>>)
    |> then(&Regex.match?(~r/(?:\A|[\s()])or(?:\z|[\s()])/i, &1))
  end

  defp replace_quoted_literals(<<"'", rest::binary>>, acc) do
    skip_quoted_literal(rest, <<acc::binary, " ">>)
  end

  defp replace_quoted_literals(<<char, rest::binary>>, acc) do
    replace_quoted_literals(rest, <<acc::binary, char>>)
  end

  defp replace_quoted_literals(<<>>, acc), do: acc

  defp skip_quoted_literal(<<"''", rest::binary>>, acc), do: skip_quoted_literal(rest, acc)
  defp skip_quoted_literal(<<"'", rest::binary>>, acc), do: replace_quoted_literals(rest, acc)
  defp skip_quoted_literal(<<_, rest::binary>>, acc), do: skip_quoted_literal(rest, acc)
  defp skip_quoted_literal(<<>>, acc), do: acc

  # Verifies an opening '(' at byte 0 stays open until the final byte (not "(a) or (b)"),
  # ignoring parentheses inside single-quoted OData string literals (including escaped '').
  defp wrapped_in_outer_parens?(<<"(", rest::binary>>) do
    paren_depth_closes_at_end?(rest, 1, false)
  end

  defp wrapped_in_outer_parens?(_), do: false

  defp paren_depth_closes_at_end?(<<"''", rest::binary>>, depth, true),
    do: paren_depth_closes_at_end?(rest, depth, true)

  defp paren_depth_closes_at_end?(<<"'", rest::binary>>, depth, in_quotes?),
    do: paren_depth_closes_at_end?(rest, depth, not in_quotes?)

  defp paren_depth_closes_at_end?(<<")">>, 1, false), do: true
  defp paren_depth_closes_at_end?(<<")", _::binary>>, 1, false), do: false

  defp paren_depth_closes_at_end?(<<"(", rest::binary>>, depth, false),
    do: paren_depth_closes_at_end?(rest, depth + 1, false)

  defp paren_depth_closes_at_end?(<<")", rest::binary>>, depth, false) when depth > 1,
    do: paren_depth_closes_at_end?(rest, depth - 1, false)

  defp paren_depth_closes_at_end?(<<_, rest::binary>>, depth, in_quotes?),
    do: paren_depth_closes_at_end?(rest, depth, in_quotes?)

  defp paren_depth_closes_at_end?(<<>>, _depth, _in_quotes?), do: false

  defp prepend_split_tokens(item, acc) do
    item
    |> to_string()
    |> split_top_level_commas()
    |> Enum.reduce(acc, fn tok, a -> prepend_non_empty(tok, a) end)
  end

  defp split_top_level_commas(""), do: []

  defp split_top_level_commas(str) when is_binary(str) do
    do_split_top_level_commas(str, 0, 0, 0, false, [])
  end

  defp do_split_top_level_commas(str, pos, start, _depth, _in_quotes?, acc)
       when pos == byte_size(str) do
    tail = str |> binary_part(start, pos - start) |> String.trim()
    acc = if tail == "", do: acc, else: [tail | acc]
    Enum.reverse(acc)
  end

  defp do_split_top_level_commas(str, pos, start, depth, in_quotes?, acc) do
    byte = :binary.at(str, pos)

    cond do
      byte == ?' ->
        do_split_top_level_commas(str, pos + 1, start, depth, not in_quotes?, acc)

      not in_quotes? and byte == ?( ->
        do_split_top_level_commas(str, pos + 1, start, depth + 1, false, acc)

      not in_quotes? and byte == ?) ->
        do_split_top_level_commas(str, pos + 1, start, max(depth - 1, 0), false, acc)

      not in_quotes? and byte == ?, and depth == 0 ->
        chunk = str |> binary_part(start, pos - start) |> String.trim()
        next_acc = if chunk == "", do: acc, else: [chunk | acc]
        do_split_top_level_commas(str, pos + 1, pos + 1, 0, false, next_acc)

      true ->
        do_split_top_level_commas(str, pos + 1, start, depth, in_quotes?, acc)
    end
  end

  defp prepend_non_empty("", acc), do: acc
  defp prepend_non_empty(str, acc), do: [str | acc]

  defp finalize_list(rev) do
    rev
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp maybe_put_csv(map, _key, []), do: map
  defp maybe_put_csv(map, key, list), do: Map.put(map, key, Enum.join(list, ","))

  defp maybe_put_str(map, _key, nil), do: map
  defp maybe_put_str(map, _key, ""), do: map
  defp maybe_put_str(map, key, val), do: Map.put(map, key, val)

  defp build_in_conditions(field, values, opts) do
    values
    |> Enum.uniq()
    |> Enum.map(fn val -> "#{field} eq #{format_literal(val, opts)}" end)
  end

  defp extract_day_number(%{day: day}) when is_integer(day), do: day
  defp extract_day_number(val), do: val

  defp validate_comparison_op!(op) do
    op_str = to_string(op)

    if op_str in @valid_comparison_ops do
      op_str
    else
      raise ArgumentError,
            "invalid OData comparison operator #{inspect(op)}, expected one of: #{Enum.join(@valid_comparison_ops, ", ")}"
    end
  end

  defp escape_single_quotes(val), do: val |> to_string() |> String.replace("'", "''")

  defp format_literal(nil, _opts), do: "null"
  defp format_literal(true, _opts), do: "true"
  defp format_literal(false, _opts), do: "false"

  defp format_literal(%DateTime{} = val, opts) do
    if odata3?(opts), do: "datetime'#{DateTime.to_iso8601(val)}'", else: DateTime.to_iso8601(val)
  end

  defp format_literal(%NaiveDateTime{} = val, opts) do
    if odata3?(opts),
      do: "datetime'#{NaiveDateTime.to_iso8601(val)}'",
      else: NaiveDateTime.to_iso8601(val) <> "Z"
  end

  defp format_literal(%Date{} = val, opts) do
    if odata3?(opts),
      do: "datetime'#{Date.to_iso8601(val)}T00:00:00'",
      else: Date.to_iso8601(val)
  end

  defp format_literal(%Time{} = val, opts) do
    if odata3?(opts), do: "time'#{Time.to_iso8601(val)}'", else: Time.to_iso8601(val)
  end

  defp format_literal(val, opts) when is_integer(val) or is_float(val) do
    if Keyword.get(opts, :quoted, false), do: "'#{val}'", else: to_string(val)
  end

  defp format_literal(val, opts) do
    str = to_string(val)

    cond do
      Keyword.get(opts, :guid, false) or Keyword.get(opts, :type) == :guid ->
        format_guid_literal(val, opts)

      byte_size(str) >= 6 and String.downcase(binary_part(str, 0, 5)) == "guid'" and
          String.ends_with?(str, "'") ->
        "guid'#{Validation.clean_guid(str)}'"

      Keyword.get(opts, :quoted, true) ->
        "'#{escape_single_quotes(str)}'"

      true ->
        str
    end
  end

  defp format_guid_literal(guid, opts) do
    clean = Validation.clean_guid(guid)
    if odata3?(opts), do: "guid'#{clean}'", else: clean
  end

  defp odata3?(opts),
    do: Keyword.get(opts, :protocol) == :odata3 or Keyword.get(opts, :odata3, false)
end
