defmodule Creatio.Error do
  @moduledoc """
  Standard error struct and exception for the Creatio SDK.
  """
  defexception [:message, :status, :code, :details, :response]

  @type t :: %__MODULE__{
          message: String.t() | nil,
          status: integer() | nil,
          code: String.t() | integer() | nil,
          details: any(),
          response: any()
        }

  @impl true
  def message(%__MODULE__{message: msg}) when is_binary(msg) and msg != "", do: msg

  def message(%__MODULE__{code: code, status: status})
      when not is_nil(code) and not is_nil(status),
      do: "Creatio error #{code} (HTTP #{status})"

  def message(%__MODULE__{status: status}) when not is_nil(status), do: "HTTP #{status}"
  def message(%__MODULE__{code: code}) when not is_nil(code), do: "Creatio error: #{code}"
  def message(%__MODULE__{}), do: "Creatio error"

  @doc """
  Constructs a new `Creatio.Error` struct from keywords.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct(__MODULE__, opts)
  end

  @doc """
  Wraps an exception or preserves an existing `%Creatio.Error{}` into `{:error, %Creatio.Error{}}`.
  """
  @spec wrap_error(any()) :: {:error, t()}
  def wrap_error(%__MODULE__{} = error), do: {:error, error}

  def wrap_error(exception) when is_exception(exception) do
    {:error, new(message: Exception.message(exception), details: exception)}
  end

  def wrap_error(other) do
    {:error, new(message: inspect(other), details: other)}
  end

  @doc """
  Constructs a `Creatio.Error` from a `Req.Response`.
  """
  @spec from_response(Req.Response.t() | any()) :: t()
  def from_response(%Req.Response{} = resp) do
    body = resp.body
    status = resp.status

    {code, message, details} = parse_error_body(body)

    final_message =
      if is_binary(message) and String.trim(message) != "" do
        message
      else
        "HTTP #{status}"
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
    code = first_non_blank([err["code"], err["Code"], err["errorCode"], err["ErrorCode"]])
    raw_msg = err["message"] || err["Message"]

    msg =
      case raw_msg do
        %{"value" => v} when is_binary(v) ->
          v

        v when is_binary(v) ->
          v

        v when not is_nil(v) ->
          inspect(v)

        _ ->
          first_non_blank([err["error_description"], code])
      end

    details = err["innererror"] || err["innerError"]
    {code, msg, details}
  end

  defp parse_error_body(%{"error" => err, "error_description" => desc}) do
    {err, desc, nil}
  end

  defp parse_error_body(%{"error" => err}) when is_binary(err) do
    {err, err, nil}
  end

  defp parse_error_body(%{"error_description" => desc} = body) when is_binary(desc) do
    code = first_non_blank([body["code"], body["Code"], body["errorCode"], body["ErrorCode"]])
    {code, desc, nil}
  end

  defp parse_error_body(%{"Exception" => %{} = ex}) do
    msg = first_non_blank([ex["Message"], ex["message"], ex["ExceptionMessage"]])
    code = first_non_blank([ex["ErrorCode"], ex["errorCode"], ex["Code"], ex["code"]])
    {code, msg, ex}
  end

  defp parse_error_body(%{"errorInfo" => %{} = info}) do
    msg = first_non_blank([info["message"], info["Message"]])
    code = first_non_blank([info["errorCode"], info["ErrorCode"]])
    {code, msg, info}
  end

  defp parse_error_body(%{"ErrorInfo" => %{} = info}) do
    msg = first_non_blank([info["message"], info["Message"]])
    code = first_non_blank([info["errorCode"], info["ErrorCode"]])
    {code, msg, info}
  end

  defp parse_error_body(%{"responseStatus" => %{} = rs}) do
    msg = first_non_blank([rs["Message"], rs["message"]])
    code = first_non_blank([rs["ErrorCode"], rs["errorCode"]])
    {code, msg, rs}
  end

  defp parse_error_body(%{"ResponseStatus" => %{} = rs}) do
    msg = first_non_blank([rs["Message"], rs["message"]])
    code = first_non_blank([rs["ErrorCode"], rs["errorCode"]])
    {code, msg, rs}
  end

  defp parse_error_body(%{"success" => val} = body)
       when is_map(body) and val in [false, "false"] do
    msg =
      first_non_blank([
        body["message"],
        body["Message"],
        "DataService query execution failed (success: false)"
      ])

    code = first_non_blank([body["errorCode"], body["ErrorCode"], body["Code"], body["code"]])
    {code, msg, body}
  end

  defp parse_error_body(%{"Success" => val} = body)
       when is_map(body) and val in [false, "false"] do
    msg =
      first_non_blank([
        body["message"],
        body["Message"],
        "DataService query execution failed (success: false)"
      ])

    code = first_non_blank([body["errorCode"], body["ErrorCode"], body["Code"], body["code"]])
    {code, msg, body}
  end

  defp parse_error_body(%{"Code" => code} = body) when is_map(body) do
    msg = first_non_blank([body["Message"], body["ExceptionMessage"], body["Exception"]])
    {code, msg, body["Exception"]}
  end

  defp parse_error_body(%{"Message" => msg} = body) when is_map(body) do
    code = first_non_blank([body["Code"], body["code"], body["errorCode"], body["ErrorCode"]])
    {code, msg, body["Exception"]}
  end

  defp parse_error_body(%{"ExceptionMessage" => msg} = body) when is_map(body) do
    code = first_non_blank([body["Code"], body["code"], body["errorCode"], body["ErrorCode"]])
    {code, msg, body["Exception"]}
  end

  defp parse_error_body(%{"message" => %{"value" => msg}} = body) when is_binary(msg) do
    code = first_non_blank([body["code"], body["Code"], body["errorCode"], body["ErrorCode"]])
    {code, msg, nil}
  end

  defp parse_error_body(%{"message" => msg} = body) when is_binary(msg) do
    code = first_non_blank([body["code"], body["Code"], body["errorCode"], body["ErrorCode"]])
    {code, msg, nil}
  end

  defp parse_error_body(body) when is_binary(body) do
    trimmed = String.trim(body)

    if trimmed == "" do
      {nil, nil, nil}
    else
      case Jason.decode(trimmed) do
        {:ok, %{} = map} -> parse_error_body(map)
        _ -> {nil, trimmed, nil}
      end
    end
  end

  defp parse_error_body(other) do
    {nil, inspect(other), nil}
  end

  defp first_non_blank(values) do
    Enum.find(values, fn
      nil -> false
      val when is_binary(val) -> String.trim(val) != ""
      _ -> true
    end)
  end
end
