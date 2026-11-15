defmodule Creatio.UtilTest do
  use ExUnit.Case, async: true

  alias Creatio.Util

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
    test "extracts header values case-insensitively from maps and tuple lists" do
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
    end
  end

  describe "normalize_json_response/1" do
    test "decodes JSON objects and arrays delivered with text/html or UTF-8 BOM" do
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
    end

    test "preserves HTML, non-JSON plain text, and already decoded bodies" do
      html_resp = %Req.Response{status: 200, body: "<html><body>WAF</body></html>"}
      assert Util.normalize_json_response(html_resp) == html_resp

      plain_resp = %Req.Response{status: 200, body: "plain ok response"}
      assert Util.normalize_json_response(plain_resp) == plain_resp

      map_resp = %Req.Response{status: 200, body: %{"ok" => true}}
      assert Util.normalize_json_response(map_resp) == map_resp
    end
  end

  describe "html_or_xml_response?/1" do
    test "detects HTML/XML interstitials and Imperva Incapsula WAF pages" do
      waf_resp = %Req.Response{
        status: 200,
        headers: %{"content-type" => ["text/html"]},
        body: "<iframe id=\"main-iframe\" src=\"/_Incapsula_Resource?SWUDNSAI=31\"></iframe>"
      }

      assert Util.html_or_xml_response?(waf_resp)

      doctype_resp = %Req.Response{
        status: 200,
        headers: %{"content-type" => ["text/plain"]},
        body: "\uFEFF  <!DOCTYPE html><html><body>Login</body></html>"
      }

      assert Util.html_or_xml_response?(doctype_resp)

      xml_resp = %Req.Response{
        status: 200,
        headers: %{"content-type" => ["application/xml; charset=utf-8"]},
        body: "plain non-json text"
      }

      assert Util.html_or_xml_response?(xml_resp)
    end

    test "returns false for JSON structures and non-HTML plain text" do
      assert Util.html_or_xml_response?(%Req.Response{
               status: 200,
               headers: %{"content-type" => ["text/html"]},
               body: %{"Id" => "1"}
             }) == false

      assert Util.html_or_xml_response?(%Req.Response{
               status: 200,
               headers: %{"content-type" => ["text/plain"]},
               body: "plain ok response"
             }) == false
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

      # Keyset cursor escaping single quotes when filter is nil or "", plus non-numeric page_size fallback
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
                   page_size: "invalid",
                   cursor_field: "Name",
                   after_cursor: "O'Brien",
                   filter: ""
                 },
                 string_cursor_fun
               )
               |> Enum.to_list()

      assert_receive {:cursor_filter, "Name gt 'O''Brien'", 100}

      # Integer cursor and filter: nil branch
      int_cursor_fun = fn _client, _entity, opts ->
        send(parent, {:int_cursor, Keyword.get(opts, :filter)})

        if Keyword.get(opts, :filter) == "Seq gt 41" do
          {:ok, [%{"Seq" => 42}, %{"Seq" => 43}]}
        else
          {:ok, []}
        end
      end

      assert [%{"Seq" => 42}, %{"Seq" => 43}] =
               Util.paginate_stream!(
                 client,
                 "Contact",
                 [page_size: 2, cursor_field: "Seq", after_cursor: 41],
                 :odata4,
                 int_cursor_fun
               )
               |> Enum.to_list()

      assert_receive {:int_cursor, "Seq gt 41"}
      assert_receive {:int_cursor, "Seq gt 43"}
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

    test "clean_guid/1 strips guid'...', braces, quotes, and whitespace" do
      id = "a1b2c3d4-0000-0000-0000-000000000001"
      assert Util.clean_guid(" guid'#{id}' ") == id
      assert Util.clean_guid("GUID'{#{id}}'") == id
      assert Util.clean_guid("{'#{id}'}") == id
      assert Util.clean_guid("'#{id}'") == id
      assert Util.clean_guid(id) == id
    end

    test "response_header/2 handles malformed list entries, empty values, non-binary items, and non-collections" do
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

    test "normalize_json_response/1 and html_or_xml_response?/1 handle malformed JSON and empty/nil bodies" do
      bad_json = %Req.Response{status: 200, body: "{not json"}
      assert Util.normalize_json_response(bad_json) == bad_json

      nil_resp = %Req.Response{
        status: 200,
        body: nil,
        headers: %{"content-type" => ["text/html"]}
      }

      assert Util.normalize_json_response(nil_resp) == nil_resp
      assert Util.html_or_xml_response?(nil_resp) == false

      empty_html = %Req.Response{
        status: 200,
        body: "   ",
        headers: %{"content-type" => ["text/html"]}
      }

      assert Util.html_or_xml_response?(empty_html) == false
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

    test "clean_guid/1 strips GUID wrappers and rejects traversal or injection characters" do
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
  end
end
