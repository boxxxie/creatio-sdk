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
end
