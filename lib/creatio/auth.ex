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
  @spec login_forms(Client.t() | Req.Request.t(), String.t(), String.t(), keyword()) ::
          {:ok, Client.t()} | {:error, Error.t()}
  def login_forms(client_or_req, username, password, opts \\ [])

  def login_forms(%Client{} = client, username, password, opts) do
    Telemetry.span(:auth, %{auth_mode: :forms, base_url: client.base_url}, fn ->
      url = Keyword.get(opts, :url, "/ServiceModel/AuthService.svc/Login")
      body = %{"UserName" => username, "UserPassword" => password}

      req =
        client.req
        |> Req.Request.delete_header("authorization")
        |> Req.Request.delete_header("cookie")
        |> Req.Request.delete_header("bpmcsrf")
        |> Req.Request.put_header("content-type", "application/json; charset=utf-8")

      case Req.post(req, url: url, json: body) do
        {:ok, %Req.Response{} = resp} ->
          handle_forms_login_result(resp, client)

        {:error, exception} ->
          Error.wrap_error(exception)
      end
    end)
  end

  def login_forms(%Req.Request{} = req, username, password, opts) do
    client = Client.from_req(req)
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
        bpmcsrf = extract_bpmcsrf(cookies, resp.headers)
        cookie_header = Enum.join(cookies, "; ")

        updated_client = Client.put_forms_auth(client, cookie_header, bpmcsrf)
        {:ok, updated_client}

      code != nil ->
        msg = body["Message"] || body["message"] || "Invalid credentials"

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
  @spec login_oauth(Client.t(), keyword()) ::
          {:ok, Client.t(), map()} | {:error, Error.t()}
  def login_oauth(%Client{} = client, opts \\ []) do
    client_id = Keyword.get(opts, :client_id) || client.client_id
    client_secret = Keyword.get(opts, :client_secret) || client.client_secret

    identity_url =
      (Keyword.get(opts, :identity_service_url) || client.identity_service_url || "")
      |> String.trim_trailing("/")

    token_path =
      Keyword.get(opts, :token_url) || Keyword.get(client.options, :token_url) ||
        "/connect/token"

    full_token_url? = String.starts_with?(token_path, ["http://", "https://"])

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

            extra_req_opts = Keyword.get(opts, :req_options, [])

            token_req =
              client
              |> identity_base_req(:oauth)
              |> Req.merge([url: full_token_url, form: form_data] ++ extra_req_opts)

            case Req.post(token_req) do
              {:ok, %Req.Response{} = raw_resp} ->
                case Util.normalize_json_response(raw_resp) do
                  %{status: 200, body: %{"access_token" => token} = token_body} ->
                    updated_client =
                      %Client{
                        client
                        | client_id: client_id,
                          client_secret: client_secret,
                          identity_service_url:
                            if(identity_url != "",
                              do: identity_url,
                              else: client.identity_service_url
                            )
                      }
                      |> Client.put_bearer_token(token)

                    {:ok, updated_client, token_body}

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
  @spec oauth_health_check(Client.t(), keyword()) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  def oauth_health_check(%Client{} = client, opts \\ []) do
    Telemetry.span(:auth, %{auth_mode: :health_check, base_url: client.base_url}, fn ->
      url = Keyword.get(opts, :url, "/0/api/OAuthHealthCheck")

      case Req.get(client.req, url: url) do
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
    end)
  end

  defp valid_health_response?(%Req.Response{body: %{} = body}) do
    not Map.has_key?(body, "error")
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
  @spec openid_configuration(Client.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def openid_configuration(client_or_url, opts \\ [])

  def openid_configuration(%Client{} = client, opts) do
    Telemetry.span(:auth, %{auth_mode: :openid_configuration, base_url: client.base_url}, fn ->
      base = client.identity_service_url || (client.base_url || "") <> "/identity"

      url =
        Keyword.get(opts, :url) ||
          "#{String.trim_trailing(base, "/")}/.well-known/openid-configuration"

      extra_req_opts = Keyword.get(opts, :req_options, [])

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
        req_opts = Keyword.get(opts, :req_options, [])
        effective_url = resolve_request_url(url, Keyword.get(req_opts, :base_url))

        with :ok <- validate_absolute_url(effective_url, "OpenID configuration") do
          req =
            [url: url]
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
    if String.starts_with?(url, ["http://", "https://"]) do
      url
    else
      "#{String.trim_trailing(base_url, "/")}#{if String.starts_with?(url, "/"), do: url, else: "/#{url}"}"
    end
  end

  defp resolve_request_url(url, _base_url), do: url

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
      %{status: 200, body: %{} = body} -> {:ok, body}
      %Req.Response{} = resp -> {:error, Error.from_response(resp)}
    end
  end

  defp handle_openid_response({:error, exception}), do: Error.wrap_error(exception)

  # Reuses client.req (Finch pool, TLS, retry, :plug) without leaking CRM session headers
  defp identity_base_req(%Client{req: %Req.Request{} = req}, auth_mode) do
    req
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
    parse_set_cookie_raw([raw])
  end

  defp parse_set_cookie_raw(list) when is_list(list) do
    # Deduplicate by cookie name keeping the latest Set-Cookie header value
    # (IIS commonly clears a cookie before setting its new value in the same response).
    {ordered_names, by_name} =
      list
      |> Enum.flat_map(fn item when is_binary(item) ->
        Regex.split(~r/,\s*(?=[A-Za-z0-9_.-]+=)/, item)
      end)
      |> Enum.map(fn cookie_str ->
        cookie_str
        |> String.split(";")
        |> List.first()
        |> String.trim()
      end)
      |> Enum.reject(&(&1 == "" or is_nil(&1)))
      |> Enum.reduce({[], %{}}, fn cookie, {names, acc} ->
        name_key =
          case String.split(cookie, "=", parts: 2) do
            [name, _val] -> String.downcase(String.trim(name))
            [name] -> String.downcase(String.trim(name))
          end

        names = if Map.has_key?(acc, name_key), do: names, else: [name_key | names]
        {names, Map.put(acc, name_key, cookie)}
      end)

    ordered_names
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_name, &1))
  end

  defp extract_bpmcsrf(cookies, headers) when is_list(cookies) do
    from_cookies =
      cookies
      |> Enum.reverse()
      |> Enum.find_value(fn cookie ->
        cookie = String.trim(cookie)

        case Regex.run(~r/^bpmcsrf=(.*)$/i, cookie) do
          [_, val] when val != "" -> safe_uri_decode(val)
          _ -> nil
        end
      end)

    from_cookies || extract_header_val(headers, "bpmcsrf") ||
      extract_header_val(headers, "BPMCSRF")
  end

  defp safe_uri_decode(val) do
    URI.decode(val)
  rescue
    ArgumentError -> val
  end

  defp extract_header_val(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [val | _] when is_binary(val) -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end
end
