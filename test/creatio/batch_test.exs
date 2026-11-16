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
      assert req2["url"] == "Contact('id-1')"
      assert req2["id"] == "u1"
      assert req2["atomicityGroup"] == "group1"

      assert req3["method"] == "DELETE"
      assert req3["url"] == "Contact('id-2')"
      assert req3["id"] == "d1"
      assert req3["atomicityGroup"] == "group1"

      assert req4["method"] == "GET"
      assert req4["url"] == "Contact('id-3')"
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
      assert multipart_body =~ "GET Contact('1') HTTP/1.1"
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
      assert Enum.at(parts, 1) =~ "GET Contact('1') HTTP/1.1"
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

    test "exposes opaque encapsulation helpers size/1 and requests/1" do
      empty = Batch.new()
      assert Batch.size(empty) == 0
      assert Batch.requests(empty) == []

      batch =
        empty
        |> Batch.add_get("Contact", "00000000-0000-0000-0000-000000000001")
        |> Batch.add_create("Account", %{"Name" => "Acme"})

      assert Batch.size(batch) == 2

      assert [
               %{"method" => "GET", "url" => url1},
               %{"method" => "POST", "url" => "Account", "body" => %{"Name" => "Acme"}}
             ] = Batch.requests(batch)

      assert String.contains?(url1, "Contact(00000000-0000-0000-0000-000000000001)")
    end

    test "raises ArgumentError on invalid :format option" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      assert_raise ArgumentError, ~r/invalid batch :format option/, fn ->
        Batch.execute(client, Batch.new() |> Batch.add_get("Contact"), format: :multiprat)
      end

      assert_raise ArgumentError, ~r/invalid batch :format option/, fn ->
        Batch.execute(client, "raw body", boundary: "b1", format: :multiprat)
      end
    end

    test "supports O(1) large builds, iodata multipart, minimal metadata/return, and multi-byte UTF-8 CRLF parsing" do
      batch =
        Enum.reduce(1..2_000, Batch.new(continue_on_error: true, return: :minimal), fn i, acc ->
          Batch.add_get(acc, "Contact", "id-#{i}")
        end)

      %{"requests" => requests} = Batch.to_payload(batch)
      assert length(requests) == 2_000
      assert hd(requests)["id"] == "req_1"
      assert List.last(requests)["id"] == "req_2000"
      assert hd(requests)["headers"]["Accept"] == "application/json; odata.metadata=minimal"
      assert hd(requests)["headers"]["Prefer"] == "continue-on-error, return=minimal"
      refute Map.has_key?(hd(requests)["headers"], "Content-Type")

      small_batch =
        Batch.new(return: :minimal)
        |> Batch.add_create("Contact", %{"Name" => "José 🚀"})

      {boundary, iodata} = Batch.to_multipart_iodata(small_batch, boundary: "b_io")
      assert boundary == "b_io"
      assert is_list(iodata)
      bin_body = IO.iodata_to_binary(iodata)
      assert bin_body =~ "--b_io\r\n"
      assert bin_body =~ "Prefer: return=minimal\r\n"
      assert bin_body =~ ~s({"Name":"José 🚀"})
      assert bin_body =~ "--b_io--\r\n"

      get_only = Batch.new() |> Batch.add_get("Contact", "1")

      assert Batch.to_multipart(get_only, boundary: "b_get") ==
               {"b_get",
                get_only
                |> Batch.to_multipart_iodata(boundary: "b_get")
                |> elem(1)
                |> IO.iodata_to_binary()}

      raw_utf8 =
        "--b_utf8\r\n" <>
          "Content-Type: application/http\r\n" <>
          "Content-ID: req_1\r\n\r\n" <>
          "HTTP/1.1 201 Created\r\n" <>
          "Content-Type: application/json; odata.metadata=minimal\r\n\r\n" <>
          ~s({"Id":"u1","Name":"José 🚀"}) <>
          "\r\n--b_utf8--\r\n"

      assert {:ok, [%Response{id: "req_1", status: 201, body: %{"Name" => "José 🚀"}}]} =
               Batch.parse_multipart_response(raw_utf8, "b_utf8")
    end

    test "drops unused :requests field and validates IDs, boundary, atomicity_group, and sub-request URLs" do
      batch = Batch.new()
      refute Map.has_key?(batch, :requests)

      for bad_id <- ["1)/../../rest/CustomService/Trigger?x=(", "../etc", "a/b", "1?x=2"] do
        assert_raise ArgumentError, fn ->
          Batch.add_delete(batch, "Contact", bad_id)
        end
      end

      assert_raise ArgumentError, ~r/invalid batch sub-request URL/, fn ->
        Batch.add(batch, "GET", "Contact\r\nX-Injected: yes")
      end

      assert_raise ArgumentError, ~r/invalid batch sub-request URL/, fn ->
        Batch.add(batch, "GET", "../rest/CustomSvc/Op")
      end

      assert_raise ArgumentError, ~r/invalid atomicity_group/, fn ->
        Batch.add_create(batch, "Contact", %{"Name" => "A"}, atomicity_group: "g1; bad")
      end

      assert_raise ArgumentError, ~r/invalid boundary/, fn ->
        Batch.to_multipart_iodata(Batch.add_get(batch, "Contact"), boundary: "b1;\r\nbad")
      end

      assert_raise ArgumentError, fn ->
        Batch.execute(Creatio.Client.new(base_url: "https://test.creatio.com"), "raw",
          format: :multipart,
          boundary: "bad;\r\nX-Injected: yes"
        )
      end
    end

    test "rejects external :url overrides, IIS path bypasses, and CRLF injection in method/headers" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      assert_raise ArgumentError, ~r/origin/, fn ->
        Batch.execute(client, Batch.new() |> Batch.add_get("Contact"),
          url: "https://attacker.example/0/odata/$batch"
        )
      end

      assert_raise ArgumentError, ~r/Invalid batch endpoint URL/, fn ->
        Batch.execute(client, Batch.new() |> Batch.add_get("Contact"),
          url: "//attacker.example/0/odata/$batch"
        )
      end

      for bad_url <- [
            "Contact/..%5crest/CustomSvc/Op",
            "Contact/.%2e/rest/CustomSvc/Op",
            "Contact/%252e%252e/rest/CustomSvc/Op",
            "/0/rest%2fCustomSvc/Op"
          ] do
        assert_raise ArgumentError, ~r/invalid batch sub-request URL/, fn ->
          Batch.add(Batch.new(), "GET", bad_url)
        end
      end

      assert_raise ArgumentError, ~r/invalid batch HTTP method/, fn ->
        Batch.add(Batch.new(), "GET /evil HTTP/1.1\r\nX-Injected: 1", "Contact")
      end

      assert_raise ArgumentError, ~r/invalid batch header name/, fn ->
        Batch.add(Batch.new(), "GET", "Contact", headers: %{"Bad\r\nHeader" => "v"})
      end

      assert_raise ArgumentError, ~r/invalid batch header value/, fn ->
        Batch.add(Batch.new(), "GET", "Contact", headers: %{"X-Test" => "ok\r\nX-Evil: 1"})
      end

      assert_raise ArgumentError, ~r/invalid batch header value/, fn ->
        Batch.execute(client, [%{method: "GET", url: "Contact", headers: %{"X-A" => "a\nb"}}])
      end
    end

    test "handles non-boundary item IDs, 49-byte atomicity_group, underscore/hyphen groups, empty batch, and query opts in multipart/OData" do
      batch =
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "A"}, id: "op with spaces:1/2")
        |> Batch.add_create("Contact", %{"Name" => "B"}, atomicity_group: "order_sync")
        |> Batch.add_create("Contact", %{"Name" => "C"}, atomicity_group: "order-sync.v1")
        |> Batch.add_create("Contact", %{"Name" => "D"},
          atomicity_group: String.duplicate("g", 49)
        )

      {boundary, body} = Batch.to_multipart(batch, boundary: "b_edge")
      assert boundary == "b_edge"
      assert body =~ "Content-ID: op with spaces:1/2\r\n"
      assert body =~ "boundary=changeset_order_sync_"
      assert body =~ "boundary=changeset_order-sync.v1_"

      assert_raise ArgumentError, ~r/at most 49 bytes/, fn ->
        Batch.add_create(Batch.new(), "Contact", %{"Name" => "TooLong"},
          atomicity_group: String.duplicate("g", 50)
        )
      end

      assert {"b_empty", "--b_empty--\r\n"} = Batch.to_multipart(Batch.new(), boundary: "b_empty")

      mixed_resp =
        "--b_srv\r\n" <>
          "Content-Type: multipart/mixed; boundary=changeset_order_sync_abc123\r\n\r\n" <>
          "--changeset_order_sync_abc123\r\n" <>
          "Content-Type: application/http\r\n\r\n" <>
          "HTTP/1.1 204 No Content\r\n\r\n" <>
          "--changeset_order_sync_abc123--\r\n\r\n" <>
          "--b_srv\r\n" <>
          "Content-Type: multipart/mixed; boundary=changeset_order-sync.v1_xyz999\r\n\r\n" <>
          "--changeset_order-sync.v1_xyz999\r\n" <>
          "Content-Type: application/http\r\n\r\n" <>
          "HTTP/1.1 204 No Content\r\n\r\n" <>
          "--changeset_order-sync.v1_xyz999--\r\n--b_srv--\r\n"

      assert {:ok, [r1, r2]} = Batch.parse_multipart_response(mixed_resp, "b_srv")
      assert r1.atomicity_group == "order_sync"
      assert r2.atomicity_group == "order-sync.v1"

      # add_get forwards OData query options and facade batch_* helpers delegate cleanly
      q_batch =
        Creatio.batch_new()
        |> Creatio.batch_get("Contact", select: ["Id", "Name"], top: 5)
        |> Creatio.batch_get("Contact", 42, select: ["Name"])
        |> Creatio.batch_create("Account", %{"Name" => "Acme"})
        |> Creatio.batch_update("Account", 1, %{"Name" => "Acme 2"})
        |> Creatio.batch_delete("Account", 2)

      [g1, g2 | _] = Batch.requests(q_batch)
      assert g1["url"] =~ "Contact?"
      assert g1["url"] =~ "%24select=Id%2CName"
      assert g1["url"] =~ "%24top=5"
      assert g2["url"] =~ "Contact(42)?"
      assert g2["url"] =~ "%24select=Name"
    end

    test "returns error for top-level 200 JSON error payload and forwards :req_options in Batch.execute/3" do
      err_client =
        Creatio.Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              Req.Test.json(conn, %{"error" => %{"code" => "BadBatch", "message" => "boom"}})
            end
          ]
        )

      assert {:error, %Error{code: "BadBatch", message: "boom"}} =
               Batch.execute(err_client, Batch.new() |> Batch.add_get("Contact"))

      override_plug = fn conn ->
        Req.Test.json(conn, %{"responses" => [%{"id" => "req_1", "status" => 200, "body" => %{}}]})
      end

      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      assert {:ok, [%Response{status: 200}]} =
               Batch.execute(client, Batch.new() |> Batch.add_get("Contact"),
                 req_options: [plug: override_plug]
               )
    end
  end

  describe "batch wire-format, boundary, and atomicity regressions" do
    test "parse_multipart_response avoids boundary prefix collisions and strips UTF-8 BOM in JSON parts" do
      body =
        [
          "--batch_1",
          "Content-Type: application/http",
          "Content-Transfer-Encoding: binary",
          "Content-ID: 1",
          "",
          "HTTP/1.1 200 OK",
          "Content-Type: application/json",
          "",
          "\uFEFF{\"note\":\"contains --batch_10 inline\"}",
          "--batch_1--",
          "--batch_10 epilogue should be ignored"
        ]
        |> Enum.join("\r\n")

      assert {:ok, [%Creatio.Batch.Response{id: "1", status: 200, body: decoded}]} =
               Batch.parse_multipart_response(body, "batch_1")

      assert decoded == %{"note" => "contains --batch_10 inline"}
    end

    test "rejects whitespace or CRLF in batch URLs and rejects interleaved atomicity_group in builder and raw modes" do
      assert_raise ArgumentError, fn ->
        Batch.new() |> Batch.add_get("Contact?$filter=Name eq 'Jane'")
      end

      assert_raise ArgumentError, fn ->
        Batch.new()
        |> Batch.add_create("Contact", %{"Name" => "A"}, atomicity_group: "g1")
        |> Batch.add_create("Contact", %{"Name" => "B"}, atomicity_group: "g2")
        |> Batch.add_create("Contact", %{"Name" => "C"}, atomicity_group: "g1")
        |> Batch.to_payload()
      end

      raw_interleaved = [
        %{method: "POST", url: "Contact", body: %{"Name" => "A"}, atomicity_group: "g1"},
        %{method: "GET", url: "Contact"},
        %{method: "POST", url: "Contact", body: %{"Name" => "B"}, atomicity_group: "g1"}
      ]

      client = Creatio.Client.new(base_url: "https://mycreatio.com")

      assert_raise ArgumentError, fn ->
        Batch.execute(client, raw_interleaved, format: :multipart)
      end

      assert_raise ArgumentError, fn ->
        Batch.execute(client, raw_interleaved, format: :json)
      end
    end

    test "ignores atomicity_group on GET requests in JSON mode and preserves $1 Content-ID refs" do
      payload =
        Batch.new()
        |> Batch.add(:get, "Contact", id: "r1", atomicity_group: "g1")
        |> Batch.add_create("Account", %{"Name" => "Acme"}, id: "1", atomicity_group: "g1")
        |> Batch.add_update("$1", %{"Name" => "Acme2"}, atomicity_group: "g1")
        |> Batch.add_delete("$1", atomicity_group: "g1")
        |> Batch.add_get("$1/Contact_Account")
        |> Batch.to_payload()

      [get_req, create_req, upd_ref, del_ref, get_ref] = payload["requests"]
      refute Map.has_key?(get_req, "atomicityGroup")
      assert create_req["atomicityGroup"] == "g1"
      assert upd_ref["url"] == "$1"
      assert del_ref["url"] == "$1"
      assert get_ref["url"] == "$1/Contact_Account"
    end

    test "execute/3 with pre-encoded binary honors :format, :continue_on_error, and :return" do
      parent = self()

      plug = fn conn ->
        send(
          parent,
          {:raw_batch, Plug.Conn.get_req_header(conn, "content-type"),
           Plug.Conn.get_req_header(conn, "prefer")}
        )

        Req.Test.json(conn, %{"responses" => [%{"id" => "1", "status" => 200, "body" => %{}}]})
      end

      client = Creatio.Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      raw_json =
        Jason.encode!(%{"requests" => [%{"id" => "1", "method" => "GET", "url" => "Contact"}]})

      assert {:ok, [%Creatio.Batch.Response{id: "1", status: 200}]} =
               Batch.execute(client, raw_json,
                 format: :json,
                 continue_on_error: true,
                 return: :minimal
               )

      assert_receive {:raw_batch,
                      ["application/json; odata.metadata=minimal; IEEE754Compatible=true"],
                      [prefer]}

      assert prefer =~ "continue-on-error"
      assert prefer =~ "return=minimal"
    end
  end
end
