defmodule Creatio.Error do
  @moduledoc """
  Standard error struct and exception for the Creatio SDK.
  """
  defexception [:message, :status, :code, :details, :response]

  @type t :: %__MODULE__{
          message: String.t(),
          status: integer() | nil,
          code: String.t() | integer() | nil,
          details: any(),
          response: any()
        }

  @doc """
  Constructs a new `Creatio.Error` struct from keywords.
  """
  def new(opts) when is_list(opts) do
    struct(__MODULE__, opts)
  end

  @doc """
  Constructs a `Creatio.Error` from a `Req.Response`.
  """
  def from_response(%Req.Response{} = resp) do
    body = resp.body
    status = resp.status

    {code, message, details} = parse_error_body(body)

    final_message =
      cond do
        is_binary(message) and String.trim(message) != "" -> message
        true -> "HTTP #{status}"
      end

    %__MODULE__{
      status: status,
      code: code,
      message: final_message,
      details: details,
      response: resp
    }
  end

  def from_response(other) do
    %__MODULE__{
      message: inspect(other),
      response: other
    }
  end

  defp parse_error_body(%{"error" => %{} = err}) do
    msg =
      case err["message"] do
        %{"value" => v} when is_binary(v) -> v
        v when is_binary(v) -> v
        v when not is_nil(v) -> inspect(v)
        _ -> err["error_description"] || err["code"]
      end

    {err["code"], msg, err["innererror"]}
  end

  defp parse_error_body(%{"error" => err, "error_description" => desc}) do
    {err, desc, nil}
  end

  defp parse_error_body(%{"error" => err}) when is_binary(err) do
    {err, err, nil}
  end

  defp parse_error_body(%{"Code" => code} = body) when is_map(body) do
    msg = body["Message"] || body["Exception"] || body["ExceptionMessage"]
    {code, msg, body["Exception"]}
  end

  defp parse_error_body(%{"Message" => msg} = body) when is_map(body) do
    {body["Code"], msg, body["Exception"]}
  end

  defp parse_error_body(%{"ExceptionMessage" => msg} = body) when is_map(body) do
    {body["Code"], msg, body["Exception"]}
  end

  defp parse_error_body(%{"message" => %{"value" => msg}} = body) when is_binary(msg) do
    {body["code"], msg, nil}
  end

  defp parse_error_body(%{"message" => msg} = body) when is_binary(msg) do
    {body["code"], msg, nil}
  end

  defp parse_error_body(body) when is_binary(body) do
    trimmed = String.trim(body)
    if trimmed == "", do: {nil, nil, nil}, else: {nil, trimmed, nil}
  end

  defp parse_error_body(other) do
    {nil, inspect(other), nil}
  end
end
