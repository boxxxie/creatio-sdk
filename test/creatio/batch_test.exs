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
      assert req2["url"] == "Contact({id-1})"
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
  end
end
