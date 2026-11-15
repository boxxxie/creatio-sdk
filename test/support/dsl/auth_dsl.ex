defmodule Creatio.TestDSL.AuthDSL do
  @moduledoc """
  Layer 2 DSL for Creatio Forms Authentication, OAuth 2.0, and OpenID discovery scenarios.
  """

  alias Creatio.Client
  alias Creatio.Error
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

  # ---------------------------------------------------------------------------
  # @given steps
  # ---------------------------------------------------------------------------

  def creatio_forms_auth_accepting(ctx, opts \\ []) do
    cookies = build_cookie_headers(opts)

    stub_opts =
      [
        cookies: cookies,
        bpmcsrf_header: Keyword.get(opts, :csrf_header),
        content_type:
          if(Keyword.get(opts, :plain_text, false), do: "text/plain", else: "application/json")
      ]
      |> maybe_put_opt(:raw_body, Keyword.get(opts, :raw_body))

    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_forms_login(stub_opts)
  end

  def creatio_forms_auth_rejecting_credentials(ctx, opts) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_forms_login(
      status: 200,
      code: Keyword.fetch!(opts, :code),
      message: Keyword.fetch!(opts, :message)
    )
  end

  def creatio_auth_service_unavailable(ctx, opts) do
    status = Keyword.fetch!(opts, :status)
    message = Keyword.fetch!(opts, :message)

    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_forms_login(
      status: status,
      error_body: %{"error" => %{"message" => message}}
    )
  end

  def unconfigured_http_client(ctx) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> then(fn c -> Map.put(c, :raw_req, CreatioServerDriver.req(c)) end)
  end

  def creatio_client_with_oauth_config(ctx, opts) do
    ctx = CreatioServerDriver.ensure_server(ctx)
    client = CreatioServerDriver.client(ctx, opts)
    Map.put(ctx, :client, client)
  end

  def identity_service_issuing_token(ctx, opts) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_oauth_token(opts)
  end

  def identity_service_rejecting_client(ctx, opts) do
    status = Keyword.fetch!(opts, :status)
    error = Keyword.fetch!(opts, :error)
    description = Keyword.fetch!(opts, :error_description)

    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_oauth_token(
      status: status,
      body: %{"error" => error, "error_description" => description}
    )
  end

  def creatio_oauth_health_status(ctx, body) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_oauth_health(body: body)
  end

  def identity_openid_discovery(ctx, body) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_openid_configuration(body: body)
  end

  def identity_openid_discovery_unavailable(ctx, status) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_openid_configuration(status: status, body: %{})
  end

  # ---------------------------------------------------------------------------
  # @upon steps
  # ---------------------------------------------------------------------------

  def logging_in_with_forms(ctx, username, password) do
    CRMClientDriver.login_forms(ctx, username, password)
  end

  def logging_in_with_oauth(ctx, opts \\ []) do
    CRMClientDriver.login_oauth(ctx, opts)
  end

  def checking_oauth_health(ctx) do
    CRMClientDriver.oauth_health_check(ctx)
  end

  def fetching_openid_configuration(ctx, opts \\ []) do
    CRMClientDriver.openid_configuration(ctx, opts)
  end

  # ---------------------------------------------------------------------------
  # @then assertions (caller-line attributed)
  # ---------------------------------------------------------------------------

  defmacro client_is_authenticated_via_forms(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:ok, %Client{} = authed} = Map.fetch!(ctx, :result)
      assert authed.auth_mode == :forms
      assert authed.bpmcsrf == Keyword.fetch!(expected, :csrf_token)

      Enum.each(Keyword.get(expected, :cookies_include, []), fn snippet ->
        assert String.contains?(authed.cookie, snippet)
      end)

      if Keyword.has_key?(expected, :exact_cookie) do
        assert authed.cookie == Keyword.fetch!(expected, :exact_cookie)
      end

      assert authed.req.headers["bpmcsrf"] == [authed.bpmcsrf]
      assert authed.req.headers["cookie"] == [authed.cookie]

      if Keyword.has_key?(expected, :submitted_username) do
        last_req = CreatioServerDriver.last_request(ctx)
        assert last_req.method == "POST"
        assert last_req.request_path == "/ServiceModel/AuthService.svc/Login"
        assert last_req.headers["forceusesession"] == ["true"]
        assert last_req.decoded_body["UserName"] == Keyword.fetch!(expected, :submitted_username)

        assert last_req.decoded_body["UserPassword"] ==
                 Keyword.fetch!(expected, :submitted_password)
      end

      ctx
    end
  end

  defmacro client_is_authenticated_via_oauth(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:ok, %Client{} = authed, token_data} = Map.fetch!(ctx, :result)
      expected_token = Keyword.fetch!(expected, :access_token)

      assert token_data["access_token"] == expected_token
      assert token_data["expires_in"] == Keyword.fetch!(expected, :expires_in)
      assert authed.auth_mode == :bearer
      assert authed.auth_token == expected_token
      assert authed.req.headers["authorization"] == ["Bearer #{expected_token}"]

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "POST"
      assert last_req.request_path == "/connect/token"
      assert last_req.decoded_body["grant_type"] == "client_credentials"
      assert last_req.decoded_body["client_id"] == Keyword.fetch!(expected, :client_id)
      assert last_req.decoded_body["client_secret"] == Keyword.fetch!(expected, :client_secret)

      ctx
    end
  end

  defmacro authentication_fails_with(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:error, %Error{} = err} = Map.fetch!(ctx, :result)

      if Keyword.has_key?(expected, :status) do
        assert err.status == Keyword.fetch!(expected, :status)
      end

      if Keyword.has_key?(expected, :code) do
        assert err.code == Keyword.fetch!(expected, :code)
      end

      if Keyword.has_key?(expected, :message) do
        assert err.message == Keyword.fetch!(expected, :message)
      end

      if Keyword.has_key?(expected, :message_contains) do
        assert String.contains?(err.message, Keyword.fetch!(expected, :message_contains))
      end

      ctx
    end
  end

  defmacro oauth_health_is(ctx, expected_body) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_body)} == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "GET"
      assert last_req.request_path == "/0/api/OAuthHealthCheck"

      ctx
    end
  end

  defmacro openid_configuration_has(ctx, expected_body) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_body)} == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "GET"

      assert last_req.request_path in [
               "/.well-known/openid-configuration",
               "/identity/.well-known/openid-configuration"
             ]

      ctx
    end
  end

  defmacro openid_discovery_fails_with_status(ctx, expected_status) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:error, %Error{status: unquote(expected_status)}} = Map.fetch!(ctx, :result)
      ctx
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp build_cookie_headers(opts) do
    cond do
      Keyword.has_key?(opts, :combined_cookie_header) ->
        [Keyword.fetch!(opts, :combined_cookie_header)]

      Keyword.has_key?(opts, :cookies) ->
        Keyword.fetch!(opts, :cookies)

      true ->
        []
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)
end
