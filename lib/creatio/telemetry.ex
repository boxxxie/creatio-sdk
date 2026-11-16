defmodule Creatio.Telemetry do
  @moduledoc """
  Telemetry instrumentation and credential redaction for `Creatio`.

  Emits standard `:telemetry` events for HTTP requests as well as domain-level
  `:telemetry.span/3` events across OData 4, OData 3, DataService, Auth, and Batch
  without requiring any runtime background processes or GenServers.

  ## Emitted Events

  ### HTTP Requests (`Creatio.Client`)
    * `[:creatio, :request, :start]`
      * Measurements: `%{system_time: integer(), monotonic_time: integer()}`
      * Metadata: `%{method: atom(), path: String.t(), base_url: String.t(), auth_mode: atom() | nil, headers: map()}`
    * `[:creatio, :request, :stop]`
      * Measurements: `%{duration: integer(), monotonic_time: integer()}`
      * Metadata: `%{method: atom(), path: String.t(), base_url: String.t(), auth_mode: atom() | nil, headers: map(), status: integer(), result: :ok | :error, error: nil}`
    * `[:creatio, :request, :exception]`
      * Measurements: `%{duration: integer(), monotonic_time: integer()}`
      * Metadata: `%{method: atom(), path: String.t(), base_url: String.t(), auth_mode: atom() | nil, headers: map(), status: integer() | nil, kind: :error, reason: any(), error: any(), stacktrace: list(), result: :error}`
      * Note: emitted for handled `{:error, exception}` transport or `read_only_guard` failures returned by `Req` (with `stacktrace: []`), whereas domain spans below emit `:stop` (`result: :error`) for `{:error, _}` return values and reserve `:exception` for raised/thrown exceptions.

  ### OData 4 Operations (`Creatio.OData`)
    * `[:creatio, :odata, :start | :stop | :exception]`
      * Measurements: `%{system_time: integer()}` on `:start`, `%{duration: integer()}` on `:stop | :exception`
      * Metadata: `%{protocol: :odata4, action: atom(), entity: String.t(), base_url: String.t(), result: :ok | :error, status: :ok | :error, error: any()}`

  ### OData 3 Operations (`Creatio.OData3`)
    * `[:creatio, :odata3, :start | :stop | :exception]`
      * Measurements: `%{system_time: integer()}` on `:start`, `%{duration: integer()}` on `:stop | :exception`
      * Metadata: `%{protocol: :odata3, action: atom(), entity: String.t(), base_url: String.t(), result: :ok | :error, status: :ok | :error, error: any()}`

  ### DataService & Custom REST (`Creatio.DataService`)
    * `[:creatio, :data_service, :start | :stop | :exception]`
      * Measurements: `%{system_time: integer()}` on `:start`, `%{duration: integer()}` on `:stop | :exception`
      * Metadata: `%{action: String.t() | :custom_service, entity: String.t() | nil, service: String.t() | nil, endpoint: String.t() | nil, method: atom() | nil, base_url: String.t(), result: :ok | :error, status: :ok | :error, error: any()}`

  ### Authentication (`Creatio.Auth`)
    * `[:creatio, :auth, :start | :stop | :exception]`
      * Measurements: `%{system_time: integer()}` on `:start`, `%{duration: integer()}` on `:stop | :exception`
      * Metadata: `%{auth_mode: :forms | :oauth | :health_check | :openid_configuration, base_url: String.t(), result: :ok | :error, status: :ok | :error, error: any()}`

  ### Batch Execution (`Creatio.Batch`)
    * `[:creatio, :batch, :start | :stop | :exception]`
      * Measurements: `%{system_time: integer()}` on `:start`, `%{duration: integer()}` on `:stop | :exception`
      * Metadata: `%{format: :json | :multipart, operation_count: non_neg_integer(), base_url: String.t(), status: :ok | :error, result: :ok | :error, error: any(), error_count: non_neg_integer()}`

  ## Credential Redaction

  Sensitive headers (`authorization`, `cookie`, `set-cookie`, `bpmcsrf`, `x-api-key`,
  `proxy-authorization`) and credential metadata keys (`auth_token`, `client_secret`,
  `cookie`, `bpmcsrf`, `password`, `UserPassword`, `access_token`, `refresh_token`)
  are automatically redacted to `"[REDACTED]"` before any telemetry event is emitted.
  """

  alias Creatio.Error

  @max_redacted_body_bytes 4_096
  @max_sanitized_depth 4
  @max_sanitized_items 32

  @domains [:request, :odata, :odata3, :data_service, :auth, :batch]
  @stages [:start, :stop, :exception]

  @sensitive_meta_keys MapSet.new([
                         "auth_token",
                         "bearer_token",
                         "access_token",
                         "refresh_token",
                         "client_secret",
                         "cookie",
                         "set_cookie",
                         "set-cookie",
                         "bpmcsrf",
                         "password",
                         "user_password",
                         "userpassword",
                         "authorization",
                         "x_api_key",
                         "x-api-key"
                       ])

  @doc """
  Returns the full list of telemetry event names emitted by `Creatio`.
  """
  @spec events() :: [[atom()]]
  def events do
    for domain <- @domains, stage <- @stages, do: [:creatio, domain, stage]
  end

  @doc """
  Executes `fun` inside a telemetry span for the given domain atom or prefix list,
  sanitizing start metadata, enriching stop and exception metadata with `:result`,
  `:status`, and `:error`, and redacting sensitive data from raised exceptions
  and stacktraces.
  """
  @spec span(atom() | [atom()], map(), (-> result)) :: result when result: var
  def span(domain, start_metadata, fun) when is_atom(domain) do
    span([:creatio, domain], start_metadata, fun)
  end

  def span(event_prefix, start_metadata, fun)
      when is_list(event_prefix) and is_map(start_metadata) and is_function(fun, 0) do
    start_event = event_prefix ++ [:start]
    stop_event = event_prefix ++ [:stop]
    exc_event = event_prefix ++ [:exception]

    has_start? = :telemetry.list_handlers(start_event) != []
    has_stop? = :telemetry.list_handlers(stop_event) != []
    has_exc? = :telemetry.list_handlers(exc_event) != []

    if not has_start? and not has_stop? and not has_exc? do
      fun.()
    else
      sanitized_start = sanitize_metadata(start_metadata)
      span_ctx = make_ref()
      start_monotonic = System.monotonic_time()

      if has_start? do
        :telemetry.execute(
          start_event,
          %{monotonic_time: start_monotonic, system_time: System.system_time()},
          Map.put(sanitized_start, :telemetry_span_context, span_ctx)
        )
      end

      try do
        res = fun.()

        if has_stop? do
          stop_monotonic = System.monotonic_time()
          outcome = outcome_metadata(res)

          outcome =
            if event_prefix == [:creatio, :batch] and match?({:ok, _}, res) do
              Map.put_new(outcome, :error_count, 0)
            else
              outcome
            end

          stop_metadata =
            sanitized_start
            |> Map.merge(outcome)
            |> Map.put(:telemetry_span_context, span_ctx)

          :telemetry.execute(
            stop_event,
            %{duration: stop_monotonic - start_monotonic, monotonic_time: stop_monotonic},
            stop_metadata
          )
        end

        res
      catch
        kind, reason ->
          if has_exc? do
            stop_monotonic = System.monotonic_time()
            sanitized_reason = sanitize_error(reason)

            exception_metadata =
              sanitized_start
              |> Map.merge(%{
                result: :error,
                status: :error,
                error: sanitized_reason,
                kind: kind,
                reason: sanitized_reason,
                stacktrace: sanitize_stacktrace(__STACKTRACE__),
                telemetry_span_context: span_ctx
              })

            :telemetry.execute(
              exc_event,
              %{duration: stop_monotonic - start_monotonic, monotonic_time: stop_monotonic},
              exception_metadata
            )
          end

          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  @doc """
  Idempotently attaches `[:creatio, :request, *]` telemetry steps to a `Req.Request`.
  """
  @spec attach_req_steps(Req.Request.t()) :: Req.Request.t()
  def attach_req_steps(%Req.Request{} = req) do
    req
    |> attach_request_step()
    |> attach_response_step()
    |> attach_error_step()
  end

  @doc false
  @spec handle_req_start(Req.Request.t()) :: Req.Request.t()
  def handle_req_start(%Req.Request{} = req) do
    has_start? = :telemetry.list_handlers([:creatio, :request, :start]) != []
    has_stop? = :telemetry.list_handlers([:creatio, :request, :stop]) != []
    has_exc? = :telemetry.list_handlers([:creatio, :request, :exception]) != []

    if has_start? or has_stop? or has_exc? do
      start_time = System.monotonic_time()
      req = Req.Request.put_private(req, :creatio_telemetry_start, start_time)

      if has_start? do
        :telemetry.execute(
          [:creatio, :request, :start],
          %{system_time: System.system_time(), monotonic_time: start_time},
          build_req_metadata(req)
        )
      end

      req
    else
      req
    end
  end

  @doc false
  @spec handle_req_stop({Req.Request.t(), Req.Response.t()}) ::
          {Req.Request.t(), Req.Response.t()}
  def handle_req_stop({%Req.Request{} = req, %Req.Response{} = resp}) do
    case Req.Request.get_private(req, :creatio_telemetry_start) do
      start_time when is_integer(start_time) ->
        if :telemetry.list_handlers([:creatio, :request, :stop]) != [] do
          stop_time = System.monotonic_time()
          duration = max(stop_time - start_time, 0)

          meta =
            req
            |> build_req_metadata()
            |> Map.merge(%{
              status: resp.status,
              result: if(resp.status in 200..299, do: :ok, else: :error),
              error: nil
            })

          :telemetry.execute(
            [:creatio, :request, :stop],
            %{duration: duration, monotonic_time: stop_time},
            meta
          )
        end

        {rearm_request_step(req), resp}

      _ ->
        {req, resp}
    end
  end

  @doc false
  @spec handle_req_error({Req.Request.t(), Exception.t()}) :: {Req.Request.t(), Exception.t()}
  def handle_req_error({%Req.Request{} = req, exception}) do
    case Req.Request.get_private(req, :creatio_telemetry_start) do
      start_time when is_integer(start_time) ->
        if :telemetry.list_handlers([:creatio, :request, :exception]) != [] do
          stop_time = System.monotonic_time()
          duration = max(stop_time - start_time, 0)
          sanitized_exception = sanitize_error(exception)

          status =
            case exception do
              %{status: s} when is_integer(s) -> s
              _ -> nil
            end

          meta =
            req
            |> build_req_metadata()
            |> Map.merge(%{
              status: status,
              kind: :error,
              reason: sanitized_exception,
              error: sanitized_exception,
              stacktrace: [],
              result: :error
            })

          :telemetry.execute(
            [:creatio, :request, :exception],
            %{duration: duration, monotonic_time: stop_time},
            meta
          )
        end

        {rearm_request_step(req), exception}

      _ ->
        {req, exception}
    end
  end

  defp rearm_request_step(%Req.Request{current_request_steps: current, private: private} = req) do
    updated_steps =
      if :creatio_telemetry in current do
        current
      else
        [:creatio_telemetry | current]
      end

    %Req.Request{
      req
      | current_request_steps: updated_steps,
        private: Map.delete(private, :creatio_telemetry_start)
    }
  end

  @doc """
  Redacts sensitive values in HTTP headers (`authorization`, `cookie`, `set-cookie`,
  `bpmcsrf`, `x-api-key`, `proxy-authorization`).
  """
  @spec sanitize_headers(map() | [{String.t() | atom(), any()}]) ::
          map() | [{String.t() | atom(), any()}]
  def sanitize_headers(headers), do: Error.sanitize_headers(headers)

  @doc """
  Recursively sanitizes telemetry metadata maps, redacting sensitive credential keys,
  headers, and nested error responses.
  """
  @spec sanitize_metadata(map()) :: map()
  def sanitize_metadata(meta) when is_map(meta) and not is_struct(meta) do
    Map.new(meta, fn {k, v} ->
      {sanitize_map_key(k), sanitize_meta_entry(k, v)}
    end)
  end

  def sanitize_metadata(other), do: other

  defp sanitize_map_key(k) when is_atom(k) or is_binary(k) or is_number(k), do: k
  defp sanitize_map_key(k), do: sanitize_meta_value(k)

  defp safe_key_downcase(key) when is_binary(key), do: String.downcase(key)
  defp safe_key_downcase(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp safe_key_downcase(key) when is_number(key), do: to_string(key)
  defp safe_key_downcase(_key), do: ""

  defp sanitize_meta_entry(key, val) do
    key_down = safe_key_downcase(key)

    cond do
      key_down in ["headers", "req_headers", "resp_headers"] ->
        sanitize_headers(val)

      MapSet.member?(@sensitive_meta_keys, key_down) ->
        if is_nil(val), do: nil, else: "[REDACTED]"

      true ->
        sanitize_meta_value(val)
    end
  end

  defp sanitize_meta_value(%Error{} = err), do: sanitize_error(err)
  defp sanitize_meta_value(%Req.Response{} = resp), do: sanitize_response(resp)

  defp sanitize_meta_value(
         %Req.Request{headers: headers, options: options, body: body, url: url, private: priv} =
           req
       ) do
    %Req.Request{
      req
      | headers: sanitize_headers(headers),
        options: sanitize_metadata(options),
        url: sanitize_meta_value(url),
        private: if(priv == %{}, do: %{}, else: %{redacted: true}),
        body: if(is_nil(body), do: nil, else: "[REDACTED]")
    }
  end

  defp sanitize_meta_value(%URI{} = uri), do: sanitize_uri(uri)

  defp sanitize_meta_value(%{__struct__: mod} = struct)
       when mod not in [Date, DateTime, NaiveDateTime, Time, URI, Regex, MapSet] do
    sanitize_struct(struct)
  end

  defp sanitize_meta_value(val) when is_map(val) and not is_struct(val),
    do: sanitize_metadata(val)

  defp sanitize_meta_value(val) when is_list(val), do: sanitize_meta_list(val)

  defp sanitize_meta_value(val) when is_tuple(val) do
    val
    |> Tuple.to_list()
    |> Enum.map(&sanitize_meta_value/1)
    |> List.to_tuple()
  end

  defp sanitize_meta_value(val) when is_binary(val), do: redact_text_secrets(val)
  defp sanitize_meta_value(val), do: val

  defp sanitize_meta_list([]), do: []

  defp sanitize_meta_list([{k, v} | rest]) when is_atom(k) or is_binary(k) do
    [{k, sanitize_meta_entry(k, v)} | sanitize_meta_list(rest)]
  end

  defp sanitize_meta_list([head | rest]) do
    [sanitize_meta_value(head) | sanitize_meta_list(rest)]
  end

  defp sanitize_meta_list(improper_tail), do: sanitize_meta_value(improper_tail)

  defp sanitize_uri(%URI{userinfo: userinfo, path: path, query: query, fragment: fragment} = uri) do
    %URI{
      uri
      | userinfo: if(is_binary(userinfo), do: "[REDACTED]", else: nil),
        path: if(is_binary(path), do: redact_text_secrets(path), else: path),
        query: sanitize_uri_query(query),
        fragment: sanitize_uri_query(fragment)
    }
  end

  defp sanitize_uri_query(nil), do: nil

  defp sanitize_uri_query(query) when is_binary(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &sanitize_uri_query_pair/1)
    |> redact_text_secrets()
  end

  defp sanitize_uri_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [raw_key, _raw_val] ->
        key_down = raw_key |> safe_uri_decode() |> String.downcase()

        if MapSet.member?(@sensitive_meta_keys, key_down) do
          "#{raw_key}=[REDACTED]"
        else
          pair
        end

      _ ->
        pair
    end
  end

  defp safe_uri_decode(str) when is_binary(str) do
    URI.decode(str)
  rescue
    ArgumentError -> str
  end

  defp sanitize_struct(%{__struct__: _mod} = struct) do
    sanitized_fields =
      struct
      |> Map.from_struct()
      |> Map.new(fn
        {:__exception__, _} = pair -> pair
        {:message, msg} when is_binary(msg) -> {:message, redact_text_secrets(msg)}
        {k, v} -> {k, sanitize_meta_entry(k, v)}
      end)

    Map.merge(struct, sanitized_fields)
  end

  defp sanitize_error(%Error{message: message, response: resp, details: details} = err) do
    %Error{
      err
      | message: redact_text_secrets(message),
        response: sanitize_meta_value(resp),
        details: sanitize_meta_value(details)
    }
  end

  defp sanitize_error(other), do: sanitize_meta_value(other)

  defp sanitize_stacktrace(stack) when is_list(stack) do
    Enum.map(stack, fn
      {mod, fun, args, loc} when is_list(args) -> {mod, fun, length(args), loc}
      other -> other
    end)
  end

  defp redact_text_secrets(str) when is_binary(str) do
    if byte_size(str) > @max_redacted_body_bytes do
      prefix = truncate_utf8_prefix(str, @max_redacted_body_bytes)
      run_secret_redactions(prefix) <> "... [TRUNCATED #{byte_size(str)} bytes]"
    else
      run_secret_redactions(str)
    end
  end

  defp redact_text_secrets(other), do: other

  defp run_secret_redactions(str) do
    str
    |> String.replace(~r/\b(Bearer|Basic)\s+[A-Za-z0-9._~+\/-]+=*/i, "\\1 [REDACTED]")
    |> String.replace(
      ~r/(?<![A-Za-z0-9_])(BPMCSRF|BPMLOADER|\.ASPXAUTH|ASP\.NET_SessionId)=[^;\s,&"']+/i,
      "\\1=[REDACTED]"
    )
    |> String.replace(
      ~r/("?(?:auth_token|bearer_token|access_token|refresh_token|client_secret|cookie|bpmcsrf|password|user_password|userpassword)"?\s*(?::|=>)\s*)"(?:\\.|[^"\\])*\\?(?:"|\z)/i,
      "\\1\"[REDACTED]\""
    )
    |> String.replace(
      ~r/\b(auth_token|bearer_token|access_token|refresh_token|client_secret|bpmcsrf|password|user_password|userpassword)=[^\s,&;]+/i,
      "\\1=[REDACTED]"
    )
  end

  defp truncate_utf8_prefix(bin, max_bytes) do
    slice = binary_part(bin, 0, max_bytes)

    if String.valid?(slice) do
      slice
    else
      slice
      |> String.chunk(:valid)
      |> Enum.take_while(&String.valid?/1)
      |> IO.iodata_to_binary()
    end
  end

  defp sanitize_response(%Req.Response{headers: headers, body: body} = resp) do
    %Req.Response{
      resp
      | headers: sanitize_headers(headers),
        body: sanitize_response_body(body, 0)
    }
  end

  defp sanitize_response_body(_val, depth) when depth >= @max_sanitized_depth, do: "[TRUNCATED]"

  defp sanitize_response_body(val, _depth) when is_binary(val), do: redact_text_secrets(val)

  defp sanitize_response_body(val, depth) when is_map(val) and not is_struct(val) do
    entries = Enum.take(val, @max_sanitized_items)
    sanitized = Map.new(entries, &sanitize_response_entry(&1, depth))

    if map_size(val) > @max_sanitized_items do
      Map.put(sanitized, "__truncated__", map_size(val) - @max_sanitized_items)
    else
      sanitized
    end
  end

  defp sanitize_response_body(val, depth) when is_list(val) do
    sanitize_response_list(val, depth, 0)
  end

  defp sanitize_response_body(val, _depth), do: sanitize_meta_value(val)

  defp sanitize_response_list([], _depth, _count), do: []

  defp sanitize_response_list([_ | _] = list, _depth, count)
       when count >= @max_sanitized_items do
    ["[TRUNCATED #{count_remaining_items(list, 0)} items]"]
  end

  defp sanitize_response_list([{k, v} | rest], depth, count) when is_atom(k) or is_binary(k) do
    [sanitize_response_entry({k, v}, depth) | sanitize_response_list(rest, depth, count + 1)]
  end

  defp sanitize_response_list([head | rest], depth, count) do
    [sanitize_response_body(head, depth + 1) | sanitize_response_list(rest, depth, count + 1)]
  end

  defp sanitize_response_list(improper_tail, depth, _count) do
    sanitize_response_body(improper_tail, depth + 1)
  end

  defp count_remaining_items([], acc), do: acc
  defp count_remaining_items([_ | rest], acc), do: count_remaining_items(rest, acc + 1)
  defp count_remaining_items(_improper_tail, acc), do: acc + 1

  defp sanitize_response_entry({k, v}, depth) do
    key_down = safe_key_downcase(k)
    safe_k = sanitize_map_key(k)

    cond do
      key_down == "headers" ->
        {safe_k, sanitize_headers(v)}

      MapSet.member?(@sensitive_meta_keys, key_down) ->
        {safe_k, if(is_nil(v), do: nil, else: "[REDACTED]")}

      true ->
        {safe_k, sanitize_response_body(v, depth + 1)}
    end
  end

  defp outcome_metadata(:ok), do: %{result: :ok, status: :ok, error: nil}

  defp outcome_metadata({:ok, [%Creatio.Batch.Response{} | _] = responses}) do
    failed = Enum.filter(responses, &Creatio.Batch.Response.error?/1)

    case failed do
      [] ->
        %{result: :ok, status: :ok, error: nil, error_count: 0}

      [first_failed | _] ->
        %{
          result: :error,
          status: :error,
          error: sanitize_error(Creatio.Batch.Response.to_error(first_failed)),
          error_count: length(failed)
        }
    end
  end

  defp outcome_metadata({:ok, _}), do: %{result: :ok, status: :ok, error: nil}
  defp outcome_metadata({:ok, _, _}), do: %{result: :ok, status: :ok, error: nil}

  defp outcome_metadata({:error, error}),
    do: %{result: :error, status: :error, error: sanitize_error(error)}

  defp outcome_metadata(_), do: %{result: :ok, status: :ok, error: nil}

  defp attach_request_step(
         %Req.Request{request_steps: steps, current_request_steps: current} = req
       ) do
    if Keyword.has_key?(steps, :creatio_telemetry) do
      req
    else
      step = {:creatio_telemetry, &__MODULE__.handle_req_start/1}
      anchor = last_present_step(steps, [:encode_body, :put_base_url])

      updated_steps =
        cond do
          anchor ->
            insert_step_after(steps, anchor, step)

          Keyword.has_key?(steps, :read_only_guard) ->
            insert_step_before(steps, :read_only_guard, step)

          true ->
            [step | steps]
        end

      updated_current =
        cond do
          anchor && anchor in current ->
            insert_name_after(current, anchor, :creatio_telemetry)

          :read_only_guard in current ->
            insert_name_before(current, :read_only_guard, :creatio_telemetry)

          true ->
            [:creatio_telemetry | current]
        end

      %Req.Request{req | request_steps: updated_steps, current_request_steps: updated_current}
    end
  end

  defp last_present_step(steps, candidates) do
    steps
    |> Keyword.keys()
    |> Enum.filter(&(&1 in candidates))
    |> List.last()
  end

  defp insert_step_after([], _anchor, step), do: [step]

  defp insert_step_after([{anchor, _} = head | tail], anchor, step) do
    [head, step | tail]
  end

  defp insert_step_after([head | tail], anchor, step) do
    [head | insert_step_after(tail, anchor, step)]
  end

  defp insert_step_before([], _target, step), do: [step]

  defp insert_step_before([{target, _} = head | tail], target, step) do
    [step, head | tail]
  end

  defp insert_step_before([head | tail], target, step) do
    [head | insert_step_before(tail, target, step)]
  end

  defp insert_name_after([], _anchor, name), do: [name]
  defp insert_name_after([anchor | tail], anchor, name), do: [anchor, name | tail]

  defp insert_name_after([head | tail], anchor, name),
    do: [head | insert_name_after(tail, anchor, name)]

  defp insert_name_before([], _target, name), do: [name]
  defp insert_name_before([target | tail], target, name), do: [name, target | tail]

  defp insert_name_before([head | tail], target, name),
    do: [head | insert_name_before(tail, target, name)]

  defp attach_response_step(%Req.Request{response_steps: steps} = req) do
    if Keyword.has_key?(steps, :creatio_telemetry) do
      req
    else
      Req.Request.prepend_response_steps(req, creatio_telemetry: &__MODULE__.handle_req_stop/1)
    end
  end

  defp attach_error_step(%Req.Request{error_steps: steps} = req) do
    if Keyword.has_key?(steps, :creatio_telemetry) do
      req
    else
      Req.Request.prepend_error_steps(req, creatio_telemetry: &__MODULE__.handle_req_error/1)
    end
  end

  defp build_req_metadata(%Req.Request{} = req) do
    client_meta = Req.Request.get_private(req, :creatio_client_meta, %{})

    base_url =
      case Map.get(client_meta, :base_url) do
        url when is_binary(url) and url != "" -> url
        _ -> resolve_base_url(req)
      end

    auth_mode = Map.get(client_meta, :auth_mode)

    %{
      method: req.method,
      path: extract_path(req.url),
      base_url: base_url,
      auth_mode: auth_mode,
      headers: sanitize_headers(req.headers)
    }
  end

  defp resolve_base_url(%Req.Request{
         options: opts,
         url: %URI{scheme: scheme, host: host, port: port}
       })
       when is_binary(scheme) and is_binary(host) do
    case opts[:base_url] do
      url when is_binary(url) and url != "" -> url
      _ -> format_origin(scheme, host, port)
    end
  end

  defp resolve_base_url(%Req.Request{options: opts}) do
    case opts[:base_url] do
      url when is_binary(url) and url != "" -> url
      _ -> ""
    end
  end

  @doc false
  @spec format_origin(String.t(), String.t(), :inet.port_number() | nil) :: String.t()
  def format_origin("http", host, 80), do: "http://#{host}"
  def format_origin("https", host, 443), do: "https://#{host}"
  def format_origin(scheme, host, nil), do: "#{scheme}://#{host}"
  def format_origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"

  defp extract_path(%URI{path: path}) when is_binary(path) and path != "", do: path
  defp extract_path(%URI{}), do: "/"
end
