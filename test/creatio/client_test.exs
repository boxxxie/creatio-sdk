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
end
