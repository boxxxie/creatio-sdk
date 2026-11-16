defmodule Creatio.Validation do
  @moduledoc false

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

  @doc """
  Strips outer whitespace, braces, single quotes, and `guid'...'` wrappers (in any nesting order).
  """
  @spec strip_guid_syntax(any()) :: String.t()
  def strip_guid_syntax(guid) do
    guid
    |> to_string()
    |> do_strip_guid_syntax()
  end

  defp do_strip_guid_syntax(str) do
    trimmed = String.trim(str)

    unwrapped =
      trimmed
      |> strip_matching_wrapper("{", "}")
      |> strip_matching_wrapper("'", "'")
      |> strip_guid_prefix()
      |> strip_matching_wrapper("{", "}")
      |> strip_matching_wrapper("'", "'")
      |> String.trim()

    if unwrapped == trimmed, do: unwrapped, else: do_strip_guid_syntax(unwrapped)
  end

  defp strip_matching_wrapper(str, prefix, suffix) do
    str
    |> String.replace_prefix(prefix, "")
    |> String.replace_suffix(suffix, "")
  end

  defp strip_guid_prefix(str) do
    if byte_size(str) >= 5 and String.downcase(binary_part(str, 0, 5)) == "guid'" do
      str
      |> binary_part(5, byte_size(str) - 5)
      |> String.replace_suffix("'", "")
    else
      str
    end
  end

  @doc """
  Formats an OData record key segment according to protocol (`:odata4` or `:odata3`).

  - Integers serialize unquoted (`123`) in both OData 4 and OData 3.
  - UUIDs serialize unquoted in OData 4 (`uuid`) and as `guid'uuid'` in OData 3.
  - Non-UUID strings serialize single-quoted (`'CODE'`) in both OData 4 and OData 3.
  """
  @spec format_record_key(any(), :odata4 | :odata3) :: String.t()
  def format_record_key(id, protocol) when is_integer(id) and protocol in [:odata4, :odata3] do
    Integer.to_string(id)
  end

  def format_record_key(id, protocol)
      when (is_binary(id) or (is_atom(id) and id not in [nil, true, false])) and
             protocol in [:odata4, :odata3] do
    cleaned = clean_guid(id)

    cond do
      uuid_like?(cleaned) ->
        if protocol == :odata3, do: "guid'#{cleaned}'", else: cleaned

      true ->
        "'#{String.replace(cleaned, "'", "''")}'"
    end
  end

  def format_record_key(id, _protocol) do
    raise ArgumentError, "invalid record identifier: #{inspect(id)}"
  end

  @doc """
  Returns `true` if the binary is a canonical 36-character hex-and-hyphen UUID.
  """
  @spec uuid_like?(any()) :: boolean()
  def uuid_like?(bin) when is_binary(bin) and byte_size(bin) == 36 do
    Regex.match?(
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/,
      bin
    )
  end

  def uuid_like?(_), do: false

  @doc """
  Returns `true` if the identifier contains only safe record key characters and no traversal.
  """
  @spec valid_record_id?(any()) :: boolean()
  def valid_record_id?(id) when is_binary(id) do
    id != "" and
      id not in [".", ".."] and
      not String.contains?(id, "..") and
      Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, id)
  end

  def valid_record_id?(_), do: false

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

      Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, trimmed) ->
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

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, trimmed) do
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
  Normalizes a request path and rejects backslashes, traversal segments, and double-encoding.
  """
  @spec safe_normalized_path(String.t() | nil) :: {:ok, String.t()} | {:error, :invalid_path}
  def safe_normalized_path(nil), do: {:ok, ""}

  def safe_normalized_path(path) when is_binary(path) do
    if String.contains?(path, ["\\", "\r", "\n", <<0>>]) do
      {:error, :invalid_path}
    else
      decoded = URI.decode(path)

      if String.contains?(decoded, ["\\", "%", "..", "\r", "\n", <<0>>]) do
        {:error, :invalid_path}
      else
        segments = String.split(decoded, "/")

        if Enum.any?(segments, &(&1 in [".", ".."])) do
          {:error, :invalid_path}
        else
          {:ok, Regex.replace(~r{/+}, decoded, "/")}
        end
      end
    end
  end

  def safe_normalized_path(_), do: {:error, :invalid_path}

  @doc """
  Converts a keyword list or plain map of `:req_options` into a keyword list safely.
  """
  @spec to_keyword_opts(any()) :: keyword()
  def to_keyword_opts(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
    else
      raise ArgumentError,
            "expected :req_options to be a keyword list or plain map, got: #{inspect(list)}"
    end
  end

  def to_keyword_opts(map) when is_map(map) and not is_struct(map) do
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

  def to_keyword_opts(other) do
    raise ArgumentError,
          "expected :req_options to be a keyword list or plain map, got: #{inspect(other)}"
  end

  @doc """
  Extracts and cleans the MIME boundary parameter from a `Content-Type` header value.
  """
  @spec extract_boundary_from_header(String.t()) :: String.t() | nil
  def extract_boundary_from_header(header) when is_binary(header) do
    case Regex.run(~r/boundary="?([^";\s\r\n]+)"?/i, header) do
      [_, boundary] -> clean_boundary_str(boundary)
      _ -> nil
    end
  end

  def extract_boundary_from_header(_), do: nil

  @doc """
  Cleans quotes and whitespace from a multipart boundary string.
  """
  @spec clean_boundary_str(String.t()) :: String.t()
  def clean_boundary_str(boundary) when is_binary(boundary) do
    boundary |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  @doc """
  Splits a `multipart/mixed` body on exact RFC 2046 boundary delimiter lines (`--boundary`
  and closing `--boundary--`), avoiding prefix collisions with boundaries like `--boundary_2`
  and ignoring any post-epilogue content after the closing delimiter.
  """
  @spec split_multipart_parts(String.t(), String.t()) :: [String.t()]
  def split_multipart_parts(body, boundary) when is_binary(body) and is_binary(boundary) do
    clean_boundary = clean_boundary_str(boundary)

    if clean_boundary == "" do
      []
    else
      pattern =
        ~r/(?:\r\n|\n|\A)--#{Regex.escape(clean_boundary)}(?:--)?[ \t]*(?=\r\n|\n|\z)/

      case Regex.split(pattern, body, include_captures: true) do
        [_preamble | rest] -> collect_open_parts(rest, [])
        _ -> []
      end
    end
  end

  defp collect_open_parts([delimiter, content | rest], acc) do
    if String.ends_with?(String.trim_trailing(delimiter), "--") do
      Enum.reverse(acc)
    else
      collect_open_parts(rest, [content | acc])
    end
  end

  defp collect_open_parts(_other, acc), do: Enum.reverse(acc)
end
