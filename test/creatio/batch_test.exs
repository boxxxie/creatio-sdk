defmodule Creatio.BatchTest do
  use ExUnit.Case, async: true

  alias Creatio.Batch
  alias Creatio.Batch.Response
  alias Creatio.Error

  describe "Batch construction and JSON payload serialization" do
    test "adds mixed operations and builds JSON payload preserving atomicity groups and order" do
      batch =
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "Alice"})
        |> Batch.add_update("Contact", "{id-1}", %{"Name" => "Alice Updated"},
          id: "u1",
          atomicity_group: "group1"
        )
        |> Batch.add_delete("Contact", "id-2", id: "d1", atomicity_group: "group1")
        |> Batch.add_get("Contact", "id-3", id: "g1")
        |> Batch.add("PATCH", "Account(id-4)", body: %{"Name" => "Acme"}, id: "raw_1")

      payload = Batch.to_payload(batch)
      assert length(payload["requests"]) == 5

      [req1, req2, req3, req4, req5] = payload["requests"]
      assert req1["method"] == "POST"
      assert req1["url"] == "Contact"
      assert req1["id"] == "req_1"
      assert req1["body"] == %{"Name" => "Alice"}

      assert req2["method"] == "PATCH"
      assert req2["url"] == "Contact(id-1)"
      assert req2["id"] == "u1"
      assert req2["atomicityGroup"] == "group1"

      assert req3["method"] == "DELETE"
      assert req3["url"] == "Contact(id-2)"
      assert req3["id"] == "d1"
      assert req3["atomicityGroup"] == "group1"

      assert req4["method"] == "GET"
      assert req4["url"] == "Contact(id-3)"
      assert req4["id"] == "g1"
      refute Map.has_key?(req4, "body")

      assert req5["method"] == "PATCH"
      assert req5["url"] == "Account(id-4)"
      assert req5["id"] == "raw_1"
    end
  end

  describe "Batch multipart/mixed payload building and response parsing" do
    test "serializes changesets for grouped writes and top-level parts for standalone GETs" do
      batch =
        Batch.new()
        |> Batch.add_get("Contact", "1", id: "get_1")
        |> Batch.add_create("Contact", %{"Name" => "Bob"}, id: "create_1", atomicity_group: "g1")
        |> Batch.add_update("Contact", "2", %{"Name" => "Cara"},
          id: "update_1",
          atomicity_group: "g1"
        )

      {boundary, multipart_body} = Batch.to_multipart(batch, boundary: "batch_test_123")

      assert boundary == "batch_test_123"
      assert multipart_body =~ "--batch_test_123\r\n"
      assert multipart_body =~ "--batch_test_123--\r\n"
      assert multipart_body =~ "Content-ID: get_1"
      assert multipart_body =~ "GET Contact(1) HTTP/1.1"
      assert multipart_body =~ "multipart/mixed; boundary=changeset_g1_"
      assert multipart_body =~ "Content-ID: create_1"
      assert multipart_body =~ "Content-ID: update_1"
      assert multipart_body =~ ~s({"Name":"Bob"})
    end

    test "parses multipart/mixed MIME response body with standalone parts and inner changeset" do
      raw_response =
        """
        --batchresponse_outer
        Content-Type: application/http
        Content-Transfer-Encoding: binary
        Content-ID: req_1

        HTTP/1.1 201 Created
        Content-Type: application/json; charset=utf-8

        {"Id":"c1","Name":"Alice"}
        --batchresponse_outer
        Content-Type: multipart/mixed; boundary=changeset_grpA_999

        --changeset_grpA_999
        Content-Type: application/http
        Content-Transfer-Encoding: binary
        Content-ID: req_2

        HTTP/1.1 204 No Content

        --changeset_grpA_999
        Content-Type: application/http
        Content-Transfer-Encoding: binary
        Content-ID: req_3

        HTTP/1.1 200 OK
        Content-Type: application/json

        {"Id":"c2"}
        --changeset_grpA_999--
        --batchresponse_outer--
        """
        |> String.replace("\n", "\r\n")

      assert {:ok, responses} = Batch.parse_multipart_response(raw_response)
      assert [r1, r2, r3] = responses

      assert %Response{id: "req_1", status: 201, body: %{"Id" => "c1", "Name" => "Alice"}} = r1
      assert Response.success?(r1)
      refute Response.error?(r1)

      assert %Response{id: "req_2", status: 204, body: nil, atomicity_group: "grpA"} = r2
      assert Response.success?(r2)

      assert %Response{id: "req_3", status: 200, body: %{"Id" => "c2"}, atomicity_group: "grpA"} =
               r3

      assert Response.success?(r3)
    end

    test "returns empty list when boundary cannot be detected and supports explicit boundary override" do
      assert {:ok, []} = Batch.parse_multipart_response("plain text without boundaries")

      explicit_body =
        """
        --changeset_1
        Content-Type: application/http
        Content-Transfer-Encoding: binary

        HTTP/1.1 404 Not Found
        Content-Type: application/json

        {"error":{"code":"NotFound","message":"Missing"}}
        --changeset_1--
        """
        |> String.replace("\n", "\r\n")

      assert {:ok, [err_resp]} = Batch.parse_multipart_response(explicit_body, "changeset_1")
      assert err_resp.status == 404
      assert Response.error?(err_resp)
      refute Response.success?(err_resp)

      assert %Error{status: 404, code: "NotFound", message: "Missing"} =
               Response.to_error(err_resp)
    end

    test "gives ungrouped writes separate changesets, keeps GETs outside changesets, and preserves request order" do
      batch =
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "Write1"}, id: "w1")
        |> Batch.add_get("Contact", "1", id: "g1", atomicity_group: "g_ignored")
        |> Batch.add_update("Contact", "2", %{"Name" => "Write2"}, id: "w2")

      {boundary, body} = Batch.to_multipart(batch, boundary: "batch_order_test")
      parts = String.split(body, "--#{boundary}") |> Enum.slice(1, 3)

      assert Enum.at(parts, 0) =~ "Content-ID: w1"
      assert Enum.at(parts, 0) =~ "multipart/mixed; boundary=changeset_"
      assert Enum.at(parts, 1) =~ "GET Contact(1) HTTP/1.1"
      refute Enum.at(parts, 1) =~ "changeset_"
      assert Enum.at(parts, 2) =~ "Content-ID: w2"
      assert Enum.at(parts, 2) =~ "multipart/mixed; boundary=changeset_"
    end

    test "case-insensitive header override in Batch.add/4" do
      batch =
        Batch.new()
        |> Batch.add("PATCH", "Contact(1)",
          body: %{"Name" => "X"},
          headers: %{"Content-Type" => "application/json"}
        )

      [req] = Batch.to_payload(batch)["requests"]
      assert req["headers"]["Content-Type"] == "application/json"
      refute Map.has_key?(req["headers"], "content-type")
    end

    test "parses HTTP/2 parts, preserves body whitespace, and ignores nested MIME strings inside JSON body" do
      raw =
        """
        --batchresponse_outer
        Content-Type: application/http
        Content-Transfer-Encoding: binary
        Content-ID: req_1

        HTTP/2 200 OK
        Content-Type: application/json

        {"Body":"  --fake_boundary\\r\\nContent-Type: text/plain  "}
        --batchresponse_outer--
        """
        |> String.replace("\n", "\r\n")

      assert {:ok, [resp]} = Batch.parse_multipart_response(raw)
      assert resp.status == 200
      assert resp.body == %{"Body" => "  --fake_boundary\r\nContent-Type: text/plain  "}
    end

    test "blocks atom-keyed and atom-method mutations in read-only mode" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com", read_only: true)

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               Batch.execute(client, [%{method: :post, url: "Contact", body: %{"Name" => "X"}}])

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               Batch.execute(client, [%{method: "DELETE", url: "Contact(1)"}])
    end

    test "handles multipart response returned in JSON batch mode and HTML 200 error response" do
      multipart_resp_body =
        "--batch_srv\r\nContent-Type: application/http\r\nContent-ID: r1\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n--batch_srv--\r\n"

      multipart_client =
        Creatio.Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("multipart/mixed; boundary=batch_srv")
              |> Plug.Conn.send_resp(200, multipart_resp_body)
            end
          ]
        )

      assert {:ok, [%Response{id: "r1", status: 204}]} =
               Batch.execute(multipart_client, Batch.new() |> Batch.add_get("Contact", "1"))

      html_client =
        Creatio.Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, "<html>Login Required</html>")
            end
          ]
        )

      assert {:error, %Error{status: 200}} =
               Batch.execute(html_client, Batch.new() |> Batch.add_get("Contact", "1"))
    end
  end
end
