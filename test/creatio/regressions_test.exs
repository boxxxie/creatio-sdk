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

      assert [{:ok, %{"Id" => 6}}, {:ok, %{"Id" => 7}}, {:ok, %{"Id" => 8}}] =
               OData.stream(client, q_skip, page_size: 2, skip: 5) |> Enum.to_list()

      assert [%{"Id" => 6}, %{"Id" => 7}, %{"Id" => 8}] =
               OData.stream!(client, q_skip, page_size: 2, skip: 5) |> Enum.to_list()

      # stream continues past 20,000 cap when page_size: 25_000 and stops cleanly on empty page
      assert [{:ok, %{"Id" => 1}}, {:ok, %{"Id" => 2}}] =
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
      assert [{:ok, %{"Id" => "o4"}}] = Creatio.stream("Contact", client) |> Enum.take(1)
      assert [%{"Id" => "o4"}] = Creatio.stream!("Contact", client) |> Enum.take(1)

      assert {:ok, [%{"Id" => "o3"}]} = Creatio.odata3_list("Contact", client)
      assert [%{"Id" => "o3"}] = Creatio.odata3_list!("Contact", client)

      assert [{:ok, %{"Id" => "o3"}}] =
               Creatio.odata3_stream("Contact", client) |> Enum.take(1)

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

      assert [{:ok, %{"Id" => ^id1}}, {:ok, %{"Id" => ^id2}}, {:ok, %{"Id" => ^id3}}] =
               OData.stream(client, q4, page_size: 2, cursor_field: "Id") |> Enum.to_list()

      assert [%{"Id" => ^id1}, %{"Id" => ^id2}, %{"Id" => ^id3}] =
               OData.stream!(client, q4, page_size: 2, cursor_field: "Id") |> Enum.to_list()

      assert [{:ok, %{"Id" => ^id2}}, {:ok, %{"Id" => ^id3}}] =
               OData3.stream(client, "Contact",
                 page_size: 2,
                 cursor_field: "Id",
                 after_cursor: id1,
                 filter: "Active eq true"
               )
               |> Enum.to_list()

      assert [%{"Id" => ^id2}, %{"Id" => ^id3}] =
               OData3.stream!(client, "Contact",
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

    test "get_field_value/5 forwards :headers, :req_options, and query params while keeping decode_body: false" do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "creatio_sdk_field_value_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      parent = self()

      plug = fn conn ->
        range_headers = Plug.Conn.get_req_header(conn, "range")

        send(parent, {
          :seen_field_value_req,
          conn.request_path,
          Plug.Conn.fetch_query_params(conn).query_params,
          Plug.Conn.get_req_header(conn, "x-trace"),
          range_headers
        })

        status = if range_headers == [], do: 200, else: 206

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, ~s({"raw":"bytes"}))
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])
      o4_path = Path.join(tmp_dir, "o4.bin")
      o3_path = Path.join(tmp_dir, "o3.bin")

      assert {:ok, %File.Stream{}} =
               Creatio.get_field_value(client, "SysFile", "1", "Data",
                 headers: [{"range", "bytes=0-4"}, {"x-trace", "o4-kw"}],
                 req_options: [decode_body: true, params: %{"from_req" => "yes"}],
                 params: %{"download" => "1"},
                 select: ["Name"],
                 into: File.stream!(o4_path)
               )

      assert File.read!(o4_path) == ~s({"raw":"bytes"})

      assert_receive {:seen_field_value_req, "/0/odata/SysFile(1)/Data/$value", o4_params,
                      ["o4-kw"], ["bytes=0-4"]}

      assert o4_params["$select"] == "Name"
      assert o4_params["download"] == "1"
      assert o4_params["from_req"] == "yes"

      # Trying to override decode_body: true via req_options still preserves decode_body: false
      assert {:ok, ~s({"raw":"bytes"})} =
               OData.get_field_value(client, "SysFile", "1", "Data", %{
                 headers: %{"x-trace" => "o4-map"},
                 req_options: [decode_body: true]
               })

      assert_receive {:seen_field_value_req, "/0/odata/SysFile(1)/Data/$value", _, ["o4-map"], []}

      assert {:ok, %File.Stream{}} =
               Creatio.odata3_get_field_value(client, "SysFile", "1", "Data", %{
                 headers: %{"range" => "bytes=0-3", "x-trace" => "o3-map"},
                 req_options: [decode_body: true, params: %{"from_req" => "o3"}],
                 select: ["Data"],
                 into: File.stream!(o3_path)
               })

      assert File.read!(o3_path) == ~s({"raw":"bytes"})

      assert_receive {:seen_field_value_req,
                      "/0/ServiceModel/EntityDataService.svc/SysFileCollection(guid'1')/Data/$value",
                      o3_params, ["o3-map"], ["bytes=0-3"]}

      assert o3_params["$select"] == "Data"
      assert o3_params["from_req"] == "o3"

      assert {:ok, ~s({"raw":"bytes"})} =
               OData3.get_field_value(client, "SysFile", "1", "Data",
                 headers: [{"x-trace", "o3-kw"}],
                 req_options: [decode_body: true]
               )

      assert_receive {:seen_field_value_req,
                      "/0/ServiceModel/EntityDataService.svc/SysFileCollection(guid'1')/Data/$value",
                      _, ["o3-kw"], []}
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

      assert {:ok,
              %{
                "@odata.id" => "https://crm.test/0/odata/Contact(abc)",
                "Id" => "abc"
              }} =
               OData.create(client, "Contact", %{"Name" => "Min"}, return: :minimal)

      assert :ok = OData.update(client, "Contact", "abc", %{"Name" => "Min2"}, return: :minimal)
    end

    test "extracts Id from mixed-case OData-EntityId or Location header on 204 return=minimal" do
      guid = "12345678-1234-1234-1234-123456789abc"
      entity_uri = "https://crm.test/0/odata/Contact({#{guid}})"

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", entity_uri)
        |> Plug.Conn.send_resp(204, "")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, %{"@odata.id" => ^entity_uri, "Id" => ^guid}} =
               OData.create(client, "Contact", %{"Name" => "Loc"}, return: :minimal)
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

  describe "IIS text/html JSON normalization and WAF HTML interstitial protection" do
    test "decodes IIS text/html JSON responses across OData, OData3, Auth, and DataService" do
      plug = fn conn ->
        body =
          case conn.request_path do
            "/0/odata/Contact" when conn.method == "POST" ->
              Jason.encode!(%{"Id" => "c-1", "Name" => "Created"})

            "/0/odata/Contact" ->
              Jason.encode!(%{"value" => [%{"Id" => "c-1"}]})

            "/0/odata/Contact(c-1)" ->
              Jason.encode!(%{"Id" => "c-1", "Name" => "Alice"})

            "/0/odata/Contact(c-1)/Account" ->
              Jason.encode!(%{"Id" => "a-1", "Name" => "Acme"})

            "/0/odata/Contact(c-1)/Name" ->
              Jason.encode!(%{"value" => "Alice"})

            "/0/ServiceModel/EntityDataService.svc/ContactCollection" ->
              Jason.encode!(%{"d" => %{"results" => [%{"Id" => "o3-1"}]}})

            "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'o3-1')" ->
              Jason.encode!(%{"d" => %{"Id" => "o3-1"}})

            "/0/api/OAuthHealthCheck" ->
              Jason.encode!(%{"HasProblem" => false})

            "/.well-known/openid-configuration" ->
              Jason.encode!(%{"issuer" => "https://id.test"})

            "/0/DataService/json/SyncReply/SelectQuery" ->
              Jason.encode!(%{"success" => true, "rows" => [%{"Id" => "ds-1"}]})

            "/0/odata/$batch" ->
              Jason.encode!(%{
                "responses" => [%{"id" => "req_1", "status" => 200, "body" => %{}}]
              })
          end

        status =
          if conn.method == "POST" and conn.request_path == "/0/odata/Contact", do: 201, else: 200

        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(status, "\uFEFF" <> body)
      end

      client =
        Client.new(
          base_url: "https://crm.test",
          identity_service_url: "https://crm.test",
          req_options: [plug: plug]
        )

      assert {:ok, %{"Id" => "c-1"}} = OData.create(client, "Contact", %{"Name" => "Created"})
      assert {:ok, [%{"Id" => "c-1"}]} = OData.list(client, "Contact")
      assert {:ok, %{"Id" => "c-1"}} = OData.get(client, "Contact", "c-1")
      assert {:ok, %{"Id" => "a-1"}} = OData.get_navigation(client, "Contact", "c-1", "Account")
      assert {:ok, "Alice"} = OData.get_field(client, "Contact", "c-1", "Name")
      assert {:ok, [%{"Id" => "o3-1"}]} = OData3.list(client, "Contact")
      assert {:ok, %{"Id" => "o3-1"}} = OData3.get(client, "Contact", "o3-1")
      assert {:ok, %{"HasProblem" => false}} = Auth.oauth_health_check(client)
      assert {:ok, %{"issuer" => "https://id.test"}} = Auth.openid_configuration(client)

      assert {:ok, %{"success" => true}} =
               DataService.select_query(client, %{"rootSchemaName" => "Contact"})

      batch = Batch.new() |> Batch.add_get("Contact")
      assert {:ok, [%Batch.Response{id: "req_1", status: 200}]} = Batch.execute(client, batch)
    end

    test "returns {:error, %Error{}} when HTTP 200/201 returns an HTML WAF/login interstitial" do
      incapsula_html = """
      <html style="height:100%"><head><meta name="ROBOTS" content="NOINDEX, NOFOLLOW"></head>
      <body style="margin:0"><iframe id="main-iframe" src="/_Incapsula_Resource?SWUDNSAI=31"></iframe></body></html>
      """

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, incapsula_html)
      end

      client =
        Client.new(
          base_url: "https://crm.test",
          identity_service_url: "https://crm.test",
          client_id: "cid",
          client_secret: "csec",
          req_options: [plug: plug]
        )

      assert {:error, %Error{status: 200}} = OData.list(client, "Contact")
      assert {:error, %Error{status: 200}} = OData.get(client, "Contact", "id-1")

      assert {:error, %Error{status: 200}} =
               OData.get_navigation(client, "Contact", "id-1", "Account")

      assert {:error, %Error{status: 200}} = OData.get_field(client, "Contact", "id-1", "Name")
      assert {:error, %Error{status: 200}} = OData.create(client, "Contact", %{"Name" => "X"})

      assert {:error, %Error{status: 200}} =
               OData.update(client, "Contact", "id-1", %{"Name" => "Y"})

      assert {:error, %Error{status: 200}} = OData3.list(client, "Contact")
      assert {:error, %Error{status: 200}} = OData3.get(client, "Contact", "id-1")

      assert {:error, %Error{status: 200}} =
               OData3.get_navigation(client, "Contact", "id-1", "Account")

      assert {:error, %Error{status: 200}} = OData3.get_field(client, "Contact", "id-1", "Name")
      assert {:error, %Error{status: 200}} = OData3.create(client, "Contact", %{"Name" => "X"})

      assert {:error, %Error{status: 200}} =
               OData3.update(client, "Contact", "id-1", %{"Name" => "Y"})

      assert {:error, %Error{status: 200}} = Auth.login_oauth(client)
      assert {:error, %Error{status: 200}} = Auth.oauth_health_check(client)
      assert {:error, %Error{status: 200}} = Auth.openid_configuration(client)

      assert {:error, %Error{status: 200}} =
               Auth.openid_configuration("https://crm.test/.well-known/openid-configuration",
                 req_options: [plug: plug]
               )

      assert {:error, %Error{status: 200}} =
               DataService.select_query(client, %{"rootSchemaName" => "Contact"})

      assert {:error, %Error{status: 200}} =
               Batch.execute(client, Batch.new() |> Batch.add_get("Contact"))
    end

    test "rejects HTTP 200 and 201 HTML/WAF interstitials across delete, update_field, delete_field, and OData3.delete" do
      waf_html =
        "<html><body><iframe src=\"/_Incapsula_Resource?SWKMTFSR=1\"></iframe></body></html>"

      id = "00000000-0000-0000-0000-000000000001"

      client_200 =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, waf_html)
            end
          ]
        )

      assert {:error, %Error{status: 200}} = OData.delete(client_200, "Contact", id)

      assert {:error, %Error{status: 200}} =
               OData.update_field(client_200, "Contact", id, "Name", "X")

      assert {:error, %Error{status: 200}} = OData.delete_field(client_200, "Contact", id, "Name")
      assert {:error, %Error{status: 200}} = OData3.delete(client_200, "Contact", id)

      client_201 =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(201, waf_html)
            end
          ]
        )

      assert {:error, %Error{status: 201}} =
               OData.update_field(client_201, "Contact", id, "Name", "X")
    end

    test "rejects corrupt JSON and plain-text 200 responses while allowing IIS text/html Healthy on OAuthHealthCheck" do
      id = "00000000-0000-0000-0000-000000000002"

      for {ct, body} <- [
            {"application/json", "{broken"},
            {"text/plain", "{broken"},
            {"text/plain", "Gateway Timeout"}
          ] do
        client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                conn
                |> Plug.Conn.put_resp_content_type(ct)
                |> Plug.Conn.send_resp(200, body)
              end
            ]
          )

        expected_status = if ct == "application/json", do: nil, else: 200

        assert {:error, %Error{status: ^expected_status}} =
                 DataService.execute_query(client, :select, %{})

        assert {:error, %Error{status: ^expected_status}} =
                 OData.update(client, "Contact", id, %{"Name" => "X"}, return: :representation)

        assert {:error, %Error{status: ^expected_status}} =
                 OData3.update(client, "Contact", id, %{"Name" => "X"}, return: :representation)

        assert {:error, %Error{status: ^expected_status}} =
                 OData.get_field(client, "Contact", id, "Name")

        assert {:error, %Error{status: ^expected_status}} =
                 OData3.get_field(client, "Contact", id, "Name")
      end

      health_ok_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_content_type("text/html")
              |> Plug.Conn.send_resp(200, "Healthy")
            end
          ]
        )

      assert {:ok, "Healthy"} = Auth.oauth_health_check(health_ok_client)

      for {ct, bad_body} <- [
            {"text/html", "<html><body>WAF</body></html>"},
            {"text/html", "{broken"},
            {"application/json", "{broken"}
          ] do
        bad_health_client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                conn
                |> Plug.Conn.put_resp_content_type(ct)
                |> Plug.Conn.send_resp(200, bad_body)
              end
            ]
          )

        expected_status = if ct == "application/json", do: nil, else: 200

        assert {:error, %Error{status: ^expected_status}} =
                 Auth.oauth_health_check(bad_health_client)
      end
    end

    test "CreatioServerDriver simulates IIS text/html JSON and 204 OData-EntityId headers" do
      alias Creatio.TestDrivers.CreatioServerDriver, as: Server

      ctx =
        %{}
        |> Server.ensure_server()
        |> Server.stub_odata_list("Contact",
          content_type: "text/html",
          records: [%{"Id" => "d-1"}]
        )
        |> Server.stub_odata_create("Contact",
          status: 204,
          odata_entityid: "https://mycreatio.com/0/odata/Contact(d-2)"
        )

      client = Server.client(ctx)
      assert {:ok, [%{"Id" => "d-1"}]} = OData.list(client, "Contact")

      assert {:ok, %{"@odata.id" => "https://mycreatio.com/0/odata/Contact(d-2)", "Id" => "d-2"}} =
               OData.create(client, "Contact", %{"Name" => "Driver"})
    end

    test "get_field_value into: Collectable gates disk writes to 2xx and preserves non-2xx errors" do
      tmp_dir = System.tmp_dir!()

      error_path =
        Path.join(tmp_dir, "creatio-err-#{System.unique_integer([:positive])}.bin")

      empty_path =
        Path.join(tmp_dir, "creatio-empty-#{System.unique_integer([:positive])}.bin")

      ok_path =
        Path.join(tmp_dir, "creatio-ok-#{System.unique_integer([:positive])}.bin")

      on_exit(fn ->
        File.rm(error_path)
        File.rm(empty_path)
        File.rm(ok_path)
      end)

      plug = fn conn ->
        case conn.request_path do
          "/0/odata/SysFile(err-404)/Data/$value" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              404,
              Jason.encode!(%{"error" => %{"message" => "File missing"}})
            )

          "/0/ServiceModel/EntityDataService.svc/AccountFileCollection(guid'err-500')/Data/$value" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              500,
              Jason.encode!(%{"error" => %{"message" => "Server boom"}})
            )

          "/0/odata/SysFile(empty-204)/Data/$value" ->
            Plug.Conn.send_resp(conn, 204, "")

          "/0/odata/SysFile(ok-200)/Data/$value" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/octet-stream")
            |> Plug.Conn.send_resp(200, "binary-payload-bytes")
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:error, %Error{status: 404, message: "File missing"}} =
               OData.get_field_value(client, "SysFile", "err-404", "Data",
                 into: File.stream!(error_path)
               )

      refute File.exists?(error_path)

      assert {:error, %Error{status: 500, message: "Server boom"}} =
               OData3.get_field_value(client, "AccountFile", "err-500", "Data",
                 into: File.stream!(error_path)
               )

      refute File.exists?(error_path)

      assert {:ok, nil} =
               OData.get_field_value(client, "SysFile", "empty-204", "Data",
                 into: File.stream!(empty_path)
               )

      refute File.exists?(empty_path)

      assert {:ok, %File.Stream{}} =
               OData.get_field_value(client, "SysFile", "ok-200", "Data",
                 into: File.stream!(ok_path)
               )

      assert File.read!(ok_path) == "binary-payload-bytes"
    end

    test "OData.count, OData3.count, and DataService.custom_service normalize IIS text/html JSON and reject WAF HTML" do
      iis_plug = fn conn ->
        cond do
          conn.request_path == "/0/odata/Contact" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(
              200,
              "\uFEFF" <> Jason.encode!(%{"@odata.count" => 42, "value" => []})
            )

          conn.request_path == "/0/odata/Contact/$count" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "\uFEFF42")

          conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "\uFEFF19")

          conn.request_path == "/0/rest/MySvc/Info" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "\uFEFF" <> Jason.encode!(%{"ok" => true}))
        end
      end

      iis_client = Client.new(base_url: "https://crm.test", req_options: [plug: iis_plug])

      assert {:ok, 42} = OData.count(iis_client, "Contact", strategy: :top_zero)
      assert {:ok, 42} = OData.count(iis_client, "Contact", strategy: :path)
      assert {:ok, 19} = OData3.count(iis_client, "Contact")

      assert {:ok, %{"ok" => true}} =
               DataService.custom_service(iis_client, "MySvc", "Info", method: :get)

      waf_html = "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"

      waf_plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, waf_html)
      end

      waf_client = Client.new(base_url: "https://crm.test", req_options: [plug: waf_plug])

      assert {:error, %Error{status: 200}} =
               OData.count(waf_client, "Contact", strategy: :top_zero)

      assert {:error, %Error{status: 200}} = OData.count(waf_client, "Contact", strategy: :path)
      assert {:error, %Error{status: 200}} = OData3.count(waf_client, "Contact")

      assert {:error, %Error{status: 200}} =
               DataService.custom_service(waf_client, "MySvc", "Info", method: :get)
    end

    test "OData.create return: :minimal avoids mis-extracting Id from composite keys and stream/list validate entities eagerly" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "odata-entityid",
          "https://crm.test/0/odata/OrderItem(OrderId=1,ItemId=2)"
        )
        |> Plug.Conn.send_resp(204, "")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, created} =
               OData.create(client, "OrderItem", %{"Name" => "X"}, return: :minimal)

      assert created["@odata.id"] == "https://crm.test/0/odata/OrderItem(OrderId=1,ItemId=2)"
      refute Map.has_key?(created, "Id")

      for empty_target <- ["", Query.new("")] do
        assert_raise ArgumentError, ~r/empty/, fn -> OData.list(client, empty_target) end
        assert_raise ArgumentError, ~r/empty/, fn -> OData.stream(client, empty_target) end
        assert_raise ArgumentError, ~r/empty/, fn -> OData.stream!(client, empty_target) end

        assert_raise ArgumentError, ~r/empty/, fn ->
          OData.stream(client, empty_target, max_records: 0)
        end

        assert_raise ArgumentError, ~r/empty/, fn -> OData3.list(client, empty_target) end
        assert_raise ArgumentError, ~r/empty/, fn -> OData3.stream(client, empty_target) end
        assert_raise ArgumentError, ~r/empty/, fn -> OData3.stream!(client, empty_target) end

        assert_raise ArgumentError, ~r/empty/, fn ->
          OData3.stream(client, empty_target, max_records: 0)
        end
      end
    end

    test "rejects nil, whitespace, and invalid non-string/Query targets without network requests" do
      id = "00000000-0000-0000-0000-000000000003"

      client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              flunk("should not issue HTTP request for invalid entity: #{conn.request_path}")
            end
          ]
        )

      for bad_target <- [nil, "   ", Query.new(nil), Query.new("   "), :Contact] do
        assert_raise ArgumentError, fn -> OData.list(client, bad_target) end
        assert_raise ArgumentError, fn -> OData.count(client, bad_target) end
        assert_raise ArgumentError, fn -> OData.stream(client, bad_target) end
        assert_raise ArgumentError, fn -> OData3.list(client, bad_target) end
        assert_raise ArgumentError, fn -> OData3.count(client, bad_target) end
        assert_raise ArgumentError, fn -> OData3.stream(client, bad_target) end
      end

      for bad_name <- [nil, "", "   ", :Contact] do
        assert_raise ArgumentError, fn -> OData.get(client, bad_name, id) end
        assert_raise ArgumentError, fn -> OData.create(client, bad_name, %{"Name" => "X"}) end
        assert_raise ArgumentError, fn -> OData.update(client, bad_name, id, %{"Name" => "X"}) end
        assert_raise ArgumentError, fn -> OData.delete(client, bad_name, id) end
        assert_raise ArgumentError, fn -> OData.get_field(client, bad_name, id, "Name") end
        assert_raise ArgumentError, fn -> OData.get_field_value(client, bad_name, id, "Photo") end

        assert_raise ArgumentError, fn ->
          OData.update_field(client, bad_name, id, "Name", "X")
        end

        assert_raise ArgumentError, fn -> OData.delete_field(client, bad_name, id, "Name") end

        assert_raise ArgumentError, fn ->
          OData.get_navigation(client, bad_name, id, "Account")
        end

        assert_raise ArgumentError, fn -> OData3.get(client, bad_name, id) end
        assert_raise ArgumentError, fn -> OData3.create(client, bad_name, %{"Name" => "X"}) end

        assert_raise ArgumentError, fn ->
          OData3.update(client, bad_name, id, %{"Name" => "X"})
        end

        assert_raise ArgumentError, fn -> OData3.delete(client, bad_name, id) end
        assert_raise ArgumentError, fn -> OData3.get_field(client, bad_name, id, "Name") end

        assert_raise ArgumentError, fn ->
          OData3.get_field_value(client, bad_name, id, "Photo")
        end
      end
    end

    test "OData3.count/3 supports string, __count, count, IIS text/html, forwards req_options, and preserves parse error metadata" do
      cases = [
        {"application/json", %{"d" => "42"}, 42},
        {"application/json", %{"d" => %{"__count" => "15"}}, 15},
        {"application/json", %{"d" => %{"count" => 7}}, 7},
        {"text/plain", "42", 42},
        {"text/html", "123", 123}
      ]

      for {ct, payload, expected} <- cases do
        client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                assert Plug.Conn.get_req_header(conn, "x-count-check") == ["1"]

                if ct == "application/json" do
                  Req.Test.json(conn, payload)
                else
                  conn
                  |> Plug.Conn.put_resp_content_type(ct)
                  |> Plug.Conn.send_resp(200, payload)
                end
              end
            ]
          )

        assert {:ok, ^expected} =
                 OData3.count(client, "Contact", req_options: [headers: [{"x-count-check", "1"}]])
      end

      bad_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn -> Req.Test.json(conn, %{"d" => "not-a-number"}) end
          ]
        )

      assert {:error, %Error{status: 200, response: %Req.Response{status: 200}}} =
               OData3.count(bad_client, "Contact")
    end

    test "Auth validates URLs for OAuth/OIDC discovery and strips stale headers in login_forms/4" do
      unconfigured =
        Client.new(
          base_url: "",
          identity_service_url: nil,
          client_id: "cid",
          client_secret: "sec"
        )

      assert {:error, %Error{message: msg1}} = Auth.openid_configuration(unconfigured)
      assert msg1 =~ "URL"

      assert {:error, %Error{message: msg2}} =
               Auth.login_oauth(unconfigured, identity_service_url: "/relative-only")

      assert msg2 =~ "URL"

      stale_client =
        Client.new(
          base_url: "https://test.creatio.com",
          auth_token: "stale-bearer",
          cookie: "stale-cookie",
          bpmcsrf: "stale-csrf",
          req_options: [
            plug: fn conn ->
              assert Plug.Conn.get_req_header(conn, "authorization") == []
              assert Plug.Conn.get_req_header(conn, "cookie") == []
              assert Plug.Conn.get_req_header(conn, "bpmcsrf") == []

              conn
              |> Plug.Conn.put_resp_cookie("BPMCSRF", "fresh-csrf", path: "/")
              |> Plug.Conn.put_resp_cookie(".ASPXAUTH", "fresh-auth", path: "/")
              |> Req.Test.json(%{"Code" => 0})
            end
          ]
        )

      assert {:ok, authed} = Auth.login_forms(stale_client, "user", "pass")
      assert authed.bpmcsrf == "fresh-csrf"
    end

    test "keyset stream auto-selects cursor_field, detects missing cursor, prioritizes opts[:filter], and tie-breaks duplicates" do
      ts = "2026-01-01T00:00:00Z"

      plug = fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        params = conn.query_params
        select_fields = String.split(params["$select"] || "", ",")

        assert "ModifiedOn" in select_fields
        assert "Id" in select_fields
        assert params["$orderby"] == "ModifiedOn asc, Id asc"
        assert params["$filter"] =~ "Active eq true"
        refute params["$filter"] =~ "Active eq false"

        records =
          if String.contains?(params["$filter"], "Id gt") do
            [%{"Id" => "id-3", "Name" => "C", "ModifiedOn" => ts}]
          else
            [
              %{"Id" => "id-1", "Name" => "A", "ModifiedOn" => ts},
              %{"Id" => "id-2", "Name" => "B", "ModifiedOn" => ts}
            ]
          end

        Req.Test.json(conn, %{"value" => records})
      end

      client = Client.new(base_url: "https://test.creatio.com", req_options: [plug: plug])

      query =
        Query.new("Contact")
        |> Query.select(["Name"])
        |> Query.filter_eq("Active", false)

      items =
        client
        |> OData.stream(query, cursor_field: "ModifiedOn", page_size: 2, filter: "Active eq true")
        |> Enum.to_list()

      assert Enum.map(items, fn {:ok, record} -> record["Id"] end) == ["id-1", "id-2", "id-3"]

      missing_cursor_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              Req.Test.json(conn, %{"value" => [%{"Id" => "id-1", "Name" => "NoCursor"}]})
            end
          ]
        )

      assert [{:ok, %{"Id" => "id-1"}}, {:error, %Error{message: msg}}] =
               missing_cursor_client
               |> OData.stream("Contact", cursor_field: "ModifiedOn", page_size: 1)
               |> Enum.to_list()

      assert msg =~ "ModifiedOn"
    end
  end

  describe "10 additional edge-case, pagination, and security regressions" do
    test "issue 1: streams follow @odata.nextLink and __next under low server caps without wasted page fetches or nil loops" do
      {:ok, req_count} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(req_count), do: Agent.stop(req_count) end)

      # Server caps page 1 to 2 rows (below requested page_size: 5) and returns @odata.nextLink
      next_link_plug = fn conn ->
        attempt = Agent.get_and_update(req_count, fn n -> {n + 1, n + 1} end)
        conn = Plug.Conn.fetch_query_params(conn)

        case attempt do
          1 ->
            assert conn.request_path == "/0/odata/Contact"

            Req.Test.json(conn, %{
              "value" => [%{"Id" => "1"}, %{"Id" => "2"}],
              "@odata.nextLink" =>
                "https://test.creatio.com/0/odata/Contact?$skiptoken=page2&$top=5"
            })

          2 ->
            assert conn.query_params["$skiptoken"] == "page2"

            Req.Test.json(conn, %{
              "value" => [%{"Id" => "3"}],
              "@odata.nextLink" => nil
            })

          _ ->
            flunk("unexpected extra request attempt #{attempt}")
        end
      end

      client =
        Client.new(base_url: "https://test.creatio.com", req_options: [plug: next_link_plug])

      records =
        Creatio.stream!(client, "Contact", page_size: 5)
        |> Enum.to_list()

      assert Enum.map(records, & &1["Id"]) == ["1", "2", "3"]
      assert Agent.get(req_count, & &1) == 2

      # OData3 __next pagination under low server cap
      Agent.update(req_count, fn _ -> 0 end)

      o3_plug = fn conn ->
        attempt = Agent.get_and_update(req_count, fn n -> {n + 1, n + 1} end)
        conn = Plug.Conn.fetch_query_params(conn)

        case attempt do
          1 ->
            Req.Test.json(conn, %{
              "d" => %{
                "results" => [%{"Id" => "o3-1"}],
                "__next" =>
                  "https://test.creatio.com/0/ServiceModel/EntityDataService.svc/ContactCollection?$skiptoken=next"
              }
            })

          2 ->
            assert conn.query_params["$skiptoken"] == "next"
            Req.Test.json(conn, %{"d" => %{"results" => [%{"Id" => "o3-2"}], "__next" => ""}})

          _ ->
            flunk("unexpected extra OData3 request #{attempt}")
        end
      end

      o3_client = Client.new(base_url: "https://test.creatio.com", req_options: [plug: o3_plug])

      assert Enum.map(OData3.stream!(o3_client, "Contact", page_size: 10), & &1["Id"]) == [
               "o3-1",
               "o3-2"
             ]

      # page_size > 20_000 on small table should not trigger a wasted extra HTTP call
      Agent.update(req_count, fn _ -> 0 end)

      single_page_plug = fn conn ->
        Agent.update(req_count, &(&1 + 1))
        Req.Test.json(conn, %{"value" => [%{"Id" => "only-1"}, %{"Id" => "only-2"}]})
      end

      sp_client =
        Client.new(base_url: "https://test.creatio.com", req_options: [plug: single_page_plug])

      assert [%{"Id" => "only-1"}, %{"Id" => "only-2"}] =
               OData.stream!(sp_client, "Contact", page_size: 25_000) |> Enum.to_list()

      assert Agent.get(req_count, & &1) == 1
    end

    test "issue 2: supports 206 Partial Content Range downloads and never writes WAF HTML to into: File.stream!" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "creatio_waf_gate_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      range_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              conn
              |> Plug.Conn.put_resp_header("content-range", "bytes 0-4/100")
              |> Plug.Conn.put_resp_content_type("application/octet-stream")
              |> Plug.Conn.send_resp(206, "hello")
            end
          ]
        )

      assert {:ok, "hello"} =
               OData.get_field_value(range_client, "SysFile", "1", "Data",
                 headers: [{"range", "bytes=0-4"}]
               )

      assert {:ok, "hello"} =
               OData3.get_field_value(range_client, "SysFile", "1", "Data",
                 headers: [{"range", "bytes=0-4"}]
               )

      # Both small (<1KB) and large (>1KB) HTTP 200 WAF HTML responses must fail without writing to disk
      for {label, body} <- [
            {"small", "<html><iframe src=\"/_Incapsula_Resource\"></iframe></html>"},
            {"large",
             "<html><body>" <> String.duplicate("waf-challenge ", 150) <> "</body></html>"}
          ] do
        waf_client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                conn
                |> Plug.Conn.put_resp_content_type("text/html")
                |> Plug.Conn.send_resp(200, body)
              end
            ]
          )

        dest = Path.join(tmp_dir, "waf_#{label}.bin")

        assert {:error, %Error{status: 200}} =
                 OData.get_field_value(waf_client, "SysFile", "1", "Data",
                   into: File.stream!(dest)
                 )

        refute File.exists?(dest)
      end
    end

    test "issue 3: blocks path traversal, DataService read_only :url bypass, and Batch header injection" do
      ro_client = Client.new(base_url: "https://test.creatio.com", read_only: true)

      for bad_id <- ["1)/../../rest/CustomService/Trigger?x=(", "../etc", "a/b", "1?x=2"] do
        assert_raise ArgumentError, fn -> OData.get(ro_client, "Contact", bad_id) end
        assert_raise ArgumentError, fn -> OData.delete(ro_client, "Contact", bad_id) end
        assert_raise ArgumentError, fn -> OData3.get(ro_client, "Contact", bad_id) end
        assert_raise ArgumentError, fn -> Batch.add_delete(Batch.new(), "Contact", bad_id) end
      end

      assert_raise ArgumentError, fn -> OData.get(ro_client, "Contact/../rest", "1") end

      assert_raise ArgumentError, fn ->
        OData.get_field(ro_client, "Contact", "1", "Name/../$value")
      end

      assert_raise ArgumentError, fn ->
        OData.get_navigation(ro_client, "Contact", "1", "Account/../Secret")
      end

      assert_raise ArgumentError, fn ->
        DataService.custom_service(ro_client, "Svc/..", "Op", %{})
      end

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.select_query(ro_client, %{},
                 url: "/0/DataService/json/SyncReply/DeleteQuery"
               )

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               DataService.execute_query(ro_client, "SelectQuery", %{},
                 url: "/0/DataService/json/SyncReply/InsertQuery"
               )

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               Req.get(ro_client.req, url: "/0/odata/Contact/../../rest/Trigger")
               |> then(fn
                 {:ok, _} -> :ok
                 {:error, exc} -> Error.wrap_error(exc)
               end)

      assert_raise ArgumentError, fn ->
        Batch.execute(Client.new(base_url: "https://test.creatio.com"), "raw",
          format: :multipart,
          boundary: "bad;\r\nX-Injected: yes"
        )
      end
    end

    test "issue 4 & issue 5: supports string maps in stream/3, Query.t()/maps in count/3, and strict non-negative integer parsing" do
      plug = fn conn ->
        case conn.request_path do
          "/0/odata/Contact/$count" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, "42")

          "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, "7")

          "/0/odata/Contact" ->
            conn = Plug.Conn.fetch_query_params(conn)

            if conn.query_params["$top"] == "0" do
              Req.Test.json(conn, %{"@odata.count" => 9, "value" => []})
            else
              Req.Test.json(conn, %{"value" => [%{"Id" => "1"}, %{"Id" => "2"}]})
            end

          "/0/ServiceModel/EntityDataService.svc/ContactCollection" ->
            resp_count =
              if String.starts_with?(conn.query_string, "/$count"), do: "11", else: "0"

            conn
            |> Plug.Conn.put_resp_content_type("text/plain")
            |> Plug.Conn.send_resp(200, resp_count)
        end
      end

      client = Client.new(base_url: "https://test.creatio.com", req_options: [plug: plug])

      assert [%{"Id" => "1"}, %{"Id" => "2"}] =
               Creatio.stream!(client, "Contact", %{"page_size" => 2, "top" => 2})
               |> Enum.to_list()

      q = Query.new("Contact") |> Query.filter_eq("Active", true)
      assert {:ok, 42} = OData.count(client, q, %{"strategy" => :path})
      assert {:ok, 42} = Creatio.count(q, client, %{strategy: :path})
      assert {:ok, 9} = OData.count(q, client, strategy: :top_zero)
      assert {:ok, 7} = OData3.count(client, q, %{"strategy" => :path})
      assert {:ok, 11} = Creatio.odata3_count(q, client, strategy: :query)

      for bad_body <- ["503 Service Unavailable", "404 Not Found", "2026-11-15 Error", "-1"] do
        bad_client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                conn
                |> Plug.Conn.put_resp_content_type("text/plain")
                |> Plug.Conn.send_resp(200, bad_body)
              end
            ]
          )

        assert {:error, %Error{status: 200}} = OData.count(bad_client, "Contact")
        assert {:error, %Error{status: 200}} = OData3.count(bad_client, "Contact")
      end
    end

    test "issue 7: Auth rejects blank access_token, normalizes identity URL, drops transient secret, and forwards req_options" do
      for bad_token <- [nil, "", "   "] do
        bad_client =
          Client.new(
            base_url: "https://test.creatio.com",
            identity_service_url: "https://id.creatio.com/0///",
            client_id: "cid",
            req_options: [
              plug: fn conn ->
                assert conn.request_path == "/0/connect/token"
                Req.Test.json(conn, %{"access_token" => bad_token})
              end
            ]
          )

        assert {:error, %Error{code: "OAuthMissingToken", status: 200}} =
                 Auth.login_oauth(bad_client, client_secret: "transient-sec")
      end

      ok_client =
        Client.new(
          base_url: "https://test.creatio.com",
          client_id: "cid",
          req_options: [
            plug: fn conn ->
              assert conn.request_path == "/0/connect/token"
              Req.Test.json(conn, %{"access_token" => "valid-jwt", "expires_in" => 3600})
            end
          ]
        )

      assert {:ok, authed, _token} =
               Auth.login_oauth(ok_client,
                 identity_service_url: " https://id.creatio.com/0// ",
                 client_secret: "transient-sec"
               )

      assert authed.identity_service_url == "https://id.creatio.com/0"
      assert authed.client_secret == nil
      assert authed.auth_token == "valid-jwt"

      forms_req = Req.new()

      forms_plug = fn conn ->
        assert conn.host == "forms.example.com"

        conn
        |> Plug.Conn.put_resp_cookie("BPMCSRF", "c1", path: "/")
        |> Req.Test.json(%{"Code" => 0})
      end

      assert {:ok, forms_client} =
               Auth.login_forms(forms_req, "u", "p",
                 base_url: "https://forms.example.com",
                 req_options: [plug: forms_plug]
               )

      assert forms_client.base_url == "https://forms.example.com"

      health_client = Client.new(base_url: "https://test.creatio.com")

      assert {:ok, "Healthy"} =
               Auth.oauth_health_check(health_client,
                 req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 200, "Healthy") end]
               )
    end

    test "issue 8: honors opts[:top] in streams, IO.Stream in update_field, 200 error maps, and 4-arg custom_service keyword payloads" do
      stream_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              Req.Test.json(conn, %{
                "value" => [%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}, %{"Id" => "4"}]
              })
            end
          ]
        )

      assert [%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}] =
               Creatio.stream!(stream_client, "Contact", top: 3, page_size: 2)
               |> Enum.to_list()

      # %IO.Stream{} binary upload in OData.update_field/6
      {:ok, io_dev} = StringIO.open("binary-stream-content")
      io_stream = IO.binstream(io_dev, 6)

      try do
        upload_client =
          Client.new(
            base_url: "https://test.creatio.com",
            req_options: [
              plug: fn conn ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)
                assert body == "binary-stream-content"
                Plug.Conn.send_resp(conn, 204, "")
              end
            ]
          )

        assert :ok == OData.update_field(upload_client, "Contact", "id-1", "Photo", io_stream)
      after
        if Process.alive?(io_dev), do: StringIO.close(io_dev)
      end

      # HTTP 200 error maps and invalid OData3 shapes
      err_map_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn -> Req.Test.json(conn, %{"error" => %{"message" => "boom"}}) end
          ]
        )

      assert {:error, %Error{status: 200}} = OData.get(err_map_client, "Contact", "id-1")
      assert {:error, %Error{status: 200}} = OData3.get(err_map_client, "Contact", "id-1")
      assert {:error, %Error{status: 200}} = OData3.list(err_map_client, "Contact")

      nil_o3_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [plug: fn conn -> Req.Test.json(conn, %{"d" => nil}) end]
        )

      assert {:error, %Error{status: 200}} = OData3.get(nil_o3_client, "Contact", "id-1")

      # 4-arg DataService.custom_service treats non-option keyword list as JSON payload
      ds_client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              assert conn.method == "POST"
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              assert Jason.decode!(body) == %{"alpha" => 1, "beta" => "two"}
              Req.Test.json(conn, %{"ok" => true})
            end
          ]
        )

      assert {:ok, %{"ok" => true}} =
               DataService.custom_service(ds_client, "CustomSvc", "DoWork", alpha: 1, beta: "two")

      assert_raise ArgumentError, fn ->
        Client.put_bearer_token(ds_client, "")
      end
    end
  end
end
