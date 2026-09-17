defmodule Creatio.Util do
  @moduledoc false

  @doc """
  Sanitizes a GUID string by removing braces, quotes, and whitespace.
  """
  def clean_guid(guid) do
    guid
    |> to_string()
    |> String.trim()
    |> String.replace_prefix("guid'", "")
    |> String.replace_suffix("'", "")
    |> String.replace_prefix("{", "")
    |> String.replace_suffix("}", "")
    |> String.replace_prefix("'", "")
    |> String.replace_suffix("'", "")
    |> String.trim()
  end
end
