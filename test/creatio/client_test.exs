defmodule Creatio.ClientTest do
  use ExUnit.Case, async: true

  alias Creatio.Client

  describe "new/1" do
    test "initializes with base_url and strips trailing slashes" do
      client = Client.new(base_url: "https://mycreatio.com/")
      assert client.base_url == "https://mycreatio.com"
      assert client.req.options.base_url == "https://mycreatio.com"
      assert client.auth_mode == :none
      assert client.req.headers["accept"] == ["application/json; odata.metadata=minimal"]
    end

    test "initializes with auth_token" do
      client = Client.new(base_url: "https://mycreatio.com", auth_token: "secret123")
      assert client.auth_mode == :bearer
      assert client.auth_token == "secret123"
      assert client.req.headers["authorization"] == ["Bearer secret123"]
    end

    test "initializes with cookie and bpmcsrf" do
      client =
        Client.new(
          base_url: "https://mycreatio.com",
          cookie: ".ASPXAUTH=abc; BPMCSRF=xyz",
          bpmcsrf: "xyz"
        )

      assert client.auth_mode == :forms
      assert client.cookie == ".ASPXAUTH=abc; BPMCSRF=xyz"
      assert client.bpmcsrf == "xyz"
      assert client.req.headers["cookie"] == [".ASPXAUTH=abc; BPMCSRF=xyz"]
      assert client.req.headers["bpmcsrf"] == ["xyz"]
    end

    test "forwards custom req_options" do
      client = Client.new(base_url: "https://mycreatio.com", req_options: [retry: false])
      assert client.req.options.retry == false
    end

    test "initializes with map of options" do
      client = Client.new(%{base_url: "https://mycreatio.com", auth_token: "token123"})
      assert client.base_url == "https://mycreatio.com"
      assert client.auth_token == "token123"
      assert client.req.headers["forceusesession"] == ["true"]
    end

    test "initializes directly from %Req.Request{}" do
      req = Req.new(base_url: "https://mycreatio.com")
      client = Client.new(req)
      assert client.base_url == "https://mycreatio.com"
      assert client.req.headers["forceusesession"] == ["true"]
      assert Client.ensure_client(req) == client
      assert Client.ensure_client(client) == client
    end
  end

  describe "put_bearer_token/2" do
    test "updates client and request with authorization header" do
      client = Client.new(base_url: "https://mycreatio.com")
      assert is_nil(client.req.headers["authorization"])

      updated = Client.put_bearer_token(client, "new_token")
      assert updated.auth_mode == :bearer
      assert updated.auth_token == "new_token"
      assert updated.req.headers["authorization"] == ["Bearer new_token"]
    end
  end

  describe "put_forms_auth/3" do
    test "updates client and request with cookie and bpmcsrf headers" do
      client = Client.new(base_url: "https://mycreatio.com")

      updated = Client.put_forms_auth(client, "foo=bar", "csrf123")
      assert updated.auth_mode == :forms
      assert updated.cookie == "foo=bar"
      assert updated.bpmcsrf == "csrf123"
      assert updated.req.headers["cookie"] == ["foo=bar"]
      assert updated.req.headers["bpmcsrf"] == ["csrf123"]
    end
  end

  describe "put_header/3" do
    test "sets custom headers on the underlying Req client" do
      client =
        Client.new(base_url: "https://mycreatio.com")
        |> Client.put_header("x-custom-header", "custom-val")

      assert client.req.headers["x-custom-header"] == ["custom-val"]
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
  end
end
