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

    test "to_multipart/2 builds valid multipart/mixed body with changesets" do
      batch =
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "Alice"}, atomicity_group: "g1")
        |> Batch.add_get("Contact", "uuid-1")

      {boundary, body} = Batch.to_multipart(batch, boundary: "test_batch_123")
      assert boundary == "test_batch_123"
      assert String.contains?(body, "--test_batch_123")
      assert String.contains?(body, "Content-Type: multipart/mixed; boundary=changeset_g1_")
      assert String.contains?(body, "POST Contact HTTP/1.1")
      assert String.contains?(body, "GET Contact(uuid-1) HTTP/1.1")
      assert String.ends_with?(body, "--test_batch_123--\r\n")
    end
  end

  describe "Batch.execute/3 (JSON format)" do
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

  describe "Batch.execute/3 (Multipart format)" do
    test "executes multipart/mixed batch request and parses JSON response" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/$batch"
        assert conn.method == "POST"

        content_type = get_req_header(conn, "content-type") |> List.first()
        assert String.starts_with?(content_type, "multipart/mixed; boundary=")

        {:ok, body, conn} = read_body(conn)
        assert String.contains?(body, "POST Contact HTTP/1.1")

        responses = [
          %{"id" => "1", "status" => 201, "body" => %{"Id" => "m1"}}
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"responses" => responses}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      batch =
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "Multi Alice"}, id: "1")

      assert {:ok, [r]} = Batch.execute(client, batch, format: :multipart)
      assert r.id == "1"
      assert r.status == 201
      assert r.body["Id"] == "m1"
    end

    test "parses multipart/mixed MIME response body" do
      raw_multipart_response = """
      --batch_response_123
      Content-Type: multipart/mixed; boundary=changeset_response_456

      --changeset_response_456
      Content-Type: application/http
      Content-Transfer-Encoding: binary

      HTTP/1.1 201 Created
      Content-Type: application/json; odata=verbose
      Content-ID: req_1

      {"Id": "new-guid", "Name": "Created"}
      --changeset_response_456
      Content-Type: application/http
      Content-Transfer-Encoding: binary

      HTTP/1.1 204 No Content
      Content-ID: req_2


      --changeset_response_456--
      --batch_response_123
      Content-Type: application/http
      Content-Transfer-Encoding: binary

      HTTP/1.1 200 OK
      Content-Type: application/json; odata=verbose
      Content-ID: req_3

      {"Name": "Found"}
      --batch_response_123--
      """

      assert {:ok, responses} = Batch.parse_multipart_response(raw_multipart_response)
      assert length(responses) == 3

      [r1, r2, r3] = responses
      assert r1.id == "req_1"
      assert r1.status == 201
      assert r1.body["Id"] == "new-guid"

      assert r2.id == "req_2"
      assert r2.status == 204

      assert r3.id == "req_3"
      assert r3.status == 200
      assert r3.body["Name"] == "Found"
    end

    test "executes raw multipart string body against endpoint" do
      raw_body =
        "--batch_999\r\nContent-Type: application/http\r\n\r\nGET Contact HTTP/1.1\r\n\r\n--batch_999--\r\n"

      plug = fn conn ->
        content_type = get_req_header(conn, "content-type") |> List.first()
        assert String.contains?(content_type, "boundary=batch_999")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"responses" => [%{"id" => "1", "status" => 200, "body" => []}]})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, [r]} = Batch.execute(client, raw_body)
      assert r.status == 200
    end

    test "handles single entity response in batch execution (Postman collection format)" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "@odata.context" => "https://mycreatio.com/0/odata/$metadata#City/$entity",
            "Id" => "fbd0565f-fa8a-4214-ae89-c976c5f3acb4",
            "Name" => "San Francisco"
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      batch = Batch.new() |> Batch.add_create("City", %{"Name" => "San Francisco"})

      assert {:ok, [resp]} = Batch.execute(client, batch)
      assert resp.status == 200
      assert resp.body["Id"] == "fbd0565f-fa8a-4214-ae89-c976c5f3acb4"
      assert resp.body["Name"] == "San Francisco"
    end

    test "sends prefer continue-on-error header when continue_on_error: true" do
      plug = fn conn ->
        prefer = get_req_header(conn, "prefer") |> List.first()
        assert prefer == "continue-on-error"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"responses" => []}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      batch = Batch.new(continue_on_error: true) |> Batch.add_get("Contact", "123")

      assert {:ok, []} = Batch.execute(client, batch)
      assert {:ok, []} = Batch.execute(client, batch, format: :multipart)
    end

    test "multipart payload building and response parsing" do
      batch =
        Batch.new()
        |> Batch.add_get("Contact", "1")
        |> Batch.add_create("Contact", %{"Name" => "Test"})
        |> Batch.add_update("Contact", "1", %{"Name" => "Updated"})
        |> Batch.add_delete("Contact", "1")

      assert {boundary, body} = Batch.to_multipart(batch)
      assert is_binary(boundary) and is_binary(body)
      assert is_map(Batch.to_payload(batch))

      multipart_resp =
        "--changeset\r\nContent-Type: application/http\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"value\": []}\r\n--changeset--"

      assert {:ok, [resp]} = Batch.parse_multipart_response(multipart_resp, "changeset")
      assert resp.status == 200
      assert Creatio.Batch.Response.success?(resp)
      refute Creatio.Batch.Response.error?(resp)
    end
  end
end
