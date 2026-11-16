defmodule Creatio.Batch.Response do
  @moduledoc """
  Individual response item inside a batch response.
  """

  alias Creatio.Error

  defstruct [:id, :status, :headers, :body, :atomicity_group]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: integer() | String.t() | nil,
          headers: map(),
          body: any(),
          atomicity_group: String.t() | nil
        }

  @doc """
  Returns `true` if the batch response status is in the 2xx range.
  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: status}) do
    case normalize_status(status) do
      int when is_integer(int) -> int in 200..299
      _ -> false
    end
  end

  def success?(_), do: false

  @doc """
  Returns `true` if the batch response represents a failure (status not in 2xx).
  """
  @spec error?(t()) :: boolean()
  def error?(%__MODULE__{} = resp), do: not success?(resp)

  @doc """
  Converts a failed batch response item into a `%Creatio.Error{}`.
  """
  @spec to_error(t()) :: Error.t()
  def to_error(%__MODULE__{} = resp) do
    Error.from_response(%Req.Response{
      status: normalize_status(resp.status),
      headers: normalize_req_headers(resp.headers),
      body: resp.body
    })
  end

  defp normalize_status(status) when is_integer(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case Integer.parse(String.trim(status)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_status(_), do: nil

  defp normalize_req_headers(nil), do: %{}

  defp normalize_req_headers(headers) when is_map(headers) do
    Map.new(headers, fn {k, v} ->
      {k |> to_string() |> String.downcase(), normalize_header_vals(v)}
    end)
  end

  defp normalize_req_headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {k, v}, acc ->
        Map.put(acc, k |> to_string() |> String.downcase(), normalize_header_vals(v))

      _, acc ->
        acc
    end)
  end

  defp normalize_req_headers(_), do: %{}

  defp normalize_header_vals(vals) when is_list(vals), do: Enum.map(vals, &to_string/1)
  defp normalize_header_vals(nil), do: []
  defp normalize_header_vals(val), do: [to_string(val)]
end
