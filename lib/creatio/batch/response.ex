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
  def success?(%__MODULE__{status: status}) when is_integer(status), do: status in 200..299
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
      status: resp.status,
      headers: resp.headers || %{},
      body: resp.body
    })
  end
end
