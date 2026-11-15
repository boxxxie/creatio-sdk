defmodule Creatio.Auth do
  @moduledoc """
  Authentication services for Creatio CRM.

  Supports both Forms Authentication (AuthService.svc with BPMCSRF and cookies)
  and OAuth 2.0 (Identity Service client credentials grant).
  """

  alias Creatio.{Client, Error}

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
    url = Keyword.get(opts, :url, "/ServiceModel/AuthService.svc/Login")
    body = %{"UserName" => username, "UserPassword" => password}

    req =
      client.req
      |> Req.Request.put_header("forceusesession", "true")
      |> Req.Request.put_header("content-type", "application/json; charset=utf-8")

    case Req.post(req, url: url, json: body) do
      {:ok, %Req.Response{} = resp} ->
        handle_forms_login_result(resp, client)

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  def login_forms(%Req.Request{} = req, username, password, opts) do
    client = Client.from_req(req)
    login_forms(client, username, password, opts)
  end

  defp handle_forms_login_result(%Req.Response{status: 200, body: body_str} = resp, client)
       when is_binary(body_str) do
    case Jason.decode(body_str) do
      {:ok, %{} = decoded} ->
        handle_forms_login_result(%Req.Response{resp | body: decoded}, client)

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

    cond do
      is_nil(client_id) or client_id == "" ->
        {:error, Error.new(message: "Missing :client_id for OAuth 2.0 authentication")}

      is_nil(client_secret) or client_secret == "" ->
        {:error, Error.new(message: "Missing :client_secret for OAuth 2.0 authentication")}

      not full_token_url? and identity_url == "" ->
        {:error, Error.new(message: "Missing :identity_service_url for OAuth 2.0 authentication")}

      true ->
        full_token_url =
          if full_token_url? do
            token_path
          else
            normalized_path =
              if String.starts_with?(token_path, "/"), do: token_path, else: "/#{token_path}"

            "#{identity_url}#{normalized_path}"
          end

        form_data = [
          grant_type: "client_credentials",
          client_id: client_id,
          client_secret: client_secret
        ]

        extra_req_opts = Keyword.get(opts, :req_options, [])

        token_req =
          client.req
          |> strip_auth_headers()
          |> Req.merge([base_url: nil, url: full_token_url, form: form_data] ++ extra_req_opts)

        case Req.post(token_req) do
          {:ok, %{status: 200, body: %{"access_token" => token} = token_body}} ->
            updated_client =
              client
              |> Client.put_bearer_token(token)
              |> Map.put(:client_id, client_id)
              |> Map.put(:client_secret, client_secret)
              |> Map.put(
                :identity_service_url,
                if(identity_url != "", do: identity_url, else: client.identity_service_url)
              )

            {:ok, updated_client, token_body}

          {:ok, %Req.Response{} = resp} ->
            {:error, Error.from_response(resp)}

          {:error, exception} ->
            Error.wrap_error(exception)
        end
    end
  end

  @doc """
  Checks the health of the OAuth functionality on the Creatio instance.

  Sends a `GET` request to `/0/api/OAuthHealthCheck`.
  """
  @spec oauth_health_check(Client.t(), keyword()) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  def oauth_health_check(%Client{} = client, opts \\ []) do
    url = Keyword.get(opts, :url, "/0/api/OAuthHealthCheck")

    case Req.get(client.req, url: url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  @doc """
  Retrieves the OpenID configuration from the Identity Service (`/.well-known/openid-configuration`).
  """
  @spec openid_configuration(Client.t() | String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def openid_configuration(client_or_url, opts \\ [])

  def openid_configuration(%Client{} = client, opts) do
    base = client.identity_service_url || (client.base_url || "") <> "/identity"

    url =
      Keyword.get(opts, :url) ||
        "#{String.trim_trailing(base, "/")}/.well-known/openid-configuration"

    extra_req_opts = Keyword.get(opts, :req_options, [])

    req =
      client.req
      |> strip_auth_headers()
      |> Req.merge([base_url: nil, url: url] ++ extra_req_opts)

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  def openid_configuration(url, opts) when is_binary(url) do
    req_opts = Keyword.get(opts, :req_options, [])

    case Req.get(url, req_opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{} = resp} ->
        {:error, Error.from_response(resp)}

      {:error, exception} ->
        Error.wrap_error(exception)
    end
  end

  defp strip_auth_headers(req) do
    req
    |> Req.Request.delete_header("authorization")
    |> Req.Request.delete_header("cookie")
    |> Req.Request.delete_header("bpmcsrf")
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
      Enum.find_value(cookies, fn cookie ->
        cookie = String.trim(cookie)

        case Regex.run(~r/^bpmcsrf=(.*)$/i, cookie) do
          [_, val] -> safe_uri_decode(val)
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
