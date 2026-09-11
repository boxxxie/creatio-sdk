defmodule Creatio.AuthTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Auth, Client, Error}

  describe "login_forms/4" do
    test "successfully authenticates, sets cookies and decodes BPMCSRF token" do
      plug = fn conn ->
        assert conn.request_path == "/ServiceModel/AuthService.svc/Login"
        assert conn.method == "POST"
        assert get_req_header(conn, "forceusesession") == ["true"]

        {:ok, body, conn} = read_body(conn)
        params = Jason.decode!(body)
        assert params["UserName"] == "AdminUser"
        assert params["UserPassword"] == "SecretPass123"

        cookies = [
          {"set-cookie", ".ASPXAUTH=AuthTokenValue123; path=/; HttpOnly"},
          {"set-cookie", "BPMLOADER=BpmLoaderVal; path=/"},
          {"set-cookie", "BPMCSRF=csrf%2Btoken%3Dval; path=/"}
        ]

        %{conn | resp_headers: cookies ++ conn.resp_headers}
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"Code" => 0, "Message" => ""}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, %Client{} = authed} = Auth.login_forms(client, "AdminUser", "SecretPass123")
      assert authed.auth_mode == :forms
      assert authed.bpmcsrf == "csrf+token=val"
      assert String.contains?(authed.cookie, ".ASPXAUTH=AuthTokenValue123")
      assert String.contains?(authed.cookie, "BPMLOADER=BpmLoaderVal")
      assert String.contains?(authed.cookie, "BPMCSRF=csrf%2Btoken%3Dval")

      # Headers are set on req
      assert authed.req.headers["bpmcsrf"] == ["csrf+token=val"]
      assert authed.req.headers["cookie"] == [authed.cookie]
    end

    test "handles comma-separated multi-cookie header with expires date comma" do
      plug = fn conn ->
        multi_cookie =
          ".ASPXAUTH=ProxyToken; path=/; expires=Sun, 06 Nov 1994 08:49:37 GMT; HttpOnly, BPMLOADER=ProxyLoader; path=/, BPMCSRF=proxy_csrf; path=/"

        conn
        |> put_resp_header("set-cookie", multi_cookie)
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"Code" => 0, "Message" => ""}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, %Client{} = authed} = Auth.login_forms(client, "AdminUser", "Pass")
      assert authed.bpmcsrf == "proxy_csrf"
      assert String.contains?(authed.cookie, ".ASPXAUTH=ProxyToken")
      assert String.contains?(authed.cookie, "BPMLOADER=ProxyLoader")
      assert String.contains?(authed.cookie, "BPMCSRF=proxy_csrf")
    end

    test "extracts BPMCSRF token from response header if not in cookies" do
      plug = fn conn ->
        conn
        |> put_resp_header("set-cookie", ".ASPXAUTH=TokenOnly; path=/")
        |> put_resp_header("bpmcsrf", "header_token_123")
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"Code" => 0, "Message" => ""}))
      end

      req = Req.new(base_url: "https://mycreatio.com", plug: plug)
      assert {:ok, %Client{} = authed} = Auth.login_forms(req, "User", "Pass")
      assert authed.bpmcsrf == "header_token_123"
      assert authed.cookie == ".ASPXAUTH=TokenOnly"
    end

    test "returns error when credentials are invalid (Code != 0)" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"Code" => -1, "Message" => "Invalid username or password"})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:error, %Error{status: 200, code: -1, message: msg}} =
               Auth.login_forms(client, "wrong", "wrong")

      assert String.contains?(msg, "Invalid username or password")
    end

    test "returns error when server responds with 500 error" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          500,
          Jason.encode!(%{"error" => %{"message" => "Internal server error"}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:error, %Error{status: 500, message: "Internal server error"}} =
               Auth.login_forms(client, "user", "pass")
    end
  end

  describe "login_oauth/2" do
    test "validates required parameters" do
      client = Client.new(base_url: "https://mycreatio.com")

      assert {:error, %Error{message: msg1}} = Auth.login_oauth(client)
      assert String.contains?(msg1, "Missing :client_id")

      assert {:error, %Error{message: msg2}} =
               Auth.login_oauth(client, client_id: "id")

      assert String.contains?(msg2, "Missing :client_secret")

      assert {:error, %Error{message: msg3}} =
               Auth.login_oauth(client, client_id: "id", client_secret: "secret")

      assert String.contains?(msg3, "Missing :identity_service_url")
    end

    test "successfully fetches OAuth 2.0 access token and sets Bearer authorization" do
      plug = fn conn ->
        assert conn.request_path == "/connect/token"
        assert conn.method == "POST"

        {:ok, body, conn} = read_body(conn)
        params = URI.decode_query(body)
        assert params["grant_type"] == "client_credentials"
        assert params["client_id"] == "test_client_id"
        assert params["client_secret"] == "test_client_secret"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "oauth_access_token_12345",
            "expires_in" => 3600,
            "token_type" => "Bearer",
            "scope" => "ApplicationAccess_xyz"
          })
        )
      end

      client =
        Client.new(
          base_url: "https://mycreatio.com",
          identity_service_url: "https://identity.creatio.com",
          client_id: "test_client_id",
          client_secret: "test_client_secret",
          req_options: [plug: plug]
        )

      assert {:ok, %Client{} = authed, token_data} = Auth.login_oauth(client)
      assert token_data["access_token"] == "oauth_access_token_12345"
      assert token_data["expires_in"] == 3600
      assert authed.auth_mode == :bearer
      assert authed.auth_token == "oauth_access_token_12345"
      assert authed.req.headers["authorization"] == ["Bearer oauth_access_token_12345"]
    end

    test "handles OAuth server error response" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_client",
            "error_description" => "Client authentication failed"
          })
        )
      end

      client =
        Client.new(
          base_url: "https://mycreatio.com",
          identity_service_url: "https://identity.creatio.com",
          client_id: "invalid_id",
          client_secret: "bad_secret",
          req_options: [plug: plug]
        )

      assert {:error, %Error{status: 400, code: "invalid_client", message: msg}} =
               Auth.login_oauth(client)

      assert String.contains?(msg, "Client authentication failed")
    end
  end

  describe "oauth_health_check/2" do
    test "checks OAuth health endpoint" do
      plug = fn conn ->
        assert conn.request_path == "/0/api/OAuthHealthCheck"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "Healthy"}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, %{"status" => "Healthy"}} = Auth.oauth_health_check(client)
    end
  end

  describe "openid_configuration/2" do
    test "fetches openid configuration" do
      plug = fn conn ->
        assert conn.request_path == "/.well-known/openid-configuration"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"token_endpoint" => "https://identity/connect/token"}))
      end

      client =
        Client.new(
          base_url: "https://mycreatio.com",
          identity_service_url: "https://identity.creatio.com",
          req_options: [plug: plug]
        )

      assert {:ok, %{"token_endpoint" => "https://identity/connect/token"}} =
               Auth.openid_configuration(client, req_options: [plug: plug])
    end
  end
end
