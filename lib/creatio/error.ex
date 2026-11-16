defmodule Creatio.Error do
  @moduledoc """
  Standard error struct and exception for the Creatio SDK.
  """

  @max_raw_message_bytes 512

  @sensitive_headers MapSet.new([
                       "authorization",
                       "cookie",
                       "set-cookie",
                       "bpmcsrf",
                       "x-api-key",
                       "proxy-authorization"
                     ])

  @derive {Inspect, except: [:response]}
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

    sanitized_resp = %Req.Response{resp | headers: sanitize_headers(resp.headers)}

    %__MODULE__{
      status: status,
      code: code,
      message: final_message,
      details: details,
      response: sanitized_resp
    }
  end

  def from_response(other) do
    %__MODULE__{
      message: inspect(other),
      response: other
    }
  end

  @doc false
  @spec sanitize_headers(map() | [{String.t() | atom(), any()}] | any()) ::
          map() | [{String.t() | atom(), any()}] | any()
  def sanitize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {k, v} ->
      if sensitive_header?(k), do: {k, redact_header_value(v)}, else: {k, v}
    end)
  end

  def sanitize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, v} ->
        if sensitive_header?(k), do: {k, redact_header_value(v)}, else: {k, v}

      other ->
        other
    end)
  end

  def sanitize_headers(other), do: other

  defp sensitive_header?(key) do
    key_down = key |> to_string() |> String.downcase()
    MapSet.member?(@sensitive_headers, key_down)
  end

  defp redact_header_value(vals) when is_list(vals), do: Enum.map(vals, fn _ -> "[REDACTED]" end)
  defp redact_header_value(nil), do: nil
  defp redact_header_value(_val), do: "[REDACTED]"

  defp parse_error_body(%{"d" => %{"error" => _} = inner}) do
    parse_error_body(inner)
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

  defp parse_error_body(%{"Exception" => %{} = ex} = body) do
    msg =
      first_non_blank([
        body["Message"],
        body["message"],
        body["ExceptionMessage"],
        ex["Message"],
        ex["message"],
        ex["ExceptionMessage"]
      ])

    code =
      first_non_blank([
        ex["ErrorCode"],
        ex["errorCode"],
        ex["Code"],
        ex["code"],
        body["ErrorCode"],
        body["errorCode"],
        body["Code"],
        body["code"]
      ])

    {code, msg, ex}
  end

  defp parse_error_body(%{"errorInfo" => %{} = info} = body) when map_size(info) > 0 do
    extract_envelope_or_fallback(
      first_non_blank([info["errorCode"], info["ErrorCode"]]),
      first_non_blank([info["message"], info["Message"]]),
      info,
      body,
      "errorInfo"
    )
  end

  defp parse_error_body(%{"ErrorInfo" => %{} = info} = body) when map_size(info) > 0 do
    extract_envelope_or_fallback(
      first_non_blank([info["errorCode"], info["ErrorCode"]]),
      first_non_blank([info["message"], info["Message"]]),
      info,
      body,
      "ErrorInfo"
    )
  end

  defp parse_error_body(%{"responseStatus" => %{} = rs} = body) when map_size(rs) > 0 do
    extract_envelope_or_fallback(
      first_non_blank([rs["ErrorCode"], rs["errorCode"]]),
      first_non_blank([rs["Message"], rs["message"]]),
      rs,
      body,
      "responseStatus"
    )
  end

  defp parse_error_body(%{"ResponseStatus" => %{} = rs} = body) when map_size(rs) > 0 do
    extract_envelope_or_fallback(
      first_non_blank([rs["ErrorCode"], rs["errorCode"]]),
      first_non_blank([rs["Message"], rs["message"]]),
      rs,
      body,
      "ResponseStatus"
    )
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
    ex = body["Exception"]

    ex_msg =
      case ex do
        %{} ->
          first_non_blank([ex["Message"], ex["message"], ex["ExceptionMessage"]]) ||
            if(map_size(ex) > 0, do: inspect(ex), else: nil)

        bin when is_binary(bin) ->
          if(String.trim(bin) != "", do: bin, else: nil)

        _ ->
          nil
      end

    msg =
      first_non_blank([
        body["Message"],
        body["message"],
        body["ExceptionMessage"],
        ex_msg
      ])

    {code, if(is_binary(msg), do: msg, else: nil), ex}
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
    trimmed =
      body
      |> String.trim()
      |> String.trim_leading("\uFEFF")
      |> String.trim()

    if trimmed == "" do
      {nil, nil, nil}
    else
      case Jason.decode(trimmed) do
        {:ok, %{} = map} -> parse_error_body(map)
        _ -> {nil, truncate_preview(trimmed, @max_raw_message_bytes), nil}
      end
    end
  end

  defp parse_error_body(other) do
    {nil, inspect(other), nil}
  end

  defp extract_envelope_or_fallback(nil, nil, _envelope, body, envelope_key) do
    body |> Map.delete(envelope_key) |> parse_error_body()
  end

  defp extract_envelope_or_fallback(code, msg, envelope, _body, _envelope_key) do
    {code, msg, envelope}
  end

  defp truncate_preview(bin, max_bytes) when byte_size(bin) <= max_bytes, do: bin

  defp truncate_preview(bin, max_bytes) do
    prefix = binary_part(bin, 0, max_bytes) |> valid_utf8_prefix()
    prefix <> "... [truncated #{byte_size(bin)} bytes]"
  end

  defp valid_utf8_prefix(bin) do
    if String.valid?(bin) do
      bin
    else
      bin
      |> String.chunk(:valid)
      |> Enum.take_while(&String.valid?/1)
      |> IO.iodata_to_binary()
    end
  end

  defp first_non_blank(values) do
    Enum.find(values, fn
      nil -> false
      val when is_binary(val) -> String.trim(val) != ""
      _ -> true
    end)
  end
end
