defmodule Creatio.Auth do
  @moduledoc """
  Authentication services for Creatio CRM.

  Supports both Forms Authentication (AuthService.svc with BPMCSRF and cookies)
  and OAuth 2.0 (Identity Service client credentials grant).
  """

  alias Creatio.{Client, Error, Telemetry, Util}

  @doc """
  Logs into Creatio using Forms authentication (Username & Password).

  Sends a request to `/ServiceModel/AuthService.svc/Login`, captures the `.ASPXAUTH`,
  `BPMLOADER`, and `BPMCSRF` cookies, and configures the client with the required
  `cookie` and `bpmcsrf` headers for subsequent requests.

  ## Examples

      client = Creatio.new(base_url: "https://mycreatio.com")
      {:ok, client} = Creatio.Auth.login_forms(client, "User01", "SecretPass")
  """
  @spec login_forms(Client.t() | Req.Request.t(), String.t(), String.t(), Creatio.opts()) ::
          {:ok, Client.t()} | {:error, Error.t()}
  def login_forms(client_or_req, username, password, opts \\ [])

  def login_forms(%Client{} = client, username, password, opts) do
    Telemetry.span(:auth, %{auth_mode: :forms, base_url: client.base_url}, fn ->
      raw_url = Util.get_opt(opts, :url, "/ServiceModel/AuthService.svc/Login")

      with {:ok, url} <- Util.validate_crm_url(raw_url, client.base_url, "Forms login URL") do
        body = %{"UserName" => username, "UserPassword" => password}

        base_req =
          client.req
          |> Client.detach_read_only_guard()
          |> Req.Request.delete_header("authorization")
          |> Req.Request.delete_header("cookie")
          |> Req.Request.delete_header("bpmcsrf")
          |> Req.Request.put_header("accept", "application/json")
          |> Req.Request.put_header("content-type", "application/json; charset=utf-8")

        {req, req_opts} =
          Util.prepare_req_call(
            base_req,
            opts,
            [url: url, json: body],
            %{},
            [:url, :json, :method]
          )

        case Req.post(req, req_opts) do
          {:ok, %Req.Response{} = resp} ->
            handle_forms_login_result(resp, client)

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    end)
  end

  def login_forms(%Req.Request{} = req, username, password, opts) do
    client_opts = opts |> Util.drop_opt(:url) |> Util.drop_opt(:req_options)
    client = Client.from_req(req, client_opts)
    login_forms(client, username, password, opts)
  end

  defp handle_forms_login_result(%Req.Response{status: 200, body: body_str} = resp, client)
       when is_binary(body_str) do
    case Util.normalize_json_response(resp) do
      %Req.Response{body: %{}} = normalized ->
        handle_forms_login_result(normalized, client)

      _ ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_forms_login_result(%Req.Response{status: 200, body: %{} = body} = resp, client) do
    code = body["Code"] || body["code"]

    cond do
      code in [0, "0"] ->
        cookies = extract_cookies(resp.headers)

        if cookies == [] do
          {:error,
           Error.new(
             status: 200,
             code: "FormsMissingCookies",
             message:
               "Forms login succeeded (Code: 0) but response contained no Set-Cookie headers.",
             response: resp
           )}
        else
          bpmcsrf = extract_bpmcsrf(cookies, resp.headers)
          cookie_header = Enum.join(cookies, "; ")

          updated_client = Client.put_forms_auth(client, cookie_header, bpmcsrf)
          {:ok, updated_client}
        end

      code != nil ->
        msg =
          Enum.find([body["Message"], body["message"], body["ExceptionMessage"]], fn
            val when is_binary(val) -> String.trim(val) != ""
            _ -> false
          end) || "Invalid credentials"

        {:error,
         Error.new(
           status: 200,
           code: code,
           message: msg,
           response: resp
         )}

      true ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_forms_login_result(%Req.Response{} = resp, _client) do
    {:error, Error.from_response(resp)}
  end

  @doc """
  Authenticates via OAuth 2.0 Client Credentials against the Creatio Identity Service.

  Sends a request to `{identity_service_url}/connect/token` with `grant_type=client_credentials`.
  On success, configures the client with the Bearer access token.

  ## Options

    * `:client_id` - The OAuth client ID (defaults to `client.client_id`).
    * `:client_secret` - The OAuth client secret (defaults to `client.client_secret`).
    * `:identity_service_url` - The base URL of the Identity Service (defaults to `client.identity_service_url`).
    * `:token_url` - Overrides the token endpoint path or full URL (defaults to `"/connect/token"`).
    * `:req_options` - Additional options merged into the request.
  """
  @spec login_oauth(Client.t() | Req.Request.t(), Creatio.opts()) ::
          {:ok, Client.t(), map()} | {:error, Error.t()}
  def login_oauth(client_or_req, opts \\ [])

  def login_oauth(%Req.Request{} = req, opts) do
    client_opts = opts |> Util.drop_opt(:url) |> Util.drop_opt(:req_options)
    client = Client.from_req(req, client_opts)
    login_oauth(client, opts)
  end

  def login_oauth(%Client{} = client, opts) do
    client_id = normalize_non_empty(Util.get_opt(opts, :client_id)) || client.client_id

    client_secret =
      normalize_non_empty(Util.get_opt(opts, :client_secret)) || client.client_secret

    identity_url =
      case Util.get_opt(opts, :identity_service_url) || client.identity_service_url do
        url when is_binary(url) -> url |> String.trim() |> String.trim_trailing("/")
        _ -> ""
      end

    token_path =
      (Util.get_opt(opts, :token_url) || Keyword.get(client.options, :token_url) ||
         "/connect/token")
      |> to_string()
      |> String.trim()

    full_token_url? = absolute_http_url?(token_path)

    span_meta = %{
      auth_mode: :oauth,
      base_url: client.base_url,
      identity_service_url: if(identity_url != "", do: identity_url, else: nil)
    }

    Telemetry.span(:auth, span_meta, fn ->
      cond do
        is_nil(client_id) or client_id == "" ->
          {:error, Error.new(message: "Missing :client_id for OAuth 2.0 authentication")}

        is_nil(client_secret) or client_secret == "" ->
          {:error, Error.new(message: "Missing :client_secret for OAuth 2.0 authentication")}

        not full_token_url? and identity_url == "" ->
          {:error,
           Error.new(message: "Missing :identity_service_url for OAuth 2.0 authentication")}

        true ->
          full_token_url =
            if full_token_url? do
              token_path
            else
              normalized_path =
                if String.starts_with?(token_path, "/"), do: token_path, else: "/#{token_path}"

              "#{identity_url}#{normalized_path}"
            end

          with :ok <- validate_absolute_url(full_token_url, "OAuth 2.0 token endpoint") do
            form_data = [
              grant_type: "client_credentials",
              client_id: client_id,
              client_secret: client_secret
            ]

            extra_req_opts = Util.extract_req_options(opts, [:url, :form, :method])

            token_req =
              client
              |> identity_base_req(:oauth)
              |> Req.merge([url: full_token_url, form: form_data] ++ extra_req_opts)

            case Req.post(token_req) do
              {:ok, %Req.Response{} = raw_resp} ->
                case Util.normalize_json_response(raw_resp) do
                  %{status: 200, body: %{"access_token" => token} = token_body} = resp ->
                    trimmed_token = if is_binary(token), do: String.trim(token), else: ""

                    if trimmed_token == "" do
                      {:error,
                       Error.new(
                         status: 200,
                         code: "OAuthMissingToken",
                         message: "OAuth token response contained an empty or null access_token.",
                         response: resp
                       )}
                    else
                      updated_client =
                        %Client{
                          client
                          | client_id: client_id,
                            identity_service_url:
                              if(identity_url != "",
                                do: identity_url,
                                else: client.identity_service_url
                              )
                        }
                        |> Client.put_bearer_token(trimmed_token)

                      {:ok, updated_client, token_body}
                    end

                  %Req.Response{} = resp ->
                    {:error, Error.from_response(resp)}
                end

              {:error, exception} ->
                Error.wrap_error(exception)
            end
          end
      end
    end)
  end

  @doc """
  Checks the health of the OAuth functionality on the Creatio instance.

  Sends a `GET` request to `/0/api/OAuthHealthCheck`.
  """
  @spec oauth_health_check(Client.t() | Req.Request.t(), Creatio.opts()) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  def oauth_health_check(client_or_req, opts \\ [])

  def oauth_health_check(%Req.Request{} = req, opts) do
    client_opts = opts |> Util.drop_opt(:url) |> Util.drop_opt(:req_options)
    client = Client.from_req(req, client_opts)
    oauth_health_check(client, opts)
  end

  def oauth_health_check(%Client{} = client, opts) do
    Telemetry.span(:auth, %{auth_mode: :health_check, base_url: client.base_url}, fn ->
      raw_url = Util.get_opt(opts, :url, "/0/api/OAuthHealthCheck")

      with {:ok, url} <- Util.validate_crm_url(raw_url, client.base_url, "OAuth health check URL") do
        {req, req_opts} =
          Util.prepare_req_call(client.req, opts, [url: url], %{}, [:url, :method])

        case Req.get(req, req_opts) do
          {:ok, %Req.Response{} = raw_resp} ->
            resp = Util.normalize_json_response(raw_resp)

            if resp.status == 200 and valid_health_response?(resp) do
              {:ok, resp.body}
            else
              {:error, Error.from_response(resp)}
            end

          {:error, exception} ->
            Error.wrap_error(exception)
        end
      end
    end)
  end

  defp valid_health_response?(%Req.Response{body: %{} = body}) do
    not Util.error_payload?(body)
  end

  defp valid_health_response?(%Req.Response{body: body} = resp) when is_binary(body) do
    trimmed = body |> String.trim_leading("\uFEFF") |> String.trim()

    trimmed != "" and
      not String.starts_with?(trimmed, ["{", "["]) and
      not Util.html_or_xml_markup?(resp)
  end

  defp valid_health_response?(_), do: false

  @doc """
  Retrieves the OpenID configuration from the Identity Service (`/.well-known/openid-configuration`).
  """
  @spec openid_configuration(Client.t() | String.t(), Creatio.opts()) ::
          {:ok, map()} | {:error, Error.t()}
  def openid_configuration(client_or_url, opts \\ [])

  def openid_configuration(%Client{} = client, opts) do
    Telemetry.span(:auth, %{auth_mode: :openid_configuration, base_url: client.base_url}, fn ->
      base = client.identity_service_url || (client.base_url || "") <> "/identity"

      url =
        Util.get_opt(opts, :url) ||
          "#{String.trim_trailing(base, "/")}/.well-known/openid-configuration"

      extra_req_opts = Util.extract_req_options(opts, [:url, :method])

      effective_url =
        resolve_request_url(url, Keyword.get(extra_req_opts, :base_url))

      with :ok <- validate_absolute_url(effective_url, "OpenID configuration") do
        req =
          client
          |> identity_base_req(:openid_configuration)
          |> Req.merge([url: url] ++ extra_req_opts)

        handle_openid_response(Req.get(req))
      end
    end)
  end

  def openid_configuration(url, opts) when is_binary(url) do
    Telemetry.span(
      :auth,
      %{auth_mode: :openid_configuration, base_url: origin_from_url(url)},
      fn ->
        req_opts = Util.extract_req_options(opts, [:url, :method])
        effective_url = resolve_request_url(url, Keyword.get(req_opts, :base_url))

        with :ok <- validate_absolute_url(effective_url, "OpenID configuration") do
          req =
            [url: url, decode_body: false]
            |> Keyword.merge(req_opts)
            |> Req.new()
            |> Telemetry.attach_req_steps()

          handle_openid_response(Req.get(req))
        end
      end
    )
  end

  defp resolve_request_url(url, base_url)
       when is_binary(base_url) and base_url != "" and is_binary(url) do
    if absolute_http_url?(url) do
      url
    else
      "#{String.trim_trailing(base_url, "/")}#{if String.starts_with?(url, "/"), do: url, else: "/#{url}"}"
    end
  end

  defp resolve_request_url(url, _base_url), do: url

  defp absolute_http_url?(url) when is_binary(url) do
    case String.downcase(url) do
      "http://" <> _ -> true
      "https://" <> _ -> true
      _ -> false
    end
  end

  defp normalize_non_empty(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_non_empty(_), do: nil

  defp validate_absolute_url(url, label) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, Error.new(message: "Invalid or missing URL for #{label}: #{inspect(url)}")}
    end
  end

  defp validate_absolute_url(other, label) do
    {:error, Error.new(message: "Invalid or missing URL for #{label}: #{inspect(other)}")}
  end

  defp origin_from_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        Telemetry.format_origin(scheme, host, port)

      _ ->
        ""
    end
  end

  defp handle_openid_response({:ok, %Req.Response{} = raw_resp}) do
    case Util.normalize_json_response(raw_resp) do
      %{status: 200, body: %{} = body} = resp ->
        if Util.error_payload?(body) do
          {:error, Error.from_response(resp)}
        else
          {:ok, body}
        end

      %Req.Response{} = resp ->
        {:error, Error.from_response(resp)}
    end
  end

  defp handle_openid_response({:error, exception}), do: Error.wrap_error(exception)

  # Reuses client.req (Finch pool, TLS, retry, :plug) without leaking CRM session headers or CRM read_only_guard
  defp identity_base_req(%Client{req: %Req.Request{} = req}, auth_mode) do
    req
    |> Client.detach_read_only_guard()
    |> Req.Request.put_option(:base_url, nil)
    |> Req.Request.put_private(:creatio_client_meta, %{base_url: nil, auth_mode: auth_mode})
    |> Req.Request.delete_header("authorization")
    |> Req.Request.delete_header("cookie")
    |> Req.Request.delete_header("bpmcsrf")
    |> Req.Request.delete_header("forceusesession")
    |> Req.Request.put_header("accept", "application/json")
  end

  defp extract_cookies(headers) when is_map(headers) do
    set_cookie =
      Map.get(headers, "set-cookie") ||
        Map.get(headers, "Set-Cookie") ||
        []

    parse_set_cookie_raw(set_cookie)
  end

  defp parse_set_cookie_raw(raw) when is_binary(raw) do
    ~r/,\s*(?=[A-Za-z0-9_.-]+=)/
    |> Regex.split(raw)
    |> parse_set_cookie_raw()
  end

  defp parse_set_cookie_raw(list) when is_list(list) do
    # Deduplicate by cookie name keeping the latest Set-Cookie header value
    # (IIS commonly clears a cookie before setting its new value in the same response),
    # and drop cookies cleared with an empty value only when targeting the same Path.
    {ordered_names, by_name} =
      list
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&split_folded_set_cookie/1)
      |> Enum.reduce({[], %{}}, fn cookie_str, {names, acc} ->
        case parse_set_cookie_entry(cookie_str) do
          {:ok, name_key, cookie_kv, path, cleared?} ->
            if cleared? do
              case Map.get(acc, name_key) do
                {_existing_kv, existing_path} when existing_path == path ->
                  {List.delete(names, name_key), Map.delete(acc, name_key)}

                _ ->
                  {names, acc}
              end
            else
              names = if Map.has_key?(acc, name_key), do: names, else: [name_key | names]
              {names, Map.put(acc, name_key, {cookie_kv, path})}
            end

          :ignore ->
            {names, acc}
        end
      end)

    ordered_names
    |> Enum.reverse()
    |> Enum.map(fn name_key ->
      {cookie_kv, _path} = Map.fetch!(by_name, name_key)
      cookie_kv
    end)
  end

  defp split_folded_set_cookie(cookie_str) when is_binary(cookie_str) do
    case String.split(cookie_str, ";", parts: 2) do
      [kv_part, attrs_tail] ->
        case Regex.split(~r/,\s*(?=[A-Za-z0-9_.-]+=)/, attrs_tail, parts: 2) do
          [first_attrs, next_cookie] ->
            ["#{kv_part};#{first_attrs}" | split_folded_set_cookie(next_cookie)]

          [only_attrs] ->
            ["#{kv_part};#{only_attrs}"]
        end

      [kv_only] ->
        [kv_only]
    end
  end

  defp parse_set_cookie_entry(cookie_str) do
    [kv_part | attr_parts] = String.split(cookie_str, ";")
    trimmed_kv = String.trim(kv_part)

    case String.split(trimmed_kv, "=", parts: 2) do
      [name, val] ->
        trimmed_name = String.trim(name)
        trimmed_val = String.trim(val)

        if trimmed_name == "" do
          :ignore
        else
          name_key = String.downcase(trimmed_name)
          attrs = parse_cookie_attrs(attr_parts)
          path = Map.get(attrs, "path")
          cleared? = trimmed_val == "" or max_age_expired?(attrs)
          {:ok, name_key, "#{trimmed_name}=#{trimmed_val}", path, cleared?}
        end

      _ ->
        :ignore
    end
  end

  defp parse_cookie_attrs(attr_parts) do
    Enum.reduce(attr_parts, %{}, fn part, acc ->
      case String.split(part, "=", parts: 2) do
        [k, v] ->
          Map.put(acc, k |> String.trim() |> String.downcase(), String.trim(v))

        _ ->
          acc
      end
    end)
  end

  defp max_age_expired?(%{"max-age" => raw_age}) do
    case Integer.parse(raw_age) do
      {age, ""} -> age <= 0
      _ -> false
    end
  end

  defp max_age_expired?(_), do: false

  defp extract_bpmcsrf(cookies, headers) when is_list(cookies) do
    from_cookies =
      cookies
      |> Enum.reverse()
      |> Enum.find_value(fn cookie ->
        cookie = String.trim(cookie)

        case Regex.run(~r/\Abpmcsrf=(.+)\z/i, cookie) do
          [_, val] -> val
          _ -> nil
        end
      end)

    from_cookies || extract_header_val(headers, "bpmcsrf") ||
      extract_header_val(headers, "BPMCSRF")
  end

  defp extract_header_val(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [val | _] when is_binary(val) -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end
end
