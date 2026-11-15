defmodule Creatio.RegressionsTest do
  use ExUnit.Case, async: true

  alias Creatio.{Auth, Batch, Client, DataService, Error, OData, OData3}
  alias Creatio.OData.Query

  describe "read-only error preservation through DataService and Batch" do
    test "DataService.batch_query, execute_query, and custom_service preserve status 403 and code ReadOnlyMode" do
      plug = fn conn ->
        flunk(
          "network plug should not be called for blocked read-only request #{conn.request_path}"
        )
      end

      client =
        Client.new(
          base_url: "https://test.creatio.com",
          read_only: true,
          req_options: [plug: plug]
        )

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.batch_query(client, %{"items" => []})

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.execute_query(client, "InsertQuery", %{"rootSchemaName" => "Contact"})

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.custom_service(client, "MySvc", "Mutate", %{"x" => 1})

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.custom_service(client, "MySvc", "DeleteIt", method: :delete)

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               Batch.execute(client, [%{method: "POST", url: "Contact", body: %{"Name" => "A"}}])
    end

    test "DataService allows read-only SelectQuery and GET/HEAD/OPTIONS custom_service" do
      plug = fn conn ->
        case conn.request_path do
          "/0/DataService/json/SyncReply/SelectQuery" ->
            Req.Test.json(conn, %{"rows" => [%{"Id" => "1"}], "success" => true})

          "/0/rest/MySvc/Ping" ->
            Req.Test.json(conn, %{"pong" => true})
        end
      end

      client =
        Client.new(
          base_url: "https://test.creatio.com",
          read_only: true,
          req_options: [plug: plug]
        )

      assert {:ok, %{"success" => true}} =
               DataService.execute_query(client, "SelectQuery", %{"rootSchemaName" => "Contact"})

      assert {:ok, %{"pong" => true}} =
               DataService.custom_service(client, "MySvc", "Ping", method: :get)
    end
  end

  describe "Auth regressions" do
    test "openid_configuration and login_oauth preserve plug from Client.from_req/2 and support token_url" do
      plug = fn conn ->
        assert conn.request_path == "/.well-known/openid-configuration" or
                 conn.request_path == "/connect/token"

        refute Enum.any?(conn.req_headers, fn {k, _} -> k in ["bpmcsrf", "cookie"] end)

        if conn.request_path == "/.well-known/openid-configuration" do
          Req.Test.json(conn, %{
            "issuer" => "https://id.test",
            "token_endpoint" => "https://id.test/connect/token"
          })
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = URI.decode_query(body)
          assert decoded["grant_type"] == "client_credentials"
          assert decoded["client_id"] == "cid"
          assert decoded["client_secret"] == "csecret"

          Req.Test.json(conn, %{
            "access_token" => "tok_from_plug",
            "token_type" => "Bearer",
            "expires_in" => 3600
          })
        end
      end

      req =
        Req.new(
          base_url: "https://crm.test",
          headers: [{"bpmcsrf", "stale"}, {"cookie", "stale=1"}],
          plug: plug
        )

      client = Client.from_req(req, identity_service_url: "https://id.test")

      assert {:ok, %{"issuer" => "https://id.test"}} = Auth.openid_configuration(client)

      token_client =
        Client.from_req(req,
          token_url: "https://id.test/connect/token",
          client_id: "cid",
          client_secret: "csecret"
        )

      assert {:ok, updated_client, %{"access_token" => "tok_from_plug"}} =
               Auth.login_oauth(token_client)

      assert updated_client.auth_mode == :bearer
      assert updated_client.auth_token == "tok_from_plug"
    end

    test "forms login preserves '+' in BPMCSRF and deduplicates repeated Set-Cookie names" do
      plug = fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.prepend_resp_headers([
          {"set-cookie", "BPMCSRF=old+val; Path=/"},
          {"set-cookie", "bpmcsrf=abc+123%2B==; Path=/"},
          {"set-cookie", ".ASPXAUTH=ticket1; Path=/"}
        ])
        |> Req.Test.json(%{"Code" => 0, "Exception" => nil})
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])
      assert {:ok, logged_in} = Auth.login_forms(client, "Supervisor", "pw")
      assert logged_in.bpmcsrf == "abc+123+=="
      assert logged_in.req.headers["bpmcsrf"] == ["abc+123+=="]
      # Only one bpmcsrf entry preserved in merged Cookie header
      assert length(Regex.scan(~r/bpmcsrf=/i, logged_in.cookie)) == 1
    end
  end

  describe "DataService.custom_service and custom_service! payload handling" do
    test "handles keyword payload, empty list [], GET string-key params, and DELETE json body" do
      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/0/rest/Svc/Kw"} ->
            Req.Test.json(conn, %{"method" => "POST", "body" => Jason.decode!(raw_body)})

          {"POST", "/0/rest/Svc/EmptyList"} ->
            Req.Test.json(conn, %{"method" => "POST", "body" => Jason.decode!(raw_body)})

          {"GET", "/0/rest/Svc/Fetch"} ->
            Req.Test.json(conn, %{"query" => URI.decode_query(conn.query_string)})

          {"DELETE", "/0/rest/Svc/Remove"} ->
            Req.Test.json(conn, %{"method" => "DELETE", "body" => Jason.decode!(raw_body)})
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert %{"body" => %{"foo" => "bar", "n" => 2}} =
               DataService.custom_service!(client, "Svc", "Kw", foo: "bar", n: 2)

      assert {:ok, %{"body" => []}} =
               DataService.custom_service(client, "Svc", "EmptyList", [])

      assert {:ok, %{"query" => %{"id" => "42", "extra" => "yes"}}} =
               DataService.custom_service(client, "Svc", "Fetch",
                 method: :get,
                 params: %{"id" => "42", :extra => "yes"}
               )

      assert {:ok, %{"method" => "DELETE", "body" => %{"ids" => ["1"]}}} =
               DataService.custom_service(client, "Svc", "Remove", %{"ids" => ["1"]},
                 method: :delete
               )
    end
  end

  describe "OData, OData3, and Facade regressions" do
    test "OData and OData3 return {:ok, nil} on 204 for get_navigation/get_field/get_field_value" do
      plug = fn conn ->
        Plug.Conn.send_resp(conn, 204, "")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, nil} = OData.get_navigation(client, "Contact", "id-1", "Owner")
      assert {:ok, nil} = OData.get_field(client, "Contact", "id-1", "Photo")
      assert {:ok, nil} = OData.get_field_value(client, "Contact", "id-1", "Photo")

      assert {:ok, nil} = OData3.get_navigation(client, "Contact", "id-1", "Owner")
      assert {:ok, nil} = OData3.get_field(client, "Contact", "id-1", "Photo")
      assert {:ok, nil} = OData3.get_field_value(client, "Contact", "id-1", "Photo")
    end

    test "OData.update_field wraps valid UTF-8 strings in JSON {\"value\": ...} by default" do
      plug = fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        ct = Plug.Conn.get_req_header(conn, "content-type") |> List.first()
        assert ct == "application/json; IEEE754Compatible=true"
        assert Jason.decode!(raw_body) == %{"value" => "Jane Doe"}
        Plug.Conn.send_resp(conn, 204, "")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])
      assert :ok = OData.update_field(client, "Contact", "id-1", "Name", "Jane Doe")
    end

    test "OData3.count with :query strategy and filter avoids double question mark" do
      plug = fn conn ->
        assert conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection"
        assert conn.query_string == "/$count&%24filter=Active+eq+true"
        Plug.Conn.send_resp(conn, 200, "17")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, 17} =
               OData3.count(client, "Contact", strategy: :query, filter: "Active eq true")
    end

    test "list/stream support map opts, count: false override, Query.top/opts.top, opts.skip override, and >20k page_size" do
      plug = fn conn ->
        q = URI.decode_query(conn.query_string)
        send(self(), {:odata_req, conn.request_path, q})

        case q do
          %{"$skip" => "5", "$top" => "2"} ->
            Req.Test.json(conn, %{"value" => [%{"Id" => 6}, %{"Id" => 7}]})

          %{"$skip" => "7", "$top" => "1"} ->
            Req.Test.json(conn, %{"value" => [%{"Id" => 8}]})

          %{"$top" => "25000", "$skip" => "0"} ->
            Req.Test.json(conn, %{
              "value" => [%{"Id" => 1}],
              "@odata.nextLink" => "/0/odata/Contact?$skip=20000"
            })

          %{"$top" => "25000", "$skip" => "1"} ->
            Req.Test.json(conn, %{"value" => [%{"Id" => 2}]})

          %{"$top" => "25000", "$skip" => "2"} ->
            Req.Test.json(conn, %{"value" => []})

          _ ->
            Req.Test.json(conn, %{"value" => [%{"Id" => 1}], "@odata.count" => 1})
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      # count: false overrides Query.count(true); map opts work
      q = Query.new("Contact") |> Query.count(true)
      assert {:ok, [%{"Id" => 1}]} = OData.list(client, q, %{count: false})

      # stream honors opts[:skip] over Query.skip and total top: 3 with page_size: 2
      q_skip = Query.new("Contact") |> Query.skip(99) |> Query.top(3)

      assert [%{"Id" => 6}, %{"Id" => 7}, %{"Id" => 8}] =
               OData.stream(client, q_skip, page_size: 2, skip: 5) |> Enum.to_list()

      # stream continues past 20,000 cap when page_size: 25_000 and stops cleanly on empty page
      assert [%{"Id" => 1}, %{"Id" => 2}] =
               OData.stream(client, "Contact", page_size: 25_000) |> Enum.to_list()
    end

    test "top-level Creatio facade accepts both client-first and entity-first arguments" do
      plug = fn conn ->
        if String.contains?(conn.request_path, "EntityDataService.svc") do
          Req.Test.json(conn, %{"d" => %{"results" => [%{"Id" => "o3"}]}})
        else
          Req.Test.json(conn, %{"value" => [%{"Id" => "o4"}]})
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, [%{"Id" => "o4"}]} = Creatio.list("Contact", client)
      assert [%{"Id" => "o4"}] = Creatio.list!("Contact", client)
      assert {:ok, [%{"Id" => "o4"}]} = Creatio.execute("Contact", client)
      assert [%{"Id" => "o4"}] = Creatio.execute!("Contact", client)
      assert [%{"Id" => "o4"}] = Creatio.stream("Contact", client) |> Enum.take(1)

      assert {:ok, [%{"Id" => "o3"}]} = Creatio.odata3_list("Contact", client)
      assert [%{"Id" => "o3"}] = Creatio.odata3_list!("Contact", client)
      assert [%{"Id" => "o3"}] = Creatio.odata3_stream("Contact", client) |> Enum.take(1)
      assert [%{"Id" => "o3"}] = Creatio.odata3_stream!("Contact", client) |> Enum.take(1)
    end
  end

  describe "Performance, Streaming, and Protocol Optimizations" do
    test "Batch supports O(1) large builds, iodata multipart, minimal metadata, and return=minimal" do
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

      # Multi-byte UTF-8 JSON body in multipart response parses cleanly with byte-level CRLF strip
      raw_utf8 =
        "--b_utf8\r\n" <>
          "Content-Type: application/http\r\n" <>
          "Content-ID: req_1\r\n\r\n" <>
          "HTTP/1.1 201 Created\r\n" <>
          "Content-Type: application/json; odata.metadata=minimal\r\n\r\n" <>
          ~s({"Id":"u1","Name":"José 🚀"}) <>
          "\r\n--b_utf8--\r\n"

      assert {:ok, [%Batch.Response{id: "req_1", status: 201, body: %{"Name" => "José 🚀"}}]} =
               Batch.parse_multipart_response(raw_utf8, "b_utf8")
    end

    test "OData and OData3 support cursor/keyset pagination without $skip" do
      id1 = "11111111-1111-1111-1111-111111111111"
      id2 = "22222222-2222-2222-2222-222222222222"
      id3 = "33333333-3333-3333-3333-333333333333"
      o3_filter_p1 = "(Active eq true) and (Id gt guid'#{id1}')"
      o3_filter_p2 = "(Active eq true) and (Id gt guid'#{id3}')"
      o4_filter_p2 = "(Active eq true) and (Id gt #{id2})"

      plug = fn conn ->
        q = URI.decode_query(conn.query_string)
        refute Map.has_key?(q, "$skip")
        assert q["$orderby"] == "Id asc"

        if String.contains?(conn.request_path, "EntityDataService.svc") do
          case q["$filter"] do
            ^o3_filter_p1 ->
              Req.Test.json(conn, %{"d" => %{"results" => [%{"Id" => id2}, %{"Id" => id3}]}})

            ^o3_filter_p2 ->
              Req.Test.json(conn, %{"d" => %{"results" => []}})
          end
        else
          case q["$filter"] do
            "Active eq true" ->
              Req.Test.json(conn, %{"value" => [%{"Id" => id1}, %{"Id" => id2}]})

            ^o4_filter_p2 ->
              Req.Test.json(conn, %{"value" => [%{"Id" => id3}]})
          end
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      q4 = Query.new("Contact") |> Query.filter_eq("Active", true)

      assert [%{"Id" => ^id1}, %{"Id" => ^id2}, %{"Id" => ^id3}] =
               OData.stream(client, q4, page_size: 2, cursor_field: "Id") |> Enum.to_list()

      assert [%{"Id" => ^id2}, %{"Id" => ^id3}] =
               OData3.stream(client, "Contact",
                 page_size: 2,
                 cursor_field: "Id",
                 after_cursor: id1,
                 filter: "Active eq true"
               )
               |> Enum.to_list()
    end

    test "get_field_value supports decode_body: false and into: streaming, and update_field streams Enumerables" do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "creatio_sdk_stream_test_#{System.unique_integer([:positive])}.bin"
        )

      on_exit(fn -> File.rm(tmp_path) end)

      plug = fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, ~s({"raw":"bytes"}))

          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert Plug.Conn.get_req_header(conn, "content-type") == [
                     "application/octet-stream; IEEE754Compatible=true"
                   ]

            assert body == "chunk1chunk2"
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      # decode_body: false returns raw binary instead of auto-decoding JSON
      assert {:ok, ~s({"raw":"bytes"})} = OData.get_field_value(client, "SysFile", "1", "Data")
      assert {:ok, ~s({"raw":"bytes"})} = OData3.get_field_value(client, "SysFile", "1", "Data")

      # into: File.stream! streams download directly to file
      assert {:ok, %File.Stream{}} =
               Creatio.get_field_value(client, "SysFile", "1", "Data",
                 into: File.stream!(tmp_path)
               )

      assert File.read!(tmp_path) == ~s({"raw":"bytes"})

      # Stream upload body does not hit Jason.encode!
      upload_stream = Stream.map(["chunk1", "chunk2"], & &1)
      assert :ok = OData.update_field(client, "SysFile", "1", "Data", upload_stream)
    end

    test "OData.create and update support return: :minimal and 204 odata-entityid" do
      plug = fn conn ->
        assert Plug.Conn.get_req_header(conn, "prefer") == ["return=minimal"]

        case conn.method do
          "POST" ->
            conn
            |> Plug.Conn.put_resp_header(
              "odata-entityid",
              "https://crm.test/0/odata/Contact(abc)"
            )
            |> Plug.Conn.send_resp(204, "")

          "PATCH" ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, %{"@odata.id" => "https://crm.test/0/odata/Contact(abc)"}} =
               OData.create(client, "Contact", %{"Name" => "Min"}, return: :minimal)

      assert :ok = OData.update(client, "Contact", "abc", %{"Name" => "Min2"}, return: :minimal)
    end

    test "Query flattens chained and_filter expressions and preserves OR precedence" do
      q =
        Query.new("Contact")
        |> Query.filter_eq("A", 1)
        |> Query.filter_eq("B", 2)
        |> Query.filter_eq("C", 3)

      assert Query.to_params(q)["$filter"] == "A eq 1 and B eq 2 and C eq 3"

      q_or_then_and =
        Query.new("Contact")
        |> Query.filter_eq("A", 1)
        |> Query.or_filter_eq("B", 2)
        |> Query.filter_eq("C", 3)

      assert Query.to_params(q_or_then_and)["$filter"] == "((A eq 1) or (B eq 2)) and C eq 3"
    end
  end
end
