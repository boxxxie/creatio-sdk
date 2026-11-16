defmodule Creatio.Features.OData3LegacyEntitiesTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.ODataDSL

  alias Creatio.OData.Query

  @waf_html "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"
  @cursor_id1 "11111111-1111-1111-1111-111111111111"
  @cursor_id2 "22222222-2222-2222-2222-222222222222"
  @cursor_id3 "33333333-3333-3333-3333-333333333333"
  @next_page_url "https://mycreatio.com/0/ServiceModel/EntityDataService.svc/AccountCollection?$skiptoken=next"
  @waf_entity_id "00000000-0000-0000-0000-000000000001"

  @odata3_count_cases [
    {"path strategy plain text integer", [strategy: :path, format: :plain_text, count: 10], [],
     10},
    {"path strategy UTF-8 BOM plain text", [strategy: :path, format: :bom_plain_text, count: 123],
     [], 123},
    {"path strategy JSON integer body", [strategy: :path, format: :json_integer, count: 42], [],
     42},
    {"path strategy string integer inside d envelope",
     [strategy: :path, format: :d_count_int, count: "42"],
     [req_options: [headers: [{"x-count-check", "1"}]]], 42},
    {"path strategy integer inside d envelope",
     [strategy: :path, format: :d_count_int, count: 55], [], 55},
    {"path strategy __count inside d object",
     [strategy: :path, format: :d_dunder_count, count: "15"], [], 15},
    {"path strategy count object inside d envelope",
     [strategy: :path, format: :d_count_obj, count: 7], [], 7},
    {"path strategy nested count inside d object",
     [strategy: :path, format: :d_nested_count, count: 1], [], 1},
    {"path strategy IIS text/html plain text",
     [strategy: :path, format: :plain_text, count: "123", content_type: "text/html"], [], 123},
    {"query strategy using /$count query string",
     [strategy: :query, format: :plain_text, count: 77], [strategy: :query], 77}
  ]

  describe "OData 3 Querying & Verbose Headers" do
    scenario "lists entities from an OData 3 Collection with verbose accept headers" do
      @given odata3_collection("Contact", records: [%{"Id" => "1", "Name" => "Legacy Alice"}])
      @upon listing_odata3_entities("Contact", top: 5)
      @then entities_returned([%{"Id" => "1", "Name" => "Legacy Alice"}])
      @then odata3_verbose_headers_sent()
      @then query_parameters_mapped(top: 5)
    end

    scenario "handles bare list inside OData 3 d envelope" do
      @given odata3_collection("Account",
               envelope: :d_list,
               records: [%{"Id" => "acc-1", "Name" => "Legacy Corp"}]
             )
      @upon listing_odata3_entities("Account")
      @then entities_returned([%{"Id" => "acc-1", "Name" => "Legacy Corp"}])
    end

    scenario "maps count option to $inlinecount=allpages and returns count with records" do
      @given odata3_collection("Contact",
               count: 10,
               count_key: "__count",
               records: [%{"Id" => "1", "Name" => "Ada"}]
             )
      @upon listing_odata3_entities("Contact", count: true)
      @then counted_entities_returned(count: 10, records: [%{"Id" => "1", "Name" => "Ada"}])
      @then query_parameters_mapped(inlinecount: "allpages")

      @given odata3_collection("Account",
               count: "\uFEFF10",
               count_key: "__count",
               records: [%{"Id" => "2", "Name" => "BOM Corp"}]
             )
      @upon listing_odata3_entities("Account", count: true)
      @then counted_entities_returned(count: 10, records: [%{"Id" => "2", "Name" => "BOM Corp"}])
    end

    scenario "supports query-first list and list! with fluent Query structs" do
      @given odata3_collection("Contact", records: [%{"Id" => "1", "Name" => "Grace"}])
      @upon listing_odata3_entities(Query.new("Contact") |> Query.select(["Id", "Name"]),
              query_first: true
            )
      @then entities_returned([%{"Id" => "1", "Name" => "Grace"}])
      @upon listing_odata3_entities(Query.new("Contact") |> Query.select(["Id", "Name"]),
              query_first: true,
              bang: true
            )
      @then entities_returned([%{"Id" => "1", "Name" => "Grace"}])
    end
  end

  describe "OData 3 Single Entity, Navigation & Field Access" do
    scenario "fetches a single OData 3 entity by GUID and formats guid key literal" do
      @given odata3_entity("Contact", "1234-5678",
               record: %{"Id" => "1234-5678", "Name" => "Bob"}
             )
      @upon getting_odata3_entity("Contact", "{1234-5678}")
      @then entity_returned(%{"Id" => "1234-5678", "Name" => "Bob"})
      @then requested_odata3_entity_guid("Contact", "1234-5678")
      @then odata3_verbose_headers_sent()
      @upon getting_odata3_entity("Contact", "1234-5678", bang: true)
      @then entity_returned(%{"Id" => "1234-5678", "Name" => "Bob"})
    end

    scenario "retrieves OData 3 navigation properties and wrapped or raw field values" do
      @given odata3_navigation("Contact", "1", "Account",
               record: %{"Id" => "acc-9", "Name" => "Legacy Org"}
             )
      @given odata3_navigation("Contact", "1", "Activities",
               records: [%{"Id" => "act-1", "Title" => "Call"}]
             )
      @given odata3_field("Contact", "1", "Name", value: "Legacy Name")
      @given odata3_field("Contact", "1", "Name", value: "Raw Legacy Name", raw: true)
      @upon getting_odata3_navigation("Contact", "1", "Account")
      @then entity_returned(%{"Id" => "acc-9", "Name" => "Legacy Org"})
      @upon getting_odata3_navigation("Contact", "1", "Activities", bang: true)
      @then entities_returned([%{"Id" => "act-1", "Title" => "Call"}])
      @upon getting_odata3_field("Contact", "1", "Name")
      @then field_value_returned("Legacy Name")
      @upon getting_odata3_field("Contact", "1", "Name", bang: true)
      @then field_value_returned("Legacy Name")
      @upon getting_odata3_raw_field_value("Contact", "1", "Name")
      @then field_value_returned("Raw Legacy Name")
      @upon getting_odata3_raw_field_value("Contact", "1", "Name", bang: true)
      @then field_value_returned("Raw Legacy Name")

      @given odata3_navigation("Contact", "id-204", "Owner", status: 204)
      @given odata3_field("Contact", "id-204", "Photo", status: 204)
      @given odata3_field("Contact", "id-204", "Photo", status: 204, raw: true)
      @upon getting_odata3_navigation("Contact", "id-204", "Owner")
      @then entity_returned(nil)
      @upon getting_odata3_field("Contact", "id-204", "Photo")
      @then field_value_returned(nil)
      @upon getting_odata3_raw_field_value("Contact", "id-204", "Photo")
      @then field_value_returned(nil)
    end

    scenario "forwards headers and Range 206 on raw OData 3 downloads, enforces decode_body false, and gates into: writes to 2xx" do
      @given temp_file_path(:o3_ok)
      @given temp_file_path(:o3_err)

      @given odata3_field("SysFile", "1", "Data",
               raw: true,
               content_type: "application/json",
               raw_body: ~s({"raw":"bytes"})
             )
      @upon getting_odata3_raw_field_value("SysFile", "1", "Data")
      @then field_value_returned(~s({"raw":"bytes"}))
      @upon getting_odata3_raw_field_value("SysFile", "1", "Data",
              headers: [{"x-trace", "o3-kw"}],
              req_options: [decode_body: true]
            )
      @then field_value_returned(~s({"raw":"bytes"}))
      @then last_request_header_was("x-trace", "o3-kw")

      @given odata3_field("SysFile", "2", "Data",
               raw: true,
               status: 206,
               content_type: "application/octet-stream",
               headers: [{"content-range", "bytes 0-3/100"}],
               raw_body: "hello"
             )
      @upon getting_odata3_raw_field_value("SysFile", "2", "Data",
              headers: [{"range", "bytes=0-3"}]
            )
      @then field_value_returned("hello")
      @upon getting_odata3_raw_field_value_to_temp_file(:o3_ok, "SysFile", "2", "Data", %{
              facade: true,
              headers: %{"range" => "bytes=0-3", "x-trace" => "o3-map"},
              req_options: [decode_body: true, params: %{"from_req" => "o3"}],
              select: ["Data"]
            })
      @then temp_file_written(:o3_ok, "hello")
      @then last_request_header_was("x-trace", "o3-map")
      @then last_request_header_was("range", "bytes=0-3")
      @then query_parameters_mapped(select: "Data", from_req: "o3")

      @given odata3_field("AccountFile", "err-500", "Data",
               raw: true,
               status: 500,
               content_type: "application/json",
               raw_body: Jason.encode!(%{"error" => %{"message" => "Server boom"}})
             )
      @upon getting_odata3_raw_field_value_to_temp_file(:o3_err, "AccountFile", "err-500", "Data")
      @then operation_failed_with(status: 500, message: "Server boom")
      @then temp_file_not_created(:o3_err)
    end
  end

  describe "OData 3 Counting" do
    scenario "counts OData 3 entities across all supported payload formats and strategies" do
      @upon counting_odata3_entities_matrix("Contact", @odata3_count_cases)
      @then all_count_cases_matched()
    end

    scenario "records query-strategy /$count URL format without double question marks" do
      @given odata3_count_endpoint("Contact", strategy: :query, format: :plain_text, count: 33)
      @upon counting_odata3_entities("Contact", strategy: :query)
      @then count_returned(33)
      @then odata3_query_count_strategy_used("Contact")

      @upon counting_odata3_entities("Contact", strategy: :query, filter: "Active eq true")
      @then count_returned(33)
      @then last_request_query_string_was("/$count&%24filter=Active+eq+true")
    end

    scenario "counts OData 3 entities with Query structs, map options, facade delegation, and bang variant" do
      @given odata3_count_endpoint("Contact", strategy: :path, format: :plain_text, count: 19)
      @upon counting_odata3_entities("Contact", bang: true)
      @then count_returned(19)
      @upon counting_odata3_entities(Query.new("Contact") |> Query.filter_eq("Active", true), %{
              "strategy" => :path
            })
      @then count_returned(19)

      @given odata3_count_endpoint("Contact", strategy: :query, format: :plain_text, count: 11)
      @upon counting_odata3_entities(Query.new("Contact"),
              query_first: true,
              facade: true,
              strategy: :query
            )
      @then count_returned(11)
    end

    scenario "returns error with response metadata when OData 3 count response is invalid" do
      @given odata3_count_endpoint("Contact",
               strategy: :path,
               format: :plain_text,
               count: "invalid"
             )
      @upon counting_odata3_entities("Contact")
      @then operation_failed_with(message: "Failed to parse count response: invalid")

      @given odata3_count_endpoint("Contact",
               strategy: :path,
               format: :d_count_int,
               count: "not-a-number"
             )
      @upon counting_odata3_entities("Contact")
      @then operation_failed_with(status: 200, response_status: 200)

      @given odata3_count_endpoint("Account",
               strategy: :path,
               format: :plain_text,
               count: "503 Service Unavailable"
             )
      @upon counting_odata3_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata3_count_endpoint("Account",
               strategy: :path,
               format: :plain_text,
               count: "-1"
             )
      @upon counting_odata3_entities("Account")
      @then operation_failed_with(status: 200)
    end
  end

  describe "OData 3 Mutations & Streaming" do
    scenario "creates, updates, and deletes OData 3 entities" do
      @given odata3_creatable_entity("Contact",
               body: %{"d" => %{"Id" => "new-1", "Name" => "Created"}}
             )
      @upon creating_odata3_entity("Contact", %{"Name" => "Created"})
      @then entity_created_with(%{"Id" => "new-1", "Name" => "Created"})
      @upon creating_odata3_entity("Contact", %{"Name" => "Created"}, bang: true)
      @then entity_created_with(%{"Id" => "new-1", "Name" => "Created"})

      @given odata3_creatable_entity("Account",
               status: 200,
               body: %{"d" => %{"Id" => "new-2", "Name" => "OK Envelope"}}
             )
      @upon creating_odata3_entity("Account", %{"Name" => "OK Envelope"})
      @then entity_created_with(%{"Id" => "new-2", "Name" => "OK Envelope"})

      @given odata3_creatable_entity("Lead",
               status: 200,
               body: %{"Id" => "new-3", "Name" => "Flat 200"}
             )
      @upon creating_odata3_entity("Lead", %{"Name" => "Flat 200"})
      @then entity_created_with(%{"Id" => "new-3", "Name" => "Flat 200"})

      @given odata3_updatable_entity("Contact", "1")
      @upon updating_odata3_entity("Contact", "1", %{"Name" => "Updated"})
      @then mutation_succeeded()
      @upon updating_odata3_entity("Contact", "1", %{"Name" => "Updated"}, bang: true)
      @then bang_mutation_succeeded()

      @given odata3_updatable_entity("Contact", "2",
               status: 200,
               body: %{"d" => %{"Id" => "2", "Name" => "Patched"}}
             )
      @upon updating_odata3_entity("Contact", "2", %{"Name" => "Patched"})
      @then entity_returned(%{"Id" => "2", "Name" => "Patched"})
      @upon updating_odata3_entity("Contact", "2", %{"Name" => "Patched"}, bang: true)
      @then entity_returned(%{"Id" => "2", "Name" => "Patched"})

      @given odata3_deletable_entity("Contact", "1")
      @upon deleting_odata3_entity("Contact", "1")
      @then mutation_succeeded()
      @upon deleting_odata3_entity("Contact", "1", bang: true)
      @then bang_mutation_succeeded()

      @given odata3_deletable_entity("Contact", "2", status: 200)
      @upon deleting_odata3_entity("Contact", "2")
      @then mutation_succeeded()
    end

    scenario "streams OData 3 entities across pages with both regular and bang streams" do
      @given odata3_paginated_collection("Contact", [
               %{"Id" => "1"},
               %{"Id" => "2"},
               %{"Id" => "3"}
             ])
      @upon streaming_odata3_entities("Contact", page_size: 2)
      @then streamed_entities_match([
              {:ok, %{"Id" => "1"}},
              {:ok, %{"Id" => "2"}},
              {:ok, %{"Id" => "3"}}
            ])
      @then query_parameters_mapped(skip: 2, top: 2)

      @upon streaming_odata3_entities(Query.new("Contact"), query_first: true, bang: true)
      @then streamed_entities_match([%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}])

      @given odata3_paginated_collection("Account", [])
      @upon streaming_odata3_entities("Account", page_size: "2", skip: "0")
      @then streamed_entities_match([])
    end

    scenario "inherits initial $skip offset when streaming an OData 3 Query struct" do
      @given odata3_paginated_collection("Contact", [
               %{"Id" => "1"},
               %{"Id" => "2"},
               %{"Id" => "3"}
             ])
      @upon streaming_odata3_entities(
              Query.new("Contact") |> Query.skip(2),
              query_first: true,
              page_size: 2
            )
      @then streamed_entities_match([{:ok, %{"Id" => "3"}}])
      @then query_parameters_mapped(skip: 2, top: 2)
    end

    scenario "paginates OData 3 streams using keyset cursor_field and d.__next without $skip" do
      @given odata3_pages("Contact", fn req, _idx ->
               filter = req.query_params["$filter"] || ""

               records =
                 if String.contains?(filter, "Id gt guid'#{@cursor_id1}'") do
                   [%{"Id" => @cursor_id2}, %{"Id" => @cursor_id3}]
                 else
                   []
                 end

               {200, %{"d" => %{"results" => records}}}
             end)
      @upon streaming_odata3_entities("Contact",
              page_size: 2,
              cursor_field: "Id",
              after_cursor: @cursor_id1,
              filter: "Active eq true"
            )
      @then streamed_entities_match([
              {:ok, %{"Id" => @cursor_id2}},
              {:ok, %{"Id" => @cursor_id3}}
            ])
      @then last_request_omitted_query_param("$skip")
      @then query_parameters_mapped(
              orderby: "Id asc",
              filter: "(Active eq true) and (Id gt guid'#{@cursor_id3}')"
            )

      @upon streaming_odata3_entities("Contact",
              page_size: 2,
              cursor_field: "Id",
              after_cursor: @cursor_id1,
              filter: "Active eq true",
              bang: true
            )
      @then streamed_entities_match([%{"Id" => @cursor_id2}, %{"Id" => @cursor_id3}])

      @given odata3_pages("Account", [
               {200, %{"d" => %{"results" => [%{"Id" => "o3-1"}], "__next" => @next_page_url}}},
               {200, %{"d" => %{"results" => [%{"Id" => "o3-2"}], "__next" => ""}}}
             ])
      @upon streaming_odata3_entities("Account", page_size: 10, bang: true)
      @then streamed_entities_match([%{"Id" => "o3-1"}, %{"Id" => "o3-2"}])
      @then query_parameters_mapped("$skiptoken": "next")
    end
  end

  describe "OData 3 IIS Content-Type & Error Resilience" do
    scenario "decodes IIS text/html BOM JSON responses and rejects WAF HTML and corrupt payloads" do
      @given odata3_collection("Contact",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"d" => %{"results" => [%{"Id" => "o3-1"}]}})
             )
      @upon listing_odata3_entities("Contact")
      @then entities_returned([%{"Id" => "o3-1"}])

      @given odata3_entity("Contact", "o3-1",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"d" => %{"Id" => "o3-1"}})
             )
      @upon getting_odata3_entity("Contact", "o3-1")
      @then entity_returned(%{"Id" => "o3-1"})

      @given odata3_count_endpoint("Contact",
               strategy: :path,
               content_type: "text/html",
               raw_body: "\uFEFF19"
             )
      @upon counting_odata3_entities("Contact")
      @then count_returned(19)

      @given odata3_collection("Account", content_type: "text/html", raw_body: @waf_html)
      @upon listing_odata3_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata3_entity("Account", @waf_entity_id,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_odata3_entity("Account", @waf_entity_id)
      @then operation_failed_with(status: 200)

      @given odata3_navigation("Account", @waf_entity_id, "Owner",
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_odata3_navigation("Account", @waf_entity_id, "Owner")
      @then operation_failed_with(status: 200)

      @given odata3_field("Account", @waf_entity_id, "Name",
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_odata3_field("Account", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)

      @given odata3_creatable_entity("Account",
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon creating_odata3_entity("Account", %{"Name" => "X"})
      @then operation_failed_with(status: 200)

      @given odata3_updatable_entity("Account", @waf_entity_id,
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon updating_odata3_entity("Account", @waf_entity_id, %{"Name" => "Y"})
      @then operation_failed_with(status: 200)

      @given odata3_deletable_entity("Account", @waf_entity_id,
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon deleting_odata3_entity("Account", @waf_entity_id)
      @then operation_failed_with(status: 200)

      @given odata3_count_endpoint("Account",
               strategy: :path,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon counting_odata3_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata3_collection("Lead", body: %{"error" => %{"message" => "boom"}})
      @given odata3_entity("Lead", @waf_entity_id, body: %{"error" => %{"message" => "boom"}})
      @given odata3_entity("Lead", "nil-id", body: %{"d" => nil})
      @upon listing_odata3_entities("Lead")
      @then operation_failed_with(status: 200)
      @upon getting_odata3_entity("Lead", @waf_entity_id)
      @then operation_failed_with(status: 200)
      @upon getting_odata3_entity("Lead", "nil-id")
      @then operation_failed_with(status: 200)

      @given odata3_updatable_entity("Lead", @waf_entity_id,
               status: 200,
               content_type: "application/json",
               raw_body: "{broken"
             )
      @given odata3_field("Lead", @waf_entity_id, "Name",
               content_type: "application/json",
               raw_body: "{broken"
             )
      @upon updating_odata3_entity("Lead", @waf_entity_id, %{"Name" => "X"},
              return: :representation
            )
      @then operation_failed_with(status: nil)
      @upon getting_odata3_field("Lead", @waf_entity_id, "Name")
      @then operation_failed_with(status: nil)

      @given odata3_updatable_entity("Lead", @waf_entity_id,
               status: 200,
               content_type: "text/plain",
               raw_body: "Gateway Timeout"
             )
      @given odata3_field("Lead", @waf_entity_id, "Name",
               content_type: "text/plain",
               raw_body: "{broken"
             )
      @upon updating_odata3_entity("Lead", @waf_entity_id, %{"Name" => "X"},
              return: :representation
            )
      @then operation_failed_with(status: 200)
      @upon getting_odata3_field("Lead", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)
    end
  end
end
