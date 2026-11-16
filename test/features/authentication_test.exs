defmodule Creatio.Features.AuthenticationTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.AuthDSL

  @waf_html "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"

  describe "Forms Authentication (AuthService)" do
    scenario "authenticates with forms credentials and stores session cookies and CSRF token" do
      @given creatio_forms_auth_accepting(
               cookies: [
                 ".ASPXAUTH=auth_cookie_123; path=/; HttpOnly",
                 "BPMCSRF=csrf_token_456; path=/",
                 "BPMLOADER=loader_789; path=/"
               ]
             )
      @upon logging_in_with_forms("Supervisor", "Supervisor")
      @then client_is_authenticated_via_forms(
              csrf_token: "csrf_token_456",
              cookies_include: [".ASPXAUTH=auth_cookie_123", "BPMCSRF=csrf_token_456"],
              submitted_username: "Supervisor",
              submitted_password: "Supervisor"
            )
    end

    scenario "extracts BPMCSRF token from response header when Set-Cookie omits it" do
      @given creatio_forms_auth_accepting(
               combined_cookie_header: ".ASPXAUTH=combined_auth; path=/; HttpOnly",
               csrf_header: "header_csrf_999"
             )
      @upon logging_in_with_forms("Analyst", "Secret123")
      @then client_is_authenticated_via_forms(
              csrf_token: "header_csrf_999",
              exact_cookie: ".ASPXAUTH=combined_auth"
            )
    end

    scenario "parses JSON login confirmation even when served as plain text" do
      @given creatio_forms_auth_accepting(
               cookies: [".ASPXAUTH=plain_auth; path=/", "BPMCSRF=plain_csrf; path=/"],
               plain_text: true
             )
      @upon logging_in_with_forms("Supervisor", "Supervisor")
      @then client_is_authenticated_via_forms(
              csrf_token: "plain_csrf",
              cookies_include: [".ASPXAUTH=plain_auth", "BPMCSRF=plain_csrf"]
            )
    end

    scenario "upgrades an unconfigured HTTP client into an authenticated Creatio client" do
      @given creatio_forms_auth_accepting(
               cookies: [".ASPXAUTH=req_auth; path=/", "BPMCSRF=req_csrf; path=/"]
             )
      @given unconfigured_http_client()
      @upon logging_in_with_forms("IntegrationUser", "Pass123!")
      @then client_is_authenticated_via_forms(
              csrf_token: "req_csrf",
              cookies_include: [".ASPXAUTH=req_auth"]
            )
    end

    scenario "returns an error when Creatio rejects credentials at application level" do
      @given creatio_forms_auth_rejecting_credentials(
               code: 1,
               message: "Invalid username or password"
             )
      @upon logging_in_with_forms("Supervisor", "WrongPassword")
      @then authentication_fails_with(message: "Invalid username or password")
    end

    scenario "returns an error when AuthService responds with HTTP failure" do
      @given creatio_auth_service_unavailable(status: 503, message: "Auth service maintenance")
      @upon logging_in_with_forms("Supervisor", "Supervisor")
      @then authentication_fails_with(status: 503, message: "Auth service maintenance")
    end

    scenario "returns an error when AuthService returns malformed non-JSON payload" do
      @given creatio_forms_auth_accepting(
               raw_body: "<html>Gateway Error</html>",
               plain_text: true
             )
      @upon logging_in_with_forms("Supervisor", "Supervisor")
      @then authentication_fails_with(message: "<html>Gateway Error</html>")
    end

    scenario "preserves '+' characters in BPMCSRF cookies and deduplicates repeated Set-Cookie names" do
      @given creatio_forms_auth_accepting(
               cookies: [
                 "BPMCSRF=old+val; Path=/",
                 "bpmcsrf=abc+123%2B==; Path=/",
                 ".ASPXAUTH=ticket1; Path=/"
               ]
             )
      @upon logging_in_with_forms("Supervisor", "pw")
      @then client_is_authenticated_via_forms(
              csrf_token: "abc+123+==",
              cookies_include: [".ASPXAUTH=ticket1"],
              single_cookie_name: "bpmcsrf"
            )
    end

    scenario "strips stale auth headers before forms login and upgrades a bare Req with base_url and req_options" do
      @given creatio_forms_auth_accepting(
               cookies: [".ASPXAUTH=fresh-auth; path=/", "BPMCSRF=fresh-csrf; path=/"]
             )
      @given creatio_client_with_oauth_config(
               auth_token: "stale-bearer",
               cookie: "stale-cookie",
               bpmcsrf: "stale-csrf"
             )
      @upon logging_in_with_forms("user", "pass")
      @then client_is_authenticated_via_forms(
              csrf_token: "fresh-csrf",
              cookies_include: ["BPMCSRF=fresh-csrf", ".ASPXAUTH=fresh-auth"]
            )
      @then request_omitted_headers(["authorization", "cookie", "bpmcsrf"])

      @given creatio_forms_auth_accepting(cookies: ["BPMCSRF=c1; path=/"])
      @given bare_req_without_base_url()
      @upon logging_in_with_forms("u", "p",
              base_url: "https://forms.example.com",
              with_server_req_options: true
            )
      @then client_is_authenticated_via_forms(
              csrf_token: "c1",
              expected_base_url: "https://forms.example.com"
            )
    end
  end

  describe "OAuth 2.0 Client Credentials & OpenID Discovery" do
    scenario "acquires an OAuth bearer token using client credentials" do
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://identity.mycreatio.com",
               client_id: "crm_service_app",
               client_secret: "crm_secret_xyz"
             )
      @given identity_service_issuing_token(
               access_token: "jwt_access_token_abc",
               expires_in: 3600
             )
      @upon logging_in_with_oauth()
      @then client_is_authenticated_via_oauth(
              access_token: "jwt_access_token_abc",
              expires_in: 3600,
              client_id: "crm_service_app",
              client_secret: "crm_secret_xyz"
            )
    end

    scenario "returns an error when OAuth client credentials are rejected" do
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://identity.mycreatio.com",
               client_id: "unknown_app",
               client_secret: "bad_secret"
             )
      @given identity_service_rejecting_client(
               status: 400,
               error: "invalid_client",
               error_description: "Unknown client credentials"
             )
      @upon logging_in_with_oauth()
      @then authentication_fails_with(
              status: 400,
              code: "invalid_client",
              message_contains: "Unknown client credentials"
            )
    end

    scenario "returns an error when OAuth client_id is missing" do
      @given creatio_client_with_oauth_config([])
      @upon logging_in_with_oauth()
      @then authentication_fails_with(message: "Missing :client_id for OAuth 2.0 authentication")
    end

    scenario "returns an error when OAuth client_secret is missing" do
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://identity.mycreatio.com",
               client_id: "crm_service_app"
             )
      @upon logging_in_with_oauth()
      @then authentication_fails_with(
              message: "Missing :client_secret for OAuth 2.0 authentication"
            )
    end

    scenario "checks Creatio OAuth health endpoint" do
      @given creatio_oauth_health_status(%{"status" => "Healthy", "version" => "8.2"})
      @upon checking_oauth_health()
      @then oauth_health_is(%{"status" => "Healthy", "version" => "8.2"})
    end

    scenario "retrieves OpenID configuration via client identity service URL" do
      @given identity_openid_discovery(%{
               "issuer" => "https://identity.mycreatio.com",
               "token_endpoint" => "https://identity.mycreatio.com/connect/token"
             })
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://identity.mycreatio.com"
             )
      @upon fetching_openid_configuration()
      @then openid_configuration_has(%{
              "issuer" => "https://identity.mycreatio.com",
              "token_endpoint" => "https://identity.mycreatio.com/connect/token"
            })
    end

    scenario "falls back to base_url /identity for OpenID discovery when identity_service_url is nil" do
      @given identity_openid_discovery(%{
               "issuer" => "https://mycreatio.com/identity",
               "token_endpoint" => "https://mycreatio.com/identity/connect/token"
             })
      @given creatio_client_with_oauth_config([])
      @upon fetching_openid_configuration()
      @then openid_configuration_has(%{
              "issuer" => "https://mycreatio.com/identity",
              "token_endpoint" => "https://mycreatio.com/identity/connect/token"
            })
    end

    scenario "retrieves OpenID configuration directly from identity service URL" do
      @given identity_openid_discovery(%{
               "issuer" => "https://identity.mycreatio.com",
               "grant_types_supported" => ["client_credentials"]
             })
      @upon fetching_openid_configuration(
              target: :url,
              url: "https://identity.mycreatio.com"
            )
      @then openid_configuration_has(%{
              "issuer" => "https://identity.mycreatio.com",
              "grant_types_supported" => ["client_credentials"]
            })
    end

    scenario "returns HTTP error when OpenID discovery endpoint fails" do
      @given identity_openid_discovery_unavailable(500)
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://identity.mycreatio.com"
             )
      @upon fetching_openid_configuration()
      @then openid_discovery_fails_with_status(500)
    end

    scenario "preserves plug from Client.from_req/2, strips stale auth headers, and supports token_url" do
      @given identity_openid_discovery(%{
               "issuer" => "https://id.test",
               "token_endpoint" => "https://id.test/connect/token"
             })
      @given creatio_client_from_req(
               req_headers: [{"bpmcsrf", "stale"}, {"cookie", "stale=1"}],
               identity_service_url: "https://id.test"
             )
      @upon fetching_openid_configuration()
      @then openid_configuration_has(%{
              "issuer" => "https://id.test",
              "token_endpoint" => "https://id.test/connect/token"
            })
      @then request_omitted_headers(["bpmcsrf", "cookie"])

      @given identity_service_issuing_token(access_token: "tok_from_plug", expires_in: 3600)
      @given creatio_client_from_req(
               req_headers: [{"bpmcsrf", "stale"}, {"cookie", "stale=1"}],
               token_url: "https://id.test/connect/token",
               client_id: "cid",
               client_secret: "csecret"
             )
      @upon logging_in_with_oauth()
      @then client_is_authenticated_via_oauth(
              access_token: "tok_from_plug",
              expires_in: 3600,
              client_id: "cid",
              client_secret: "csecret"
            )
      @then request_omitted_headers(["bpmcsrf", "cookie"])
    end

    scenario "normalizes identity_service_url, drops transient client_secret, and rejects blank tokens" do
      @given identity_service_issuing_token(
               path: "/0/connect/token",
               access_token: "valid-jwt",
               expires_in: 3600
             )
      @given creatio_client_with_oauth_config(client_id: "cid")
      @upon logging_in_with_oauth(
              identity_service_url: " https://id.creatio.com/0// ",
              client_secret: "transient-sec"
            )
      @then client_is_authenticated_via_oauth(
              access_token: "valid-jwt",
              expires_in: 3600,
              token_path: "/0/connect/token",
              identity_service_url: "https://id.creatio.com/0",
              clears_client_secret: true,
              client_id: "cid",
              client_secret: "transient-sec"
            )

      @upon attempting_blank_oauth_token_logins([nil, "", "   "])
      @then all_token_attempts_failed_with(status: 200, code: "OAuthMissingToken")
    end

    scenario "validates OAuth and OpenID discovery base URLs locally without network calls" do
      @given creatio_client_with_raw_urls(
               base_url: "",
               identity_service_url: nil,
               client_id: "cid",
               client_secret: "sec"
             )
      @upon fetching_openid_configuration()
      @then authentication_fails_with(message_contains: "URL")
      @upon logging_in_with_oauth(identity_service_url: "/relative-only")
      @then authentication_fails_with(message_contains: "URL")
    end

    scenario "handles IIS text/html BOM JSON, Healthy checks, and rejects WAF HTML or corrupt JSON" do
      @given creatio_oauth_health_status(
               "\uFEFF" <> Jason.encode!(%{"HasProblem" => false}),
               content_type: "text/html"
             )
      @upon checking_oauth_health()
      @then oauth_health_is(%{"HasProblem" => false})

      @given identity_openid_discovery(
               "\uFEFF" <> Jason.encode!(%{"issuer" => "https://id.test"}),
               content_type: "text/html"
             )
      @given creatio_client_with_oauth_config(identity_service_url: "https://crm.test")
      @upon fetching_openid_configuration()
      @then openid_configuration_has(%{"issuer" => "https://id.test"})

      @given creatio_oauth_health_status("Healthy", content_type: "text/html")
      @upon checking_oauth_health(with_server_req_options: true)
      @then oauth_health_is("Healthy")

      @given identity_service_issuing_token(content_type: "text/html", raw_body: @waf_html)
      @given creatio_client_with_oauth_config(
               identity_service_url: "https://crm.test",
               client_id: "cid",
               client_secret: "csec"
             )
      @upon logging_in_with_oauth()
      @then authentication_fails_with(status: 200)

      @given creatio_oauth_health_status(@waf_html, content_type: "text/html")
      @upon checking_oauth_health()
      @then authentication_fails_with(status: 200)

      @given identity_openid_discovery(@waf_html, content_type: "text/html")
      @upon fetching_openid_configuration()
      @then openid_discovery_fails_with_status(200)
      @upon fetching_openid_configuration(target: :url, url: "https://crm.test")
      @then openid_discovery_fails_with_status(200)

      @given creatio_oauth_health_status("{broken", content_type: "text/html")
      @upon checking_oauth_health()
      @then authentication_fails_with(status: 200)

      @given creatio_oauth_health_status("{broken", content_type: "application/json")
      @upon checking_oauth_health()
      @then authentication_fails_with(status: nil)
    end
  end
end
