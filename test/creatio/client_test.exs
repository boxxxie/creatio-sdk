defmodule Creatio.ClientTest do
  use ExUnit.Case, async: true

  alias Creatio.Client

  describe "new/1" do
    test "initializes from keyword options, maps, and %Req.Request{} with normalized URLs" do
      client = Client.new(base_url: "https://mycreatio.com/")
      assert client.base_url == "https://mycreatio.com"
      assert client.req.options.base_url == "https://mycreatio.com"
      assert client.auth_mode == :none
      assert client.req.headers["accept"] == ["application/json; odata.metadata=minimal"]

      map_client = Client.new(%{base_url: "https://mycreatio.com", auth_token: "token123"})
      assert map_client.base_url == "https://mycreatio.com"
      assert map_client.auth_token == "token123"
      assert map_client.req.headers["forceusesession"] == ["true"]

      req = Req.new(base_url: "https://mycreatio.com")
      req_client = Client.new(req)
      assert req_client.base_url == "https://mycreatio.com"
      assert req_client.req.headers["forceusesession"] == ["true"]
      assert Client.ensure_client(req) == req_client
      assert Client.ensure_client(req_client) == req_client

      with_identity =
        Client.new(
          base_url: "https://mycreatio.com/",
          identity_service_url: "https://id.mycreatio.com/0/"
        )

      assert with_identity.identity_service_url == "https://id.mycreatio.com/0"

      from_req_client = Client.from_req(req, identity_service_url: "https://id.mycreatio.com/0/")
      assert from_req_client.identity_service_url == "https://id.mycreatio.com/0"
    end

    test "configures bearer and forms auth modes and forwards req_options" do
      bearer = Client.new(base_url: "https://mycreatio.com", auth_token: "secret123")
      assert bearer.auth_mode == :bearer
      assert bearer.auth_token == "secret123"
      assert bearer.req.headers["authorization"] == ["Bearer secret123"]

      forms =
        Client.new(
          base_url: "https://mycreatio.com",
          cookie: ".ASPXAUTH=abc; BPMCSRF=xyz",
          bpmcsrf: "xyz"
        )

      assert forms.auth_mode == :forms
      assert forms.cookie == ".ASPXAUTH=abc; BPMCSRF=xyz"
      assert forms.bpmcsrf == "xyz"
      assert forms.req.headers["cookie"] == [".ASPXAUTH=abc; BPMCSRF=xyz"]
      assert forms.req.headers["bpmcsrf"] == ["xyz"]

      custom = Client.new(base_url: "https://mycreatio.com", req_options: [retry: false])
      assert custom.req.options.retry == false
    end
  end

  describe "header and auth mutators" do
    test "updates bearer token (rejecting blank tokens), forms auth cookies/BPMCSRF, and custom headers" do
      client = Client.new(base_url: "https://mycreatio.com")
      assert is_nil(client.req.headers["authorization"])

      assert_raise ArgumentError, fn ->
        Client.put_bearer_token(client, "")
      end

      bearer = Client.put_bearer_token(client, "new_token")
      assert bearer.auth_mode == :bearer
      assert bearer.auth_token == "new_token"
      assert bearer.req.headers["authorization"] == ["Bearer new_token"]

      forms = Client.put_forms_auth(client, "foo=bar", "csrf123")
      assert forms.auth_mode == :forms
      assert forms.cookie == "foo=bar"
      assert forms.bpmcsrf == "csrf123"
      assert forms.req.headers["cookie"] == ["foo=bar"]
      assert forms.req.headers["bpmcsrf"] == ["csrf123"]

      custom = Client.put_header(client, "x-custom-header", "custom-val")
      assert custom.req.headers["x-custom-header"] == ["custom-val"]
    end
  end

  describe "read_only mode and to_req/1" do
    test "exposes underlying Req request and preserves read_only_guard across auth updates" do
      client = Client.new(base_url: "https://mycreatio.com", read_only: true)
      assert client.read_only == true
      assert Client.to_req(client) == client.req
      assert Keyword.has_key?(client.req.request_steps, :read_only_guard)

      bearer_client = Client.put_bearer_token(client, "tok_123")
      assert bearer_client.read_only == true
      assert Keyword.has_key?(bearer_client.req.request_steps, :read_only_guard)

      forms_client = Client.put_forms_auth(client, ".ASPXAUTH=1", "csrf_1")
      assert forms_client.read_only == true
      assert Keyword.has_key?(forms_client.req.request_steps, :read_only_guard)
      assert is_nil(forms_client.auth_token)
      assert is_nil(forms_client.req.headers["authorization"])

      back_to_bearer = Client.put_bearer_token(forms_client, "tok_2")
      assert is_nil(back_to_bearer.cookie)
      assert is_nil(back_to_bearer.bpmcsrf)
      assert is_nil(back_to_bearer.req.headers["cookie"])
      assert is_nil(back_to_bearer.req.headers["bpmcsrf"])
    end

    test "normalizes read_only option to boolean and preserves from_req auth detection" do
      assert Client.new(base_url: "https://mycreatio.com", read_only: "false").read_only == false
      assert Client.new(base_url: "https://mycreatio.com", read_only: "true").read_only == true

      req_bearer =
        Req.new(base_url: "https://mycreatio.com", headers: [{"authorization", "Bearer abc"}])

      assert Client.from_req(req_bearer).auth_mode == :bearer

      req_forms =
        Req.new(
          base_url: "https://mycreatio.com",
          headers: [{"cookie", ".ASPXAUTH=abc"}, {"bpmcsrf", "csrf"}]
        )

      assert Client.from_req(req_forms).auth_mode == :forms
    end

    test "read_only_guard rejects non-read REST paths, false suffix matches, and duplicate steps" do
      client =
        Client.new(
          base_url: "https://mycreatio.com",
          read_only: true,
          req_options: [plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end]
        )

      read_only_steps =
        client.req.request_steps
        |> Keyword.keys()
        |> Enum.count(&(&1 == :read_only_guard))

      assert read_only_steps == 1

      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(client.req, url: "/0/rest/SomeService/GetOrMutate", json: %{})

      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(client.req,
                 url: "/0/DataService/json/SyncReply/FakeSelectQuery",
                 json: %{}
               )

      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(client.req, url: "/0/odata/Contact", json: %{})
    end

    test "inspect/1 redacts secrets and client.options strips sensitive credentials" do
      client =
        Client.new(
          base_url: "https://crm.test",
          identity_service_url: "https://ids.test",
          client_id: "public-cid",
          client_secret: "super-secret-client-secret",
          auth_token: "super-secret-jwt",
          cookie: ".ASPXAUTH=secret-cookie",
          bpmcsrf: "secret-csrf",
          read_only: true,
          req_options: [
            headers: [{"authorization", "Bearer header-secret"}, {"x-safe", "visible"}],
            auth: {:bearer, "basic-secret"},
            receive_timeout: 5_000
          ]
        )

      inspected = inspect(client)
      assert inspected =~ "https://crm.test"
      assert inspected =~ "public-cid"
      assert inspected =~ "read_only: true"
      refute inspected =~ "super-secret-client-secret"
      refute inspected =~ "super-secret-jwt"
      refute inspected =~ "secret-cookie"
      refute inspected =~ "secret-csrf"
      refute inspected =~ "header-secret"
      refute inspected =~ "basic-secret"
      refute inspected =~ "options:"
      refute inspected =~ "req:"

      refute Keyword.has_key?(client.options, :client_secret)
      refute Keyword.has_key?(client.options, :auth_token)
      refute Keyword.has_key?(client.options, :cookie)
      refute Keyword.has_key?(client.options, :bpmcsrf)
      assert client.options[:req_options] == [receive_timeout: 5_000]
    end

    test "normalizes string-keyed maps safely in new/1 and from_req/2" do
      client =
        Client.new(%{
          "base_url" => "https://crm.test/",
          "auth_token" => "tok-1",
          "read_only" => "true",
          "unknown_runtime_key_xyz" => "ignored"
        })

      assert client.base_url == "https://crm.test"
      assert client.auth_token == "tok-1"
      assert client.read_only == true

      from_req_client =
        Client.from_req(client.req, %{
          "read_only" => false,
          "unknown_from_req_key_xyz" => "ignored"
        })

      assert from_req_client.read_only == false
      refute Keyword.has_key?(from_req_client.req.request_steps, :read_only_guard)
    end

    test "new/1 handles map :req_options, preserves caller headers, and blocks IIS path bypasses in read_only_guard" do
      client =
        Client.new(
          base_url: "https://mycreatio.com",
          req_options: %{
            "retry" => false,
            headers: [{"accept", "application/xml"}, {"forceusesession", "false"}]
          }
        )

      assert client.req.options.retry == false
      assert Req.Request.get_header(client.req, "accept") == ["application/xml"]
      assert Req.Request.get_header(client.req, "forceusesession") == ["false"]

      ro =
        Client.new(
          base_url: "https://mycreatio.com",
          read_only: true,
          req_options: [plug: fn conn -> Req.Test.json(conn, %{"ok" => true}) end]
        )

      for path <- [
            "/0/DataService/json/SyncReply/DeleteQuery/..%5cSelectQuery",
            "/0/DataService/json/SyncReply/DeleteQuery/.%2e/SelectQuery",
            "/0/DataService/json/SyncReply/DeleteQuery/%252e%252e/SelectQuery",
            "/0/rest%2fCustomSvc/SelectQuery"
          ] do
        assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
                 Req.post(ro.req, url: path, json: %{})
      end
    end

    test "from_req/2 preserves existing auth headers on Req.Request and honors explicit overrides" do
      bearer_client =
        Client.new(
          base_url: "https://mycreatio.com",
          auth_token: "tok-123"
        )

      bearer_req = Client.to_req(bearer_client)
      rehydrated_bearer = Client.from_req(bearer_req)

      assert rehydrated_bearer.auth_mode == :bearer
      assert rehydrated_bearer.auth_token == "tok-123"
      assert Req.Request.get_header(rehydrated_bearer.req, "authorization") == ["Bearer tok-123"]

      # Custom non-Bearer Authorization scheme is also preserved when opts == []
      custom_req =
        Req.new(
          base_url: "https://mycreatio.com",
          headers: %{"authorization" => "CustomScheme xyz"}
        )

      rehydrated_custom = Client.from_req(custom_req)
      assert rehydrated_custom.auth_mode == :bearer
      assert rehydrated_custom.auth_token == nil

      assert Req.Request.get_header(rehydrated_custom.req, "authorization") == [
               "CustomScheme xyz"
             ]

      # Forms headers preserved when opts == []
      forms_client =
        Client.new(
          base_url: "https://mycreatio.com",
          cookie: ".ASPXAUTH=abc; BPMCSRF=csrf-1",
          bpmcsrf: "csrf-1"
        )

      rehydrated_forms = Client.from_req(Client.to_req(forms_client))
      assert rehydrated_forms.auth_mode == :forms
      assert rehydrated_forms.cookie == ".ASPXAUTH=abc; BPMCSRF=csrf-1"
      assert rehydrated_forms.bpmcsrf == "csrf-1"

      assert Req.Request.get_header(rehydrated_forms.req, "cookie") == [
               ".ASPXAUTH=abc; BPMCSRF=csrf-1"
             ]

      assert Req.Request.get_header(rehydrated_forms.req, "bpmcsrf") == ["csrf-1"]

      # Explicit forms credentials override an existing bearer Authorization header
      switched_to_forms =
        Client.from_req(bearer_req, cookie: ".ASPXAUTH=new", bpmcsrf: "csrf-new")

      assert switched_to_forms.auth_mode == :forms
      assert switched_to_forms.auth_token == nil
      assert switched_to_forms.cookie == ".ASPXAUTH=new"
      assert switched_to_forms.bpmcsrf == "csrf-new"
      assert Req.Request.get_header(switched_to_forms.req, "authorization") == []
      assert Req.Request.get_header(switched_to_forms.req, "cookie") == [".ASPXAUTH=new"]
      assert Req.Request.get_header(switched_to_forms.req, "bpmcsrf") == ["csrf-new"]

      # Explicit auth_token overrides existing forms headers
      switched_to_bearer = Client.from_req(Client.to_req(forms_client), auth_token: "new-tok")
      assert switched_to_bearer.auth_mode == :bearer
      assert switched_to_bearer.auth_token == "new-tok"
      assert switched_to_bearer.cookie == nil
      assert switched_to_bearer.bpmcsrf == nil

      assert Req.Request.get_header(switched_to_bearer.req, "authorization") == [
               "Bearer new-tok"
             ]

      assert Req.Request.get_header(switched_to_bearer.req, "cookie") == []
      assert Req.Request.get_header(switched_to_bearer.req, "bpmcsrf") == []

      # Explicit auth_mode: :none clears auth headers
      cleared = Client.from_req(bearer_req, auth_mode: :none)
      assert cleared.auth_mode == :none
      assert cleared.auth_token == nil
      assert Req.Request.get_header(cleared.req, "authorization") == []
    end

    test "read_only_guard blocks mutating or opaque $batch payloads while allowing read-only $batch" do
      plug = fn conn ->
        Req.Test.json(conn, %{"responses" => [%{"id" => "1", "status" => 200, "body" => %{}}]})
      end

      ro =
        Client.new(
          base_url: "https://mycreatio.com",
          read_only: true,
          req_options: [plug: plug, retry: false]
        )

      req = Client.to_req(ro)

      # JSON $batch containing a POST mutation is blocked
      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(req,
                 url: "/0/odata/$batch",
                 json: %{
                   "requests" => [
                     %{"id" => "1", "method" => "GET", "url" => "Contact"},
                     %{"id" => "2", "method" => "POST", "url" => "Contact", "body" => %{}}
                   ]
                 }
               )

      # Raw multipart $batch containing a PATCH mutation is blocked
      mutating_multipart =
        "--batch_ro\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\nPATCH Contact(00000000-0000-0000-0000-000000000001) HTTP/1.1\r\n\r\n{\"Name\":\"X\"}\r\n--batch_ro--\r\n"

      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(req,
                 url: "/0/odata/$batch",
                 headers: %{"content-type" => "multipart/mixed; boundary=batch_ro"},
                 body: mutating_multipart
               )

      # Compressed or uninspectable $batch body fails closed in read-only mode
      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(req,
                 url: "/0/odata/$batch",
                 headers: %{
                   "content-type" => "application/json",
                   "content-encoding" => "gzip"
                 },
                 body: :zlib.gzip(~s({"requests":[{"id":"1","method":"GET","url":"Contact"}]}))
               )

      # Non-POST method to /odata/$batch is blocked
      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.put(req, url: "/0/odata/$batch", json: %{"requests" => []})

      # Purely read-only GET JSON and multipart $batch requests are allowed
      assert {:ok, %Req.Response{status: 200}} =
               Req.post(req,
                 url: "/0/odata/$batch",
                 json: %{"requests" => [%{"id" => "1", "method" => "GET", "url" => "Contact"}]}
               )

      ro_multipart =
        "--batch_ro\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n\r\nGET Contact HTTP/1.1\r\n\r\n--batch_ro--\r\n"

      assert {:ok, %Req.Response{status: 200}} =
               Req.post(req,
                 url: "/0/odata/$batch",
                 headers: %{"content-type" => "multipart/mixed; boundary=batch_ro"},
                 body: ro_multipart
               )
    end

    test "Auth.login_oauth works on read_only client with custom token_url and accepts Req.Request" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/oauth2/v2.0/token"} ->
            Req.Test.json(conn, %{"access_token" => "ro-oauth-tok", "expires_in" => 3600})

          {"GET", "/0/api/OAuthHealthCheck"} ->
            Req.Test.json(conn, %{"status" => "Healthy"})

          _ ->
            Req.Test.json(conn, %{"ok" => true})
        end
      end

      ro =
        Client.new(
          base_url: "https://mycreatio.com",
          identity_service_url: "https://identity.mycreatio.com",
          client_id: "cid",
          client_secret: "csec",
          read_only: true,
          req_options: [plug: plug, retry: false]
        )

      assert {:ok, %Client{} = authed, %{"access_token" => "ro-oauth-tok"}} =
               Creatio.Auth.login_oauth(ro, token_url: "/oauth2/v2.0/token")

      assert authed.read_only == true
      assert authed.auth_token == "ro-oauth-tok"
      assert Keyword.has_key?(authed.req.request_steps, :read_only_guard)

      # Ensure read-only guard stays active on the authenticated client
      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Creatio.create(authed, "Contact", %{"Name" => "Blocked"})

      # %Req.Request{} input works for both login_oauth/2 and oauth_health_check/2
      raw_req =
        Req.new(
          base_url: "https://mycreatio.com",
          plug: plug,
          retry: false
        )

      assert {:ok, %Client{auth_token: "ro-oauth-tok"}, _body} =
               Creatio.Auth.login_oauth(raw_req,
                 identity_service_url: "https://identity.mycreatio.com",
                 client_id: "cid",
                 client_secret: "csec",
                 token_url: "/oauth2/v2.0/token"
               )

      assert {:ok, %{"status" => "Healthy"}} = Creatio.Auth.oauth_health_check(raw_req)
    end
  end
