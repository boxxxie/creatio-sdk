defmodule Creatio.Features.AuthenticationTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.AuthDSL

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
  end
end
