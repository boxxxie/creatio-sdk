defmodule Creatio.BatchTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Batch, Client}

  describe "Batch construction" do
    test "constructs batch payload with atomicity groups and operations" do
      batch =
        Batch.new(continue_on_error: true)
        |> Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "grp1")
        |> Batch.add_update("Contact", "uuid-1", %{"JobTitle" => "VP"}, atomicity_group: "grp1")
        |> Batch.add_delete("Contact", "uuid-2")

      assert batch.continue_on_error == true
      payload = Batch.to_payload(batch)

      requests = payload["requests"]
      assert length(requests) == 3

      req1 = Enum.at(requests, 0)
      assert req1["method"] == "POST"
      assert req1["url"] == "Contact"
      assert req1["body"] == %{"Name" => "Alice"}
      assert req1["atomicityGroup"] == "grp1"

      req2 = Enum.at(requests, 1)
      assert req2["method"] == "PATCH"
      assert req2["url"] == "Contact(uuid-1)"
      assert req2["body"] == %{"JobTitle" => "VP"}
      assert req2["atomicityGroup"] == "grp1"

      req3 = Enum.at(requests, 2)
      assert req3["method"] == "DELETE"
      assert req3["url"] == "Contact(uuid-2)"
      assert is_nil(req3["atomicityGroup"])
    end
  end

  describe "Batch.execute/3" do
    test "executes batch request and parses response objects" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/$batch"
        assert conn.method == "POST"
        assert get_req_header(conn, "prefer") == ["continue-on-error"]
        assert get_req_header(conn, "forceusesession") == ["true"]

        content_type = get_req_header(conn, "content-type") |> List.first()
        assert String.contains?(content_type, "application/json")
        assert String.contains?(content_type, "IEEE754Compatible=true")

        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert length(payload["requests"]) == 2

        responses = [
          %{
            "id" => "req_1",
            "status" => 201,
            "headers" => %{
              "location" => "https://mycreatio.com/0/odata/Contact(uuid-new)",
              "content-type" => "application/json"
            },
            "body" => %{"Id" => "uuid-new", "Name" => "Alice"}
          },
          %{
            "id" => "req_2",
            "status" => 204,
            "headers" => %{},
            "body" => nil
          }
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"responses" => responses}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      batch =
        Batch.new(continue_on_error: true)
        |> Batch.add_create("Contact", %{"Name" => "Alice"})
        |> Batch.add_delete("Contact", "uuid-old")

      assert {:ok, responses} = Batch.execute(client, batch)
      assert length(responses) == 2

      resp1 = Enum.at(responses, 0)
      assert resp1.id == "req_1"
      assert resp1.status == 201
      assert resp1.body["Id"] == "uuid-new"
      assert Batch.Response.success?(resp1) == true
      assert Batch.Response.error?(resp1) == false

      resp2 = Enum.at(responses, 1)
      assert resp2.id == "req_2"
      assert resp2.status == 204
      assert is_nil(resp2.body)
      assert Batch.Response.success?(resp2) == true
    end

    test "supports add_get and handles failed item with to_error" do
      plug = fn conn ->
        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert length(payload["requests"]) == 2

        get_req = Enum.at(payload["requests"], 0)
        assert get_req["method"] == "GET"
        assert get_req["url"] == "Contact(123)"

        responses = [
          %{
            "id" => "req_1",
            "status" => "200",
            "body" => %{"Id" => "123", "Name" => "Bob"}
          },
          %{
            "id" => "req_2",
            "status" => "404",
            "body" => %{"error" => %{"message" => "Not found"}}
          }
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"responses" => responses}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      batch =
        Batch.new()
        |> Batch.add_get("Contact", "123")
        |> Batch.add_get("Contact(999)")

      assert {:ok, [r1, r2]} = Batch.execute(client, batch)
      assert r1.status == 200
      assert Batch.Response.success?(r1) == true

      assert r2.status == 404
      assert Batch.Response.error?(r2) == true
      err = Batch.Response.to_error(r2)
      assert err.status == 404
      assert err.message == "Not found"
    end
  end
end