end

defmodule Creatio.ClientEnvTest do
  use ExUnit.Case, async: false

  alias Creatio.Client

  setup do
    previous = System.get_env("CREATIO_BASE_URL")

    on_exit(fn ->
      if is_binary(previous) do
        System.put_env("CREATIO_BASE_URL", previous)
      else
        System.delete_env("CREATIO_BASE_URL")
      end
    end)

    :ok
  end

  test "from_req/2 does not read CREATIO_BASE_URL from the environment while new/1 does" do
    System.put_env("CREATIO_BASE_URL", "https://env.creatio.com")

    req_without_base_url = Req.new()
    client_from_req = Client.from_req(req_without_base_url)
    assert client_from_req.base_url == ""

    client_from_req_with_opt =
      Client.from_req(req_without_base_url, base_url: "https://opt.creatio.com")

    assert client_from_req_with_opt.base_url == "https://opt.creatio.com"

    req_with_base_url = Req.new(base_url: "https://req.creatio.com")
    client_from_req_url = Client.from_req(req_with_base_url)
    assert client_from_req_url.base_url == "https://req.creatio.com"

    client_from_new = Client.new()
    assert client_from_new.base_url == "https://env.creatio.com"
  end

  test "from_req/2 ignores CREATIO_READ_ONLY env and application config" do
    prev_env = System.get_env("CREATIO_READ_ONLY")
    prev_app = Application.get_env(:creatio, :read_only)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CREATIO_READ_ONLY", prev_env),
        else: System.delete_env("CREATIO_READ_ONLY")

      if prev_app != nil,
        do: Application.put_env(:creatio, :read_only, prev_app),
        else: Application.delete_env(:creatio, :read_only)
    end)

    System.put_env("CREATIO_READ_ONLY", "true")
    Application.put_env(:creatio, :read_only, true)

    assert Client.new(base_url: "https://crm.test").read_only == true

    req = Req.new(base_url: "https://crm.test")
    client = Client.from_req(req)
    assert client.read_only == false
    refute Keyword.has_key?(client.req.request_steps, :read_only_guard)
  end

  test "explicit forms auth and explicit auth_token: nil are not overridden by ambient env tokens" do
    prev_env = System.get_env("CREATIO_AUTH_TOKEN")
    prev_app = Application.get_env(:creatio, :auth_token)

    on_exit(fn ->
      if prev_env,
        do: System.put_env("CREATIO_AUTH_TOKEN", prev_env),
        else: System.delete_env("CREATIO_AUTH_TOKEN")

      if prev_app != nil,
        do: Application.put_env(:creatio, :auth_token, prev_app),
        else: Application.delete_env(:creatio, :auth_token)
    end)

    System.put_env("CREATIO_AUTH_TOKEN", "ambient-env-token")
    Application.put_env(:creatio, :auth_token, "ambient-app-token")

    forms_client =
      Client.new(base_url: "https://crm.test", cookie: ".ASPXAUTH=c1", bpmcsrf: "csrf1")

    assert forms_client.auth_mode == :forms
    assert forms_client.auth_token == nil
    assert Req.Request.get_header(forms_client.req, "cookie") == [".ASPXAUTH=c1"]
    assert Req.Request.get_header(forms_client.req, "bpmcsrf") == ["csrf1"]
    assert Req.Request.get_header(forms_client.req, "authorization") == []

    none_client = Client.new(base_url: "https://crm.test", auth_token: nil)
    assert none_client.auth_mode == :none
    assert none_client.auth_token == nil
    assert Req.Request.get_header(none_client.req, "authorization") == []
  end

  test "disabling read_only via from_req/2 clears current_request_steps and executes requests without KeyError" do
    plug = fn conn -> Req.Test.json(conn, %{"ok" => true}) end

    ro_client =
      Client.new(
        base_url: "https://mycreatio.com",
        read_only: true,
        req_options: [plug: plug]
      )

    assert :read_only_guard in ro_client.req.current_request_steps

    rw_client = Client.from_req(ro_client.req, read_only: false)
    refute Keyword.has_key?(rw_client.req.request_steps, :read_only_guard)
    refute :read_only_guard in rw_client.req.current_request_steps

    assert {:ok, %Req.Response{status: 200}} =
             Req.post(rw_client.req, url: "/0/odata/Contact", json: %{"Name" => "Alice"})
  end

  test "read_only_guard blocks case-insensitive /0/rest/ paths and non-POST methods on whitelisted suffixes" do
    plug = fn conn -> Req.Test.json(conn, %{"ok" => true}) end

    ro =
      Client.new(
        base_url: "https://mycreatio.com",
        read_only: true,
        req_options: [plug: plug]
      )

    for {method, path} <- [
          {:post, "/0/REST/MyService/AuthService.svc/Login"},
          {:post, "/0/Rest/MyService/DataService/json/SyncReply/SelectQuery"},
          {:delete, "/ServiceModel/AuthService.svc/Login"},
          {:put, "/0/DataService/json/SyncReply/SelectQuery"},
          {:patch, "/connect/token"}
        ] do
      assert {:error, %Creatio.Error{status: 403, code: "ReadOnlyMode"}} =
               Req.request(ro.req, method: method, url: path, json: %{})
    end
  end

  test "handles UTF-8 BOM-prefixed application/json responses and trims env/bearer secrets" do
    bom_plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "\uFEFF" <> Jason.encode!(%{"value" => [%{"Id" => "1"}]}))
    end

    default_client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: bom_plug])
    assert default_client.req.options[:decode_body] == false
    assert {:ok, [%{"Id" => "1"}]} = Creatio.OData.list(default_client, "Contact")

    explicit_decode_client =
      Client.new(
        base_url: "https://mycreatio.com",
        req_options: [plug: bom_plug, decode_body: true]
      )

    assert {:ok, [%{"Id" => "1"}]} = Creatio.OData.list(explicit_decode_client, "Contact")

    prev_url = System.get_env("CREATIO_BASE_URL")
    prev_tok = System.get_env("CREATIO_AUTH_TOKEN")
    prev_cid = System.get_env("CREATIO_CLIENT_ID")
    prev_sec = System.get_env("CREATIO_CLIENT_SECRET")

    on_exit(fn ->
      for {k, v} <- [
            {"CREATIO_BASE_URL", prev_url},
            {"CREATIO_AUTH_TOKEN", prev_tok},
            {"CREATIO_CLIENT_ID", prev_cid},
            {"CREATIO_CLIENT_SECRET", prev_sec}
          ] do
        if is_binary(v), do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    System.put_env("CREATIO_BASE_URL", " https://env.creatio.com/\n")
    System.put_env("CREATIO_AUTH_TOKEN", " env-token \n")
    System.put_env("CREATIO_CLIENT_ID", " env-cid \n")
    System.put_env("CREATIO_CLIENT_SECRET", " env-csec \n")

    trimmed = Client.new()
    assert trimmed.base_url == "https://env.creatio.com"
    assert trimmed.auth_token == "env-token"
    assert trimmed.client_id == "env-cid"
    assert trimmed.client_secret == "env-csec"
    assert Req.Request.get_header(trimmed.req, "authorization") == ["Bearer env-token"]

    updated = Client.put_bearer_token(trimmed, "  new-tok \n")
    assert updated.auth_token == "new-tok"
    assert Req.Request.get_header(updated.req, "authorization") == ["Bearer new-tok"]
  end
end
