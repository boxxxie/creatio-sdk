defmodule Creatio.UtilTest do
  use ExUnit.Case, async: true

  alias Creatio.{Auth, Client, DataService, Error, OData, OData3, Util}
  alias Creatio.OData.Query

  describe "prepare_field_value_request/4 transport safety" do
    test "defaults Accept: */*, strips :method and :url, and preserves duplicate query params" do
      req = Req.new(base_url: "https://crm.test")

      {prepared_req, req_opts} =
        Util.prepare_field_value_request(
          req,
          "/0/odata/Contact(1)/Photo/$value",
          req_options: [
            method: :delete,
            url: "https://evil.test",
            params: [{"$filter", "A"}, {"$filter", "B"}]
          ]
        )

      assert Req.Request.get_header(prepared_req, "accept") == ["*/*"]
      assert Keyword.fetch!(req_opts, :url) == "/0/odata/Contact(1)/Photo/$value"
      refute Keyword.has_key?(req_opts, :method)
      assert Keyword.fetch!(req_opts, :params) == [{"$filter", "A"}, {"$filter", "B"}]

      {explicit_accept_req, _explicit_accept_opts} =
        Util.prepare_field_value_request(
          req,
          "/0/odata/Contact(1)/Photo/$value",
          headers: [{"Accept", "image/png"}]
        )

      assert Req.Request.get_header(explicit_accept_req, "accept") == ["image/png"]
    end
  end

  describe "response_header/2" do
    test "extracts header values case-insensitively and ignores malformed or empty entries" do
      map_headers = %{
        "OData-EntityId" => ["https://crm.test/0/odata/Contact(123)"],
        "content-type" => "application/json; charset=utf-8"
      }

      assert Util.response_header(map_headers, "odata-entityid") ==
               "https://crm.test/0/odata/Contact(123)"

      assert Util.response_header(map_headers, "Content-Type") ==
               "application/json; charset=utf-8"

      list_headers = [
        {"X-Empty", ""},
        {"Location", "https://crm.test/0/odata/Account(456)"}
      ]

      assert Util.response_header(list_headers, "location") ==
               "https://crm.test/0/odata/Account(456)"

      assert Util.response_header(list_headers, "x-missing") == nil

      weird_headers = [
        :not_a_tuple,
        {"X-Trace", ["", "   ", "trace-1"]},
        {"X-Empty-List", []},
        {"X-Non-Bin", [123]}
      ]

      assert Util.response_header(weird_headers, "x-trace") == "trace-1"
      assert Util.response_header(weird_headers, "x-empty-list") == nil
      assert Util.response_header(weird_headers, "x-non-bin") == nil
      assert Util.response_header(:invalid_headers, "x-trace") == nil
    end
  end

  describe "normalize_json_response/1 and html_or_xml_response?/1" do
    test "normalize_json_response/1 decodes JSON delivered with text/html or BOM and leaves HTML/malformed/non-JSON intact" do
      obj_resp = %Req.Response{
        status: 201,
        headers: %{"content-type" => ["text/html; charset=utf-8"]},
        body: "\uFEFF  {\"Id\":\"abc\",\"Name\":\"Alice\"} "
      }

      assert %Req.Response{body: %{"Id" => "abc", "Name" => "Alice"}} =
               Util.normalize_json_response(obj_resp)

      arr_resp = %Req.Response{
        status: 200,
        headers: %{"content-type" => ["text/html"]},
        body: "[{\"Id\":\"1\"}]"
      }

      assert %Req.Response{body: [%{"Id" => "1"}]} = Util.normalize_json_response(arr_resp)

      unchanged_cases = [
        %Req.Response{status: 200, body: "<html><body>WAF</body></html>"},
        %Req.Response{status: 200, body: "plain ok response"},
        %Req.Response{status: 200, body: %{"ok" => true}},
        %Req.Response{status: 200, body: "{not json"},
        %Req.Response{status: 200, body: nil, headers: %{"content-type" => ["text/html"]}}
      ]

      for resp <- unchanged_cases do
        assert Util.normalize_json_response(resp) == resp
      end
    end

    test "html_or_xml_response?/1 detects HTML/XML interstitials and WAF pages while ignoring JSON and plain text" do
      true_cases = [
        %Req.Response{
          status: 200,
          headers: %{"content-type" => ["text/html"]},
          body: "<iframe id=\"main-iframe\" src=\"/_Incapsula_Resource?SWUDNSAI=31\"></iframe>"
        },
        %Req.Response{
          status: 200,
          headers: %{"content-type" => ["text/plain"]},
          body: "\uFEFF  <!DOCTYPE html><html><body>Login</body></html>"
        },
        %Req.Response{
          status: 200,
          headers: %{"content-type" => ["application/xml; charset=utf-8"]},
          body: "plain non-json text"
        }
      ]

      false_cases = [
        %Req.Response{
          status: 200,
          headers: %{"content-type" => ["text/html"]},
          body: %{"Id" => "1"}
        },
        %Req.Response{
          status: 200,
          headers: %{"content-type" => ["text/plain"]},
          body: "plain ok response"
        },
        %Req.Response{status: 200, body: nil, headers: %{"content-type" => ["text/html"]}},
        %Req.Response{status: 200, body: "   ", headers: %{"content-type" => ["text/html"]}}
      ]

      for resp <- true_cases, do: assert(Util.html_or_xml_response?(resp))
      for resp <- false_cases, do: assert(Util.html_or_xml_response?(resp) == false)
    end
  end

  describe "paginate_stream/5 and paginate_stream!/5" do
    test "paginate_stream/5 yields {:ok, record} tuples and emits {:error, error} before halting on failure" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      list_fun = fn _client, _entity, opts ->
        case Keyword.get(opts, :skip) do
          0 -> {:ok, [%{"Id" => "1"}, %{"Id" => "2"}]}
          2 -> {:error, %Creatio.Error{status: 500, message: "page 2 failed"}}
        end
      end

      results =
        Util.paginate_stream(client, "Contact", [page_size: 2], :odata4, list_fun)
        |> Enum.to_list()

      assert [
               {:ok, %{"Id" => "1"}},
               {:ok, %{"Id" => "2"}},
               {:error, %Creatio.Error{status: 500, message: "page 2 failed"}}
             ] = results
    end

    test "paginate_stream!/5 yields plain record maps and raises Creatio.Error on failure" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      ok_list_fun = fn _client, _entity, opts ->
        case Keyword.get(opts, :skip) do
          0 -> {:ok, [%{"Id" => "1"}, %{"Id" => "2"}]}
          2 -> {:ok, [%{"Id" => "3"}]}
          3 -> {:ok, []}
        end
      end

      assert [%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}] =
               Util.paginate_stream!(client, "Contact", [page_size: 2], :odata4, ok_list_fun)
               |> Enum.to_list()

      failing_list_fun = fn _client, _entity, opts ->
        case Keyword.get(opts, :skip) do
          0 -> {:ok, [%{"Id" => "1"}, %{"Id" => "2"}]}
          2 -> {:error, %Creatio.Error{status: 500, message: "boom"}}
        end
      end

      assert_raise Creatio.Error, ~r/boom/, fn ->
        Util.paginate_stream!(client, "Contact", [page_size: 2], :odata4, failing_list_fun)
        |> Enum.to_list()
      end
    end

    test "4-arity defaults, max_records caps, @odata.nextLink / __next, cursor types, and bad page payloads" do
      client = Creatio.Client.new(base_url: "https://test.creatio.com")

      # max_records: 0 halts without calling list_fun
      never_called = fn _, _, _ ->
        flunk("list_fun should not be called when max_records is 0")
      end

      assert [] =
               Util.paginate_stream(client, "Contact", [max_records: 0], never_called)
               |> Enum.to_list()

      # Integer max_records caps partial page and hits remaining: 0 halt guard
      capped_fun = fn _client, _entity, opts ->
        case Keyword.get(opts, :skip) do
          0 -> {:ok, [%{"Id" => "1"}, %{"Id" => "2"}]}
          2 -> {:ok, [%{"Id" => "3"}, %{"Id" => "4"}]}
        end
      end

      assert [%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}] =
               Util.paginate_stream!(
                 client,
                 "Contact",
                 [page_size: 2, max_records: 3],
                 capped_fun
               )
               |> Enum.to_list()

      # @odata.nextLink / __next continues even when fewer than fetch_size records return, then halts on []
      next_link_fun = fn _client, _entity, opts ->
        case Keyword.get(opts, :skip) do
          0 ->
            {:ok, %{records: [%{"Id" => "1"}], raw: %{"@odata.nextLink" => "next"}}}

          1 ->
            {:ok, %{records: [%{"Id" => "2"}], raw: %{"__next" => "next2"}}}

          2 ->
            {:ok, %{records: [], raw: %{}}}
        end
      end

      assert [{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}] =
               Util.paginate_stream(client, "Contact", [page_size: 10], next_link_fun)
               |> Enum.to_list()

      # Unexpected page payload produces {:error, %Creatio.Error{}}
      bad_payload_fun = fn _client, _entity, _opts -> {:ok, :unexpected_shape} end

      assert [{:error, %Creatio.Error{message: msg}}] =
               Util.paginate_stream(client, "Contact", [], bad_payload_fun) |> Enum.to_list()

      assert msg =~ "Unexpected stream page response"

      # Keyset cursor escaping single quotes when filter is nil or ""
      parent = self()

      string_cursor_fun = fn _client, _entity, opts ->
        send(parent, {:cursor_filter, Keyword.get(opts, :filter), Keyword.get(opts, :top)})

        case Keyword.get(opts, :filter) do
          "Name gt 'O''Brien'" -> {:ok, [%{"Id" => "2", "Name" => "Smith"}]}
          _ -> {:ok, []}
        end
      end

      assert [{:ok, %{"Id" => "2", "Name" => "Smith"}}] =
               Util.paginate_stream(
                 client,
                 "Contact",
                 %{
                   page_size: 100,
                   cursor_field: "Name",
                   after_cursor: "O'Brien",
                   filter: ""
                 },
                 string_cursor_fun
               )
               |> Enum.to_list()

      assert_receive {:cursor_filter, "Name gt 'O''Brien'", 100}

      # Integer cursor with tie-breaker Id and filter: nil branch
      int_cursor_fun = fn _client, _entity, opts ->
        send(parent, {:int_cursor, Keyword.get(opts, :filter)})

        if Keyword.get(opts, :filter) == "Seq gt 41" do
          {:ok, [%{"Id" => "id-42", "Seq" => 42}, %{"Id" => "id-43", "Seq" => 43}]}
        else
          {:ok, []}
        end
      end

      assert [%{"Id" => "id-42", "Seq" => 42}, %{"Id" => "id-43", "Seq" => 43}] =
               Util.paginate_stream!(
                 client,
                 "Contact",
                 [page_size: 2, cursor_field: "Seq", after_cursor: 41],
                 :odata4,
                 int_cursor_fun
               )
               |> Enum.to_list()

      assert_receive {:int_cursor, "Seq gt 41"}
      assert_receive {:int_cursor, "(Seq gt 43 or (Seq eq 43 and Id gt 'id-43'))"}
    end
  end

  describe "additional Util helpers and edge cases" do
    test "wrap_error/1 preserves Creatio.Error and wraps exceptions and arbitrary terms" do
      err = %Creatio.Error{status: 400, message: "bad"}
      assert {:error, ^err} = Util.wrap_error(err)

      assert {:error, %Creatio.Error{message: "boom"}} =
               Util.wrap_error(%RuntimeError{message: "boom"})

      assert {:error, %Creatio.Error{message: ":timeout"}} = Util.wrap_error(:timeout)
    end

    test "get_opt/2 and get_opt/3 work with keyword lists, atom/string map keys, and defaults" do
      assert Util.get_opt([top: 10], :top) == 10
      assert Util.get_opt([top: 10], :missing, 50) == 50
      assert Util.get_opt(%{top: 20}, :top) == 20
      assert Util.get_opt(%{"top" => 30}, :top) == 30
      assert Util.get_opt(%{"top" => 30}, :missing) == nil
      assert Util.get_opt(%{"top" => 30}, :missing, :fallback) == :fallback
    end

    test "clean_guid/1 strips GUID wrappers and rejects traversal or injection characters" do
      id = "a1b2c3d4-0000-0000-0000-000000000001"
      assert Util.clean_guid(" guid'#{id}' ") == id
      assert Util.clean_guid("GUID'{#{id}}'") == id
      assert Util.clean_guid("{'#{id}'}") == id
      assert Util.clean_guid("'#{id}'") == id
      assert Util.clean_guid(id) == id

      assert Util.clean_guid("guid'{12345678-1234-1234-1234-123456789abc}'") ==
               "12345678-1234-1234-1234-123456789abc"

      for bad <- [
            "",
            "../etc",
            "1)/../../rest/Trigger?x=(",
            "1?foo=bar",
            "1#frag",
            "id with space"
          ] do
        assert_raise ArgumentError, fn ->
          Util.clean_guid(bad)
        end
      end
    end

    test "normalize_odata_params/3 handles maps, count: false, and ignores unsupported orderby" do
      params =
        Util.normalize_odata_params(
          %{
            count: false,
            orderby: 123,
            select: :Name,
            expand: "Account",
            params: [custom: 1]
          },
          %{"$count" => "true", "$inlinecount" => "allpages"}
        )

      refute Map.has_key?(params, "$count")
      refute Map.has_key?(params, "$inlinecount")
      refute Map.has_key?(params, "$orderby")
      assert params["$select"] == "Name"
      assert params["$expand"] == "Account"
      assert params["custom"] == "1"
    end

    test "prepare_field_value_request/4 merges req_options maps/headers/params and forces decode_body: false" do
      base_req = Req.new(base_url: "https://crm.test")

      {merged_req, req_opts} =
        Util.prepare_field_value_request(
          base_req,
          "/0/odata/SysFile(1)/Data/$value",
          %{
            headers: %{"x-top" => "yes", "x-shared" => "top"},
            req_options: %{
              "headers" => %{"x-shared" => "req", "x-req" => "1"},
              "params" => %{"a" => "req", "b" => "2"},
              "decode_body" => true,
              "url" => "/wrong"
            },
            params: %{"a" => "top"},
            select: ["Data"]
          }
        )

      assert merged_req.headers["x-top"] == ["yes"]
      assert merged_req.headers["x-shared"] == ["top"]
      assert merged_req.headers["x-req"] == ["1"]
      assert req_opts[:decode_body] == false
      assert req_opts[:url] == "/0/odata/SysFile(1)/Data/$value"
      assert req_opts[:params] == %{"$select" => "Data", "a" => "top", "b" => "2"}
    end

    test "prepare_field_value_request/4 merges duplicate keyword headers/params and rejects unsafe req_options" do
      base_req = Req.new(base_url: "https://crm.test")

      {merged_req, req_opts} =
        Util.prepare_field_value_request(
          base_req,
          "/0/odata/SysFile(1)/Data/$value",
          req_options: [
            headers: %{"x-one" => "1"},
            headers: %{"x-two" => "2"},
            params: %{"a" => "1", "c" => "old"},
            params: %{"b" => "2", "c" => "new"}
          ],
          params: %{"a" => "top"}
        )

      assert merged_req.headers["x-one"] == ["1"]
      assert merged_req.headers["x-two"] == ["2"]
      assert req_opts[:params] == %{"a" => "top", "b" => "2", "c" => "new"}

      assert_raise ArgumentError, ~r/unknown option key/, fn ->
        Util.prepare_field_value_request(
          base_req,
          "/0/odata/SysFile(1)/Data/$value",
          req_options: %{"definitely_unknown_creatio_opt_999" => true}
        )
      end

      assert_raise ArgumentError, ~r/keyword list or plain map/, fn ->
        Util.prepare_field_value_request(
          base_req,
          "/0/odata/SysFile(1)/Data/$value",
          req_options: URI.parse("https://crm.test")
        )
      end

      assert_raise ArgumentError, ~r/keyword list or plain map/, fn ->
        Util.prepare_field_value_request(
          base_req,
          "/0/odata/SysFile(1)/Data/$value",
          req_options: ["not_a_keyword"]
        )
      end
    end

    test "paginate_stream/5 parses valid string max_records and raises ArgumentError on invalid values" do
      client = Creatio.Client.new(base_url: "https://crm.test", req_options: [plug: & &1])

      page_fun = fn _c, _target, _opts ->
        {:ok, [%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}]}
      end

      records =
        Util.paginate_stream(client, "Contact", [max_records: "2"], :odata4, page_fun)
        |> Enum.to_list()

      assert records == [{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}]

      top_limited =
        Util.paginate_stream(
          client,
          Creatio.OData.Query.new("Contact") |> Creatio.OData.Query.top(2),
          [],
          :odata4,
          page_fun
        )
        |> Enum.to_list()

      assert top_limited == [{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}]

      assert_raise ArgumentError, ~r/expected :max_records to be a non-negative integer/, fn ->
        Util.paginate_stream(client, "Contact", [max_records: -1], :odata4, page_fun)
      end

      assert_raise ArgumentError, ~r/expected :max_records to be a non-negative integer/, fn ->
        Util.paginate_stream(client, "Contact", [max_records: "abc"], :odata4, page_fun)
      end

      map_records =
        Util.paginate_stream(
          client,
          "Contact",
          %{"page_size" => 2, "top" => 2},
          :odata4,
          page_fun
        )
        |> Enum.to_list()

      assert map_records == [{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}]
    end
  end

  describe "eager target, ID, and path-traversal validation guards" do
    test "rejects empty/invalid targets and path-traversal IDs or segments before issuing HTTP requests" do
      id = "00000000-0000-0000-0000-000000000003"

      client =
        Client.new(
          base_url: "https://test.creatio.com",
          req_options: [
            plug: fn conn ->
              flunk("should not issue HTTP request for invalid input: #{conn.request_path}")
            end
          ]
        )

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

      for bad_id <- ["1)/../../rest/CustomService/Trigger?x=(", "../etc", "a/b", "1?x=2"] do
        assert_raise ArgumentError, fn -> OData.get(client, "Contact", bad_id) end
        assert_raise ArgumentError, fn -> OData.delete(client, "Contact", bad_id) end
        assert_raise ArgumentError, fn -> OData3.get(client, "Contact", bad_id) end
      end

      assert_raise ArgumentError, fn -> OData.get(client, "Contact/../rest", "1") end

      assert_raise ArgumentError, fn ->
        OData.get_field(client, "Contact", "1", "Name/../$value")
      end

      assert_raise ArgumentError, fn ->
        OData.get_navigation(client, "Contact", "1", "Account/../Secret")
      end

      assert_raise ArgumentError, fn ->
        DataService.custom_service(client, "Svc/..", "Op", %{})
      end
    end
  end

  describe "security, streaming, pagination, and protocol regression fixes" do
    test "rejects external :url overrides and IIS path bypasses across DataService and Auth" do
      client = Client.new(base_url: "https://crm.test", auth_token: "secret-tok")
      ro_client = Client.new(base_url: "https://crm.test", read_only: true)

      for bad_url <- [
            "https://attacker.example/0/DataService/json/SyncReply/SelectQuery",
            "//attacker.example/0/DataService/json/SyncReply/SelectQuery",
            "/0/DataService/json/SyncReply/DeleteQuery/..%5cSelectQuery",
            "/0/DataService/json/SyncReply/DeleteQuery/.%2e/SelectQuery",
            "/0/DataService/json/SyncReply/DeleteQuery/%252e%252e/SelectQuery"
          ] do
        assert_raise ArgumentError, fn ->
          DataService.execute_query(ro_client, "SelectQuery", %{}, url: bad_url)
        end
      end

      assert {:error, %Error{message: msg}} =
               Auth.oauth_health_check(client, url: "https://attacker.example/steal")

      assert msg =~ "origin"

      assert {:error, %Error{message: login_msg}} =
               Auth.login_forms(client, "u", "p", url: "https://attacker.example/steal")

      assert login_msg =~ "origin"
    end

    test "Auth handles empty Set-Cookie on Code: 0 and map/stripped :req_options in openid_configuration" do
      no_cookie_client =
        Client.new(
          base_url: "https://crm.test",
          req_options: [
            plug: fn conn -> Req.Test.json(conn, %{"Code" => 0}) end
          ]
        )

      assert {:error, %Error{code: "FormsMissingCookies"}} =
               Auth.login_forms(no_cookie_client, "u", "p")

      parent = self()

      oidc_plug = fn conn ->
        send(parent, {:oidc_path, conn.request_path})
        Req.Test.json(conn, %{"issuer" => "https://id.crm.test"})
      end

      assert {:ok, %{"issuer" => "https://id.crm.test"}} =
               Auth.openid_configuration("https://id.crm.test/.well-known/openid-configuration",
                 req_options: %{plug: oidc_plug, url: "https://attacker.example/evil"}
               )

      assert_receive {:oidc_path, "/.well-known/openid-configuration"}
    end

    test "DataService.custom_service/5 supports 4-arity Req opts and preserves req_options[:params]" do
      parent = self()

      plug = fn conn ->
        send(parent, {:custom_req, conn.method, conn.query_string, Plug.Conn.read_body(conn)})
        Req.Test.json(conn, %{"ok" => true})
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, %{"ok" => true}} =
               DataService.custom_service(client, "Svc", "Ping", receive_timeout: 15_000)

      assert_receive {:custom_req, "POST", "", {:ok, "{}", _}}

      assert {:ok, %{"ok" => true}} =
               DataService.custom_service(client, "Svc", "Echo", %{"a" => 1},
                 params: %{"x" => "1"},
                 req_options: [params: %{"y" => "2", "x" => "old"}]
               )

      assert_receive {:custom_req, "POST", qs, {:ok, ~s({"a":1}), _}}
      assert URI.decode_query(qs) == %{"x" => "1", "y" => "2"}
    end

    test "fetch_field_value/4 does not corrupt File.stream! on retry and blocks HTML-typed JSON errors >= 1024 bytes" do
      tmp_dir = System.tmp_dir!()
      retry_path = Path.join(tmp_dir, "creatio_retry_#{System.unique_integer([:positive])}.bin")
      err_path = Path.join(tmp_dir, "creatio_json_err_#{System.unique_integer([:positive])}.bin")
      on_exit(fn -> Enum.each([retry_path, err_path], &File.rm/1) end)

      attempts = :counters.new(1, [:atomics])
      chunk_1500 = String.duplicate("A", 1500)

      retry_adapter = fn req ->
        n = :counters.get(attempts, 1) + 1
        :counters.put(attempts, 1, n)

        if n == 1 do
          resp = %Req.Response{status: 200, headers: %{}, body: ""}

          case req.into.(
                 {:data, chunk_1500},
                 {req, resp}
               ) do
            {:cont, _} -> {req, %Req.TransportError{reason: :closed}}
            {:halt, _} -> {req, %Req.TransportError{reason: :closed}}
          end
        else
          resp = %Req.Response{status: 200, headers: %{}, body: ""}
          {:cont, {req2, resp2}} = req.into.({:data, "FINAL_BODY"}, {req, resp})
          {req2, resp2}
        end
      end

      assert {:ok, %File.Stream{}} =
               Util.fetch_field_value(
                 Req.new(base_url: "https://crm.test"),
                 "/0/odata/Contact(1)/Photo/$value",
                 into: File.stream!(retry_path),
                 req_options: [adapter: retry_adapter, retry: :transient, retry_delay: 0]
               )

      assert File.read!(retry_path) == "FINAL_BODY"

      large_json_err = Jason.encode!(%{"error" => %{"message" => String.duplicate("E", 1200)}})

      html_json_plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, large_json_err)
      end

      assert {:error, %Error{status: 200}} =
               Util.fetch_field_value(
                 Req.new(base_url: "https://crm.test"),
                 "/0/odata/Contact(1)/Photo/$value",
                 into: File.stream!(err_path),
                 req_options: [plug: html_json_plug]
               )

      refute File.exists?(err_path)
    end

    test "keyset pagination rejects non-map records cleanly, supports desc orderby, and rejects mismatched orderby" do
      client = Client.new(base_url: "https://crm.test")

      non_map_fun = fn _c, _t, _opts -> {:ok, ["not_a_map"]} end

      assert [{:ok, "not_a_map"}, {:error, %Error{message: msg}}] =
               Util.paginate_stream(client, "Contact", [cursor_field: "Id"], :odata4, non_map_fun)
               |> Enum.to_list()

      assert msg =~ "missing or nil"

      parent = self()

      desc_fun = fn _c, _t, opts ->
        send(parent, {:desc_page, Keyword.get(opts, :orderby), Keyword.get(opts, :filter)})

        if Keyword.get(opts, :filter) do
          {:ok, []}
        else
          {:ok, [%{"CreatedOn" => "2026-02-01T00:00:00Z", "Id" => "id-9"}]}
        end
      end

      assert [%{"Id" => "id-9"}] =
               Util.paginate_stream!(
                 client,
                 "Contact",
                 [cursor_field: "CreatedOn", orderby: "CreatedOn desc", page_size: 1],
                 :odata4,
                 desc_fun
               )
               |> Enum.to_list()

      assert_receive {:desc_page, "CreatedOn desc, Id desc", nil}

      assert_receive {:desc_page, "CreatedOn desc, Id desc",
                      "(CreatedOn lt 2026-02-01T00:00:00Z or (CreatedOn eq 2026-02-01T00:00:00Z and Id lt 'id-9'))"}

      assert_raise ArgumentError, ~r/cursor_field/, fn ->
        Util.paginate_stream!(
          client,
          "Contact",
          [cursor_field: "Id", orderby: "Name asc"],
          :odata4,
          desc_fun
        )
        |> Enum.to_list()
      end
    end

    test "OData.update_field/6 handles map opts, raw JSON/text uploads, query params, and RFC 9110 Accept" do
      parent = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:put_field, conn.query_string, Plug.Conn.get_req_header(conn, "accept"),
           Plug.Conn.get_req_header(conn, "content-type"), raw}
        )

        Plug.Conn.send_resp(conn, 204, "")
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert :ok ==
               OData.update_field(
                 client,
                 "SysFile",
                 "1",
                 "Data",
                 ~s({"raw":true}),
                 %{content_type: "application/json", params: %{"v" => "1"}}
               )

      assert_receive {:put_field, "v=1", ["application/json, text/plain, */*"],
                      ["application/json"], ~s({"raw":true})}
    end

    test "OData and OData3 forward :req_options, avoid map return leakage, handle count list fallback, and catch OData3 get_field d.error" do
      parent = self()

      plug = fn conn ->
        send(parent, {:hit, conn.request_path, conn.query_string})

        case conn.request_path do
          "/0/odata/Contact" when conn.method == "POST" ->
            Plug.Conn.send_resp(conn, 204, "")

          "/0/odata/Contact" ->
            Req.Test.json(conn, [%{"Id" => "1"}])

          "/0/ServiceModel/EntityDataService.svc/ContactCollection" ->
            Req.Test.json(conn, %{"d" => [%{"Id" => "1"}]})

          "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')/Name" ->
            Req.Test.json(conn, %{"d" => %{"error" => %{"message" => "field fail"}}})
        end
      end

      client = Client.new(base_url: "https://crm.test")

      assert {:ok, %{records: [%{"Id" => "1"}], count: nil}} =
               OData.list(client, "Contact", count: true, req_options: [plug: plug])

      assert {:ok, %{}} =
               OData.create(client, "Contact", %{"Name" => "A"}, %{
                 "return" => :minimal,
                 req_options: [plug: plug]
               })

      assert_receive {:hit, "/0/odata/Contact", qs}
      refute qs =~ "return=minimal"

      assert {:ok, %{records: [%{"Id" => "1"}], count: nil}} =
               OData3.list(client, "Contact", count: true, req_options: [plug: plug])

      assert {:error, %Error{status: 200}} =
               OData3.get_field(client, "Contact", "1", "Name", req_options: [plug: plug])
    end
  end

  describe "protocol, security, and pagination regressions" do
    test "quotes lookalike non-hex 36-char UUIDs in cursors and rejects invalid cursor_field" do
      alias Creatio.OData

      parent = self()
      malicious = "00000000-0000-0000-0000-0 eq 0 or 1 "

      plug = fn conn ->
        send(parent, {:req_qs, conn.query_string})
        Req.Test.json(conn, %{"value" => []})
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert [] =
               OData.stream(client, "Contact",
                 cursor_field: "Notes",
                 after_cursor: malicious
               )
               |> Enum.to_list()

      assert_receive {:req_qs, qs}
      params = URI.decode_query(qs)
      assert params["$filter"] == "Notes gt '00000000-0000-0000-0000-0 eq 0 or 1 '"

      for bad_cursor <- [false, true, "", "Id eq 1"] do
        assert_raise ArgumentError, fn ->
          Util.paginate_stream(client, "Contact", [cursor_field: bad_cursor], fn _, _, _ ->
            {:ok, []}
          end)
          |> Enum.to_list()
        end
      end
    end

    test "formats OData 3 DateTime cursors across MS AJAX, DateTime, NaiveDateTime, and ISO strings" do
      alias Creatio.OData3

      parent = self()

      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        send(parent, {:o3_filter, query["$filter"]})
        Req.Test.json(conn, %{"d" => %{"results" => []}})
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      for {after_cursor, expected_fragment} <- [
            {"/Date(1704067200000)/", "CreatedOn gt datetime'2024-01-01T00:00:00'"},
            {"/Date(-86400000)/", "CreatedOn gt datetime'1969-12-31T00:00:00'"},
            {"/Date(1704067200000+0200)/",
             "CreatedOn gt datetimeoffset'2024-01-01T02:00:00+02:00'"},
            {~U[2024-05-01 14:30:00Z], "CreatedOn gt datetimeoffset'2024-05-01T14:30:00Z'"},
            {~N[2024-05-01 14:30:00], "CreatedOn gt datetime'2024-05-01T14:30:00'"},
            {"2024-05-01T14:30:00Z", "CreatedOn gt datetimeoffset'2024-05-01T14:30:00Z'"},
            {"2024-05-01T14:30:00", "CreatedOn gt datetime'2024-05-01T14:30:00'"}
          ] do
        assert [] =
                 OData3.stream(client, "Contact",
                   cursor_field: "CreatedOn",
                   after_cursor: after_cursor
                 )
                 |> Enum.to_list()

        assert_receive {:o3_filter, ^expected_fragment}
      end
    end

    test "strip_guid_syntax/1 and format_record_key/2 handle braced guids, integers, and string keys" do
      uuid = "12345678-1234-1234-1234-123456789abc"
      assert Util.strip_guid_syntax("{guid'#{uuid}'}") == uuid
      assert Util.format_record_key(uuid, :odata4) == uuid
      assert Util.format_record_key(uuid, :odata3) == "guid'#{uuid}'"
      assert Util.format_record_key(123, :odata4) == "123"
      assert Util.format_record_key(123, :odata3) == "123"
      assert Util.format_record_key("CODE", :odata4) == "'CODE'"
      assert Util.format_record_key("CODE", :odata3) == "'CODE'"
    end

    test "stream pagination resists :params overrides, follows TLS-downgraded nextLink, and handles low server caps" do
      parent = self()
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        page_idx = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
        send(parent, {:stream_req, page_idx, query})

        case page_idx do
          0 ->
            Req.Test.json(conn, %{
              "value" => [%{"Id" => "1"}, %{"Id" => "2"}],
              "@odata.nextLink" => "http://mycreatio.com/0/odata/Contact?$skiptoken=tok1&$top=2"
            })

          1 ->
            Req.Test.json(conn, %{
              "value" => [%{"Id" => "3"}]
            })
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      items =
        Util.paginate_stream(
          client,
          "Contact",
          [page_size: 2, params: %{"$skip" => 999, "$top" => 1, "custom" => "ok"}],
          fn _c, _t, opts ->
            params = Util.normalize_odata_params(opts, %{}, {"$count", "true"})
            send(parent, {:page_params, params})

            case params["$skiptoken"] do
              nil ->
                {:ok,
                 %{
                   records: [%{"Id" => "1"}, %{"Id" => "2"}],
                   count: nil,
                   raw: %{
                     "@odata.nextLink" =>
                       "http://mycreatio.com/0/odata/Contact?$skiptoken=tok1&$top=2"
                   }
                 }}

              "tok1" ->
                {:ok, %{records: [%{"Id" => "3"}], count: nil, raw: %{}}}
            end
          end
        )
        |> Enum.to_list()

      assert items == [{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}, {:ok, %{"Id" => "3"}}]
      assert_receive {:page_params, %{"$top" => "2", "$skip" => "0", "custom" => "ok"}}
      assert_receive {:page_params, %{"$top" => "2", "$skiptoken" => "tok1", "custom" => "ok"}}

      # Low server MaxEntityRowCount without @odata.nextLink continues until []
      {:ok, cap_agent} = Agent.start_link(fn -> 0 end)

      cap_results =
        Util.paginate_stream!(client, "Contact", [page_size: 5_000], fn _c, _t, opts ->
          idx = Agent.get_and_update(cap_agent, fn n -> {n, n + 1} end)
          params = Util.normalize_odata_params(opts, %{}, {"$count", "true"})
          send(parent, {:cap_page, idx, params["$skip"], params["$top"]})

          case idx do
            0 -> {:ok, [%{"Id" => "a"}, %{"Id" => "b"}]}
            1 -> {:ok, [%{"Id" => "c"}]}
            _ -> {:ok, []}
          end
        end)
        |> Enum.to_list()

      assert cap_results == [%{"Id" => "a"}, %{"Id" => "b"}, %{"Id" => "c"}]
      assert_receive {:cap_page, 0, "0", "5000"}
      assert_receive {:cap_page, 1, "2", "5000"}
      assert_receive {:cap_page, 2, "3", "5000"}
    end

    test "normalize_odata_params/3 and ensure_cursor_select_in_opts drop nil/boolean/blank select, expand, filter and normalize params lists" do
      params =
        Util.normalize_odata_params(
          [
            select: nil,
            select: false,
            select: [],
            expand: nil,
            expand: false,
            filter: nil,
            params: [:bad_entry, foo: ["a", "b"], ignored: nil]
          ],
          %{},
          {"$count", "true"}
        )

      refute Map.has_key?(params, "$select")
      refute Map.has_key?(params, "$expand")
      refute Map.has_key?(params, "$filter")
      assert params["foo"] == "a,b"
      refute Map.has_key?(params, "ignored")

      map_params =
        Util.normalize_odata_params(
          %{"$filter" => nil, "$select" => [], "$expand" => ""},
          %{},
          {"$count", "true"}
        )

      assert map_params == %{}

      # Blank select + cursor_field should NOT restrict $select to only ["Id"]
      parent = self()

      Util.paginate_stream(
        Client.new(base_url: "https://mycreatio.com"),
        "Contact",
        [cursor_field: "Id", select: nil, params: %{"$select" => ["Name"]}],
        fn _c, _t, opts ->
          p = Util.normalize_odata_params(opts, %{}, {"$count", "true"})
          send(parent, {:cursor_select, p["$select"]})
          {:ok, []}
        end
      )
      |> Enum.to_list()

      assert_receive {:cursor_select, "Name,Id"}
    end

    test "OData and OData3 count, delete, create, and @odata.null handle Accept headers, query stripping, and responses" do
      alias Creatio.{OData, OData3}

      parent = self()

      plug = fn conn ->
        send(
          parent,
          {:req, conn.method, conn.request_path, URI.decode_query(conn.query_string),
           Plug.Conn.get_req_header(conn, "accept")}
        )

        case {conn.method, conn.request_path} do
          {"GET", "/0/odata/Contact/$count"} ->
            conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "7")

          {"GET", "/0/odata/Contact"} ->
            Req.Test.json(conn, %{"@odata.count" => 7, "value" => []})

          {"POST", "/0/odata/Contact"} ->
            conn
            |> Plug.Conn.put_resp_header(
              "odata-entityid",
              "https://mycreatio.com/0/odata/Contact(12345678-1234-1234-1234-123456789abc)"
            )
            |> Plug.Conn.send_resp(201, "")

          {"GET", "/0/odata/Contact(12345678-1234-1234-1234-123456789abc)/Account"} ->
            Req.Test.json(conn, %{"@odata.context" => "ctx", "@odata.null" => true})

          {"GET", "/0/odata/Contact(12345678-1234-1234-1234-123456789abc)/MiddleName"} ->
            Req.Test.json(conn, %{"@odata.context" => "ctx", "@odata.null" => true})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count"} ->
            conn |> Plug.Conn.put_resp_content_type("text/plain") |> Plug.Conn.send_resp(200, "9")

          {"POST", "/0/ServiceModel/EntityDataService.svc/ContactCollection"} ->
            conn
            |> Plug.Conn.put_resp_header(
              "location",
              "https://mycreatio.com/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'12345678-1234-1234-1234-123456789abc')"
            )
            |> Plug.Conn.send_resp(201, "")

          {"DELETE",
           "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'12345678-1234-1234-1234-123456789abc')"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      uuid = "12345678-1234-1234-1234-123456789abc"

      assert {:ok, 7} = OData.count(client, "Contact", top: 50, select: "Id", filter: "Active")
      assert_receive {:req, "GET", "/0/odata/Contact/$count", q1, [accept1]}
      assert q1 == %{"$filter" => "Active"}
      assert accept1 =~ "text/plain"

      assert {:ok, 7} =
               OData.count(client, "Contact", %{
                 "strategy" => :top_zero,
                 "$top" => 50,
                 "$skip" => 5,
                 "$select" => "Id"
               })

      assert_receive {:req, "GET", "/0/odata/Contact", q2, _}
      assert q2["$top"] == "0"
      assert q2["$count"] == "true"
      refute Map.has_key?(q2, "$skip")
      refute Map.has_key?(q2, "$select")

      assert {:ok, %{"Id" => ^uuid, "@odata.id" => _}} =
               OData.create(client, "Contact", %{"Name" => "New"})

      assert {:ok, nil} = OData.get_navigation(client, "Contact", uuid, "Account")
      assert {:ok, nil} = OData.get_field(client, "Contact", uuid, "MiddleName")

      assert {:ok, 9} = OData3.count(client, "Contact", top: 10, inlinecount: "allpages")

      assert_receive {:req, "GET",
                      "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count", q3,
                      [accept3]}

      assert q3 == %{}
      refute accept3 =~ "odata.metadata=minimal"
      assert accept3 =~ "text/plain"

      assert {:ok, %{"Id" => ^uuid}} =
               OData3.create(client, "Contact", %{"Name" => "Legacy"})

      assert :ok = OData3.delete(client, "Contact", uuid)

      expected_del_path =
        "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'#{uuid}')"

      assert_receive {:req, "DELETE", ^expected_del_path, _, [accept_del]}

      assert accept_del == "application/json; odata=verbose"
    end

    test "Auth.login_forms preserves comma values, drops cleared cookies, and keeps undecoded BPMCSRF" do
      alias Creatio.Auth

      plug = fn conn ->
        conn
        |> Map.put(:resp_headers, [
          {"set-cookie", ".ASPXAUTH=tok%2B1,seg=val; path=/; HttpOnly"},
          {"set-cookie", "OldCookie=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/"},
          {"set-cookie", "BPMCSRF=\"abc%2Bdef\"; path=/"}
        ])
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"Code" => 0}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, authed} = Auth.login_forms(client, "Supervisor", "Supervisor")

      assert authed.cookie =~ ".ASPXAUTH=tok%2B1,seg=val"
      refute authed.cookie =~ "OldCookie"
      assert authed.bpmcsrf == "\"abc%2Bdef\""
    end

    test "DataService.custom_service normalizes string GET, skips empty list JSON body, handles nil req_options, and rejects 200 WCF errors" do
      alias Creatio.DataService

      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:custom_svc, conn.method, body})

        case conn.request_path do
          "/0/rest/Svc/Ping" ->
            Req.Test.json(conn, %{"ok" => true})

          "/0/rest/Svc/WcfErr" ->
            Req.Test.json(conn, %{"responseStatus" => %{"ErrorCode" => "E"}})

          "/0/rest/Svc/ErrObj" ->
            Req.Test.json(conn, %{"error" => %{"message" => "fail"}})
        end
      end

      ro =
        Client.new(base_url: "https://mycreatio.com", read_only: true, req_options: [plug: plug])

      assert {:ok, %{"ok" => true}} =
               DataService.custom_service(ro, "Svc", "Ping", [], method: "GET", req_options: nil)

      assert_receive {:custom_svc, "GET", ""}

      assert {:error, %Error{status: 200}} =
               DataService.custom_service(ro, "Svc", "WcfErr", [], method: "GET")

      assert {:error, %Error{status: 200}} =
               DataService.custom_service(ro, "Svc", "ErrObj", [], method: "GET")
    end

    test "keyset pagination handles nullable final-page cursors without error and errors on missing intermediate tie-breaker Id" do
      client = Client.new(base_url: "https://crm.test")

      # Short final page with nil nullable cursor_field should NOT emit a bogus error
      short_final_fun = fn _c, _t, _opts ->
        {:ok, [%{"Id" => "id-1", "ModifiedOn" => nil}]}
      end

      assert [{:ok, %{"Id" => "id-1", "ModifiedOn" => nil}}] =
               Util.paginate_stream(
                 client,
                 "Contact",
                 [cursor_field: "ModifiedOn", page_size: 2],
                 :odata4,
                 short_final_fun
               )
               |> Enum.to_list()

      # Cap-reached final page (max_records: 1) with nil cursor_field should NOT emit a bogus error
      assert [%{"Id" => "id-1", "ModifiedOn" => nil}] =
               Util.paginate_stream!(
                 client,
                 "Contact",
                 [cursor_field: "ModifiedOn", page_size: 1, max_records: 1],
                 :odata4,
                 short_final_fun
               )
               |> Enum.to_list()

      # Intermediate page with cursor_field != "Id" and nil "Id" MUST emit error instead of falling back
      missing_id_fun = fn _c, _t, _opts ->
        {:ok, [%{"ModifiedOn" => "2026-01-01T00:00:00Z"}]}
      end

      assert [{:ok, %{"ModifiedOn" => "2026-01-01T00:00:00Z"}}, {:error, %Error{message: msg}}] =
               Util.paginate_stream(
                 client,
                 "Contact",
                 [cursor_field: "ModifiedOn", page_size: 1],
                 :odata4,
                 missing_id_fun
               )
               |> Enum.to_list()

      assert msg =~ "tie-breaker"
    end

    test "OData and OData3 preserve ComplexType fields, wrap structs, stream iodata raw lists, delegate nil update_field to DELETE, and reject 200 error envelopes" do
      parent = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:req, conn.method, conn.request_path, conn.req_headers, raw})

        case {conn.method, conn.request_path} do
          {"GET", "/0/odata/Contact('1')/Money"} ->
            Req.Test.json(conn, %{"value" => 100, "currency" => "USD"})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')/Address"} ->
            Req.Test.json(conn, %{"d" => %{"Address" => "123 Main", "City" => "NYC"}})

          {"PUT", "/0/odata/Contact('1')/BirthDate"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"PUT", "/0/odata/Contact('1')/Data"} ->
            Plug.Conn.send_resp(conn, 200, "\uFEFF   ")

          {"DELETE", "/0/odata/Contact('1')/MiddleName"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"POST", "/0/odata/Contact"} ->
            Req.Test.json(conn, %{
              "errorInfo" => %{"errorCode" => "E1", "message" => "Create fail"}
            })

          {"PATCH", "/0/odata/Contact('1')"} ->
            Req.Test.json(conn, %{"ExceptionMessage" => "Patch fail"})

          {"DELETE", "/0/odata/Contact('1')"} ->
            Req.Test.json(conn, %{"d" => %{"error" => %{"message" => "Delete fail"}}})

          {"POST", "/0/DataService/json/SyncReply/SelectQuery"} ->
            Req.Test.json(conn, %{
              "responseStatus" => %{"ErrorCode" => "DS1", "Message" => "DS fail"}
            })

          {"GET", "/.well-known/openid-configuration"} ->
            Req.Test.json(conn, %{"error" => "oidc_error"})
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, %{"value" => 100, "currency" => "USD"}} =
               OData.get_field(client, "Contact", "1", "Money")

      assert {:ok, %{"Address" => "123 Main", "City" => "NYC"}} =
               OData3.get_field(client, "Contact", "1", "Address")

      assert :ok = OData.update_field(client, "Contact", "1", "BirthDate", ~D[2026-01-15])

      assert_receive {:req, "PUT", "/0/odata/Contact('1')/BirthDate", _,
                      ~s({"value":"2026-01-15"})}

      assert :ok =
               OData.update_field(client, "Contact", "1", "Data", ["hello", " ", "world"],
                 content_type: "application/octet-stream"
               )

      assert_receive {:req, "PUT", "/0/odata/Contact('1')/Data", headers_put, "hello world"}

      assert List.keyfind(headers_put, "content-type", 0) ==
               {"content-type", "application/octet-stream"}

      assert :ok = OData.update_field(client, "Contact", "1", "MiddleName", nil)
      assert_receive {:req, "DELETE", "/0/odata/Contact('1')/MiddleName", _, ""}

      assert {:error, %Error{code: "E1", message: "Create fail"}} =
               OData.create(client, "Contact", %{"Name" => "X"})

      assert {:error, %Error{message: "Patch fail"}} =
               OData.update(client, "Contact", "1", %{"Name" => "Y"})

      assert {:error, %Error{message: "Delete fail"}} = OData.delete(client, "Contact", "1")

      assert {:error, %Error{code: "DS1", message: "DS fail"}} =
               Creatio.DataService.select_query(client, %{})

      assert {:error, %Error{status: 200}} =
               Auth.openid_configuration("https://crm.test/.well-known/openid-configuration",
                 req_options: [plug: plug]
               )
    end

    test "normalizes $-prefixed OData options, rejects non-binary :filter and invalid :skip/:page_size" do
      assert_raise ArgumentError, ~r/expected :filter to be a binary/, fn ->
        Util.normalize_odata_params([filter: [Name: "Alice"]], %{}, {"$count", "true"})
      end

      params =
        Util.normalize_odata_params(
          %{
            "$count" => true,
            "$top" => nil,
            "$orderby" => [{"Name", :asc}],
            :params => %{"$filter" => ""}
          },
          %{},
          {"$inlinecount", "allpages"}
        )

      assert params == %{"$inlinecount" => "allpages", "$orderby" => "Name asc"}

      client = Client.new(base_url: "https://crm.test")

      for bad_opts <- [
            [page_size: 0],
            [page_size: -1],
            [page_size: "bad"],
            [skip: -1],
            [skip: "bad"]
          ] do
        assert_raise ArgumentError, fn ->
          Util.paginate_stream(client, "Contact", bad_opts, :odata4, fn _, _, _ -> {:ok, []} end)
        end
      end
    end

    test "DataService OPTIONS/pre-encoded JSON, Auth forms/OAuth/cookies, HTML comment WAF, and 2-arity into: gating" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:svc_req, conn.method, conn.request_path, conn.req_headers, body})

        case {conn.method, conn.request_path} do
          {"OPTIONS", "/0/rest/Svc/Ep"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"POST", "/0/rest/Svc/Ep"} ->
            Req.Test.json(conn, %{"ok" => true})

          {"POST", "/ServiceModel/AuthService.svc/Login"} ->
            if String.contains?(body, "bad") do
              Req.Test.json(conn, %{"Code" => 1, "Message" => ""})
            else
              conn
              |> Map.put(:resp_headers, [
                {"set-cookie", ".ASPXAUTH=auth1; Path=/0; HttpOnly"},
                {"set-cookie", "BPMCSRF=valid_csrf; Path=/0; HttpOnly"},
                {"set-cookie", "BPMCSRF=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT"}
              ])
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(200, Jason.encode!(%{"Code" => 0}))
            end

          {"POST", "/connect/token"} ->
            Req.Test.json(conn, %{"access_token" => "tok-uc", "expires_in" => 3600})

          {"GET", "/0/api/OAuthHealthCheck"} ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "<!-- Incapsula WAF --><div>Blocked</div>")
        end
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, ""} = Creatio.DataService.custom_service(client, "Svc", "Ep", method: :options)
      assert_receive {:svc_req, "OPTIONS", "/0/rest/Svc/Ep", _, ""}

      assert {:ok, %{"ok" => true}} =
               Creatio.DataService.custom_service(client, "Svc", "Ep", ~s({"a":1}))

      assert_receive {:svc_req, "POST", "/0/rest/Svc/Ep", json_headers, ~s({"a":1})}

      assert List.keyfind(json_headers, "content-type", 0) ==
               {"content-type", "application/json; charset=utf-8"}

      assert {:ok, authed} = Auth.login_forms(client, "user", "good")
      assert_receive {:svc_req, "POST", "/ServiceModel/AuthService.svc/Login", login_headers, _}
      assert List.keyfind(login_headers, "accept", 0) == {"accept", "application/json"}
      assert authed.bpmcsrf == "valid_csrf"
      assert authed.cookie =~ "BPMCSRF=valid_csrf"

      assert {:error, %Error{code: 1, message: "Invalid credentials"}} =
               Auth.login_forms(client, "user", "bad")

      assert {:ok, _oauth_client, %{"access_token" => "tok-uc"}} =
               Auth.login_oauth(client,
                 client_id: "cid",
                 client_secret: "csec",
                 token_url: "HTTPS://id.crm.test/connect/token"
               )

      assert {:error, %Error{status: 200}} = Auth.oauth_health_check(client)
      assert Util.html_or_xml_markup?(%Req.Response{body: "  <!-- comment waf -->"})

      # 2-arity into: fun is status-gated and non-2xx errors are capped at 64 KB
      huge_err = String.duplicate("X", 100_000)

      stream_plug = fn conn ->
        case conn.request_path do
          "/err" ->
            Plug.Conn.send_resp(conn, 500, huge_err)

          "/waf" ->
            conn
            |> Plug.Conn.put_resp_content_type("text/html")
            |> Plug.Conn.send_resp(200, "<!-- waf --><html>blocked</html>")

          "/ok" ->
            Plug.Conn.send_resp(conn, 200, "small-ok")
        end
      end

      into_cb = fn {:data, chunk}, {req, resp} ->
        send(parent, {:into_chunk, chunk})
        {:cont, {req, %{resp | body: (resp.body || "") <> chunk}}}
      end

      assert {:error, %Error{status: 500, response: err_resp}} =
               Util.fetch_field_value(
                 Req.new(base_url: "https://crm.test"),
                 "/err",
                 into: into_cb,
                 req_options: [plug: stream_plug, retry: false]
               )

      assert byte_size(err_resp.body) == 65_536
      refute_received {:into_chunk, _}

      assert {:error, %Error{status: 200}} =
               Util.fetch_field_value(
                 Req.new(base_url: "https://crm.test"),
                 "/waf",
                 into: into_cb,
                 req_options: [plug: stream_plug, retry: false]
               )

      refute_received {:into_chunk, _}

      assert {:ok, "small-ok"} =
               Util.fetch_field_value(
                 Req.new(base_url: "https://crm.test"),
                 "/ok",
                 into: into_cb,
                 req_options: [plug: stream_plug, retry: false]
               )

      assert_receive {:into_chunk, "small-ok"}
    end
  end
end
