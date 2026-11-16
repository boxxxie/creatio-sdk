defmodule Creatio.Features.ODataEntitiesTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.ODataDSL

  alias Creatio.OData.Query

  @waf_html "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"
  @large_waf_html "<html><body>" <> String.duplicate("waf-challenge ", 150) <> "</body></html>"
  @sample_guid "12345678-1234-1234-1234-123456789abc"
  @location_uri "https://crm.test/0/odata/Contact({12345678-1234-1234-1234-123456789abc})"
  @cursor_id1 "11111111-1111-1111-1111-111111111111"
  @cursor_id2 "22222222-2222-2222-2222-222222222222"
  @cursor_id3 "33333333-3333-3333-3333-333333333333"
  @cursor_ts "2026-01-01T00:00:00Z"
  @waf_entity_id "00000000-0000-0000-0000-000000000001"

  @count_format_cases [
    {"plain text integer", [format: :plain_text, count: 42], [], 42},
    {"UTF-8 BOM plain text integer", [format: :bom_plain_text, count: 22_345], [], 22_345},
    {"JSON integer body", [format: :json_integer, count: 42], [], 42},
    {"OData count JSON envelope", [format: :odata_count, count: 15], [], 15},
    {"OData count string JSON value", [format: :odata_count_string, count: 25], [], 25},
    {"value string JSON payload", [format: :value_string, count: 50], [], 50},
    {"top-zero strategy with value and odata.count",
     [strategy: :top_zero, format: :value_and_count, count: {42, 1}], [strategy: :top_zero], 1},
    {"path strategy preferring odata.count when present alongside integer value",
     [format: :value_and_count, count: {42, 1}], [], 1}
  ]

  describe "OData 4 Querying & Listing" do
    scenario "lists entities from an OData collection" do
      @given odata_collection("Contact",
               records: [
                 %{"Id" => "1", "Name" => "Alice"},
                 %{"Id" => "2", "Name" => "Bob"}
               ]
             )
      @upon listing_entities("Contact")
      @then entities_returned([
              %{"Id" => "1", "Name" => "Alice"},
              %{"Id" => "2", "Name" => "Bob"}
            ])
    end

    scenario "handles bare array collection responses" do
      @given odata_collection("Contact",
               bare_array: true,
               records: [%{"Id" => "1", "Name" => "Bare"}]
             )
      @upon listing_entities("Contact")
      @then entities_returned([%{"Id" => "1", "Name" => "Bare"}])
    end

    scenario "maps keyword query options into standard OData 4 query parameters" do
      @given odata_collection("Contact", records: [%{"Id" => "1", "Name" => "VIP"}])
      @upon listing_entities("Contact",
              select: ["Id", "Name"],
              filter: "Active eq true",
              orderby: "Name asc",
              top: 10,
              skip: 5,
              expand: "Account"
            )
      @then entities_returned([%{"Id" => "1", "Name" => "VIP"}])
      @then query_parameters_mapped(
              select: "Id,Name",
              filter: "Active eq true",
              orderby: "Name asc",
              top: 10,
              skip: 5,
              expand: "Account"
            )
    end

    scenario "lists and executes fluent Query structs including query-first and bang variants" do
      @given odata_collection("Contact", count: 42, records: [%{"Id" => "1", "Name" => "Ada"}])
      @upon listing_entities(
              Query.new("Contact")
              |> Query.select(["Id", "Name"])
              |> Query.filter_eq("Active", true)
              |> Query.top(3),
              query_first: true
            )
      @then entities_returned([%{"Id" => "1", "Name" => "Ada"}])
      @upon listing_entities(
              Query.new("Contact")
              |> Query.select(["Id", "Name"])
              |> Query.filter_eq("Active", true)
              |> Query.top(3),
              query_first: true,
              bang: true
            )
      @then entities_returned([%{"Id" => "1", "Name" => "Ada"}])
      @upon executing_query(
              Query.new("Contact") |> Query.select(["Id", "Name"]),
              count: true
            )
      @then counted_entities_returned(count: 42, records: [%{"Id" => "1", "Name" => "Ada"}])
      @upon executing_query(
              Query.new("Contact") |> Query.select(["Id", "Name"]),
              query_first: true,
              bang: true
            )
      @then entities_returned([%{"Id" => "1", "Name" => "Ada"}])
    end

    scenario "executes query with UTF-8 BOM string @odata.count" do
      @given odata_collection("Contact", count: "\uFEFF42", records: [%{"Id" => "1"}])
      @upon executing_query(Query.new("Contact"), count: true)
      @then counted_entities_returned(count: 42, records: [%{"Id" => "1"}])
    end

    scenario "supports listing through an unconfigured raw HTTP request" do
      @given odata_collection("Contact", records: [%{"Id" => "raw-1", "Name" => "Raw"}])
      @given raw_http_client()
      @upon listing_entities("Contact")
      @then entities_returned([%{"Id" => "raw-1", "Name" => "Raw"}])
    end

    scenario "honors map options and count: false override over Query.count(true)" do
      @given odata_collection("Contact", count: 1, records: [%{"Id" => 1}])
      @upon listing_entities(Query.new("Contact") |> Query.count(true), %{count: false})
      @then entities_returned([%{"Id" => 1}])
      @then last_request_omitted_query_param("$count")
    end
  end

  describe "OData 4 Single Entity, Navigation & Field Access" do
    scenario "fetches a single entity by GUID and normalizes braces" do
      @given odata_entity("Contact", @sample_guid,
               record: %{"Id" => @sample_guid, "Name" => "John"}
             )
      @upon getting_entity("Contact", "{#{@sample_guid}}")
      @then entity_returned(%{"Id" => @sample_guid, "Name" => "John"})
      @then requested_odata_entity_id("Contact", @sample_guid)
      @upon getting_entity("Contact", @sample_guid, bang: true)
      @then entity_returned(%{"Id" => @sample_guid, "Name" => "John"})
    end

    scenario "returns structured error when entity does not exist" do
      @given odata_missing_entity("Contact", "missing-id",
               status: 404,
               code: "404",
               message: "Contact not found"
             )
      @upon getting_entity("Contact", "missing-id")
      @then operation_failed_with(status: 404, code: "404", message: "Contact not found")
    end

    scenario "retrieves single and collection navigation properties" do
      @given odata_navigation("Contact", "1", "Account",
               record: %{"Id" => "acc-1", "Name" => "Acme Corp"}
             )
      @given odata_navigation("Contact", "1", "Activities",
               records: [%{"Id" => "act-1", "Title" => "Follow up"}]
             )
      @upon getting_navigation("Contact", "1", "Account")
      @then entity_returned(%{"Id" => "acc-1", "Name" => "Acme Corp"})
      @upon getting_navigation("Contact", "1", "Activities", bang: true)
      @then entities_returned([%{"Id" => "act-1", "Title" => "Follow up"}])
    end

    scenario "retrieves wrapped and raw entity field values and returns nil on 204 No Content" do
      @given odata_field("Contact", "1", "Name", value: "Alice")
      @given odata_field("Contact", "1", "Name", value: "Alice", raw: true)
      @upon getting_field("Contact", "1", "Name")
      @then field_value_returned("Alice")
      @upon getting_raw_field_value("Contact", "1", "Name")
      @then field_value_returned("Alice")
      @upon getting_field("Contact", "1", "Name", bang: true)
      @then field_value_returned("Alice")
      @upon getting_raw_field_value("Contact", "1", "Name", bang: true)
      @then field_value_returned("Alice")

      @given odata_navigation("Contact", "id-204", "Owner", status: 204)
      @given odata_field("Contact", "id-204", "Photo", status: 204)
      @given odata_field("Contact", "id-204", "Photo", status: 204, raw: true)
      @upon getting_navigation("Contact", "id-204", "Owner")
      @then entity_returned(nil)
      @upon getting_field("Contact", "id-204", "Photo")
      @then field_value_returned(nil)
      @upon getting_raw_field_value("Contact", "id-204", "Photo")
      @then field_value_returned(nil)
    end

    scenario "forwards headers and query params on raw field downloads, enforces decode_body false, and gates into: writes to 2xx" do
      @given temp_file_path(:o4_ok)
      @given temp_file_path(:o4_err)
      @given temp_file_path(:o4_204)
      @given temp_file_path(:waf_small)
      @given temp_file_path(:waf_large)

      @given odata_field("SysFile", "1", "Data",
               raw: true,
               content_type: "application/json",
               raw_body: ~s({"raw":"bytes"})
             )
      @upon getting_raw_field_value("SysFile", "1", "Data")
      @then field_value_returned(~s({"raw":"bytes"}))
      @upon getting_raw_field_value("SysFile", "1", "Data", %{
              headers: %{"x-trace" => "o4-map"},
              req_options: [decode_body: true]
            })
      @then field_value_returned(~s({"raw":"bytes"}))
      @then last_request_header_was("x-trace", "o4-map")

      @given odata_field("SysFile", "2", "Data",
               raw: true,
               status: 206,
               content_type: "application/octet-stream",
               headers: [{"content-range", "bytes 0-4/100"}],
               raw_body: "hello"
             )
      @upon getting_raw_field_value("SysFile", "2", "Data", headers: [{"range", "bytes=0-4"}])
      @then field_value_returned("hello")
      @upon getting_raw_field_value_to_temp_file(:o4_ok, "SysFile", "2", "Data",
              facade: true,
              headers: [{"range", "bytes=0-4"}, {"x-trace", "o4-kw"}],
              req_options: [decode_body: true, params: %{"from_req" => "yes"}],
              params: %{"download" => "1"},
              select: ["Name"]
            )
      @then temp_file_written(:o4_ok, "hello")
      @then last_request_header_was("x-trace", "o4-kw")
      @then last_request_header_was("range", "bytes=0-4")
      @then query_parameters_mapped(select: "Name", download: "1", from_req: "yes")

      @given odata_field("SysFile", "err-404", "Data",
               raw: true,
               status: 404,
               content_type: "application/json",
               raw_body: Jason.encode!(%{"error" => %{"message" => "File missing"}})
             )
      @upon getting_raw_field_value_to_temp_file(:o4_err, "SysFile", "err-404", "Data")
      @then operation_failed_with(status: 404, message: "File missing")
      @then temp_file_not_created(:o4_err)

      @given odata_field("SysFile", "empty-204", "Data", raw: true, status: 204)
      @upon getting_raw_field_value_to_temp_file(:o4_204, "SysFile", "empty-204", "Data")
      @then field_value_returned(nil)
      @then temp_file_not_created(:o4_204)

      @given odata_field("SysFile", "waf-s", "Data",
               raw: true,
               content_type: "text/html",
               raw_body: "<html><iframe src=\"/_Incapsula_Resource\"></iframe></html>"
             )
      @upon getting_raw_field_value_to_temp_file(:waf_small, "SysFile", "waf-s", "Data")
      @then operation_failed_with(status: 200)
      @then temp_file_not_created(:waf_small)

      @given odata_field("SysFile", "waf-l", "Data",
               raw: true,
               content_type: "text/html",
               raw_body: @large_waf_html
             )
      @upon getting_raw_field_value_to_temp_file(:waf_large, "SysFile", "waf-l", "Data")
      @then operation_failed_with(status: 200)
      @then temp_file_not_created(:waf_large)
    end
  end

  describe "OData 4 Counting" do
    scenario "counts entities across all supported payload formats and strategies" do
      @upon counting_entities_matrix("Contact", @count_format_cases)
      @then all_count_cases_matched()
    end

    scenario "counts entities with Query structs, map options, facade delegation, and bang variant" do
      @given odata_count_endpoint("Contact", format: :plain_text, count: 77)
      @upon counting_entities("Contact", bang: true)
      @then count_returned(77)

      @upon counting_entities(Query.new("Contact") |> Query.filter_eq("Active", true), %{
              "strategy" => :path
            })
      @then count_returned(77)

      @upon counting_entities(Query.new("Contact"),
              query_first: true,
              facade: true,
              strategy: :path
            )
      @then count_returned(77)

      @given odata_collection("Contact", count: 9, records: [])
      @upon counting_entities(Query.new("Contact"), query_first: true, strategy: :top_zero)
      @then count_returned(9)
    end

    scenario "returns errors when count endpoint lacks @odata.count or returns invalid integers" do
      @given odata_collection("Contact", records: [])
      @upon counting_entities("Contact", strategy: :top_zero)
      @then operation_failed_with(message: "No @odata.count found in response")

      @given odata_count_endpoint("Contact", format: :plain_text, count: "invalid")
      @upon counting_entities("Contact")
      @then operation_failed_with(message: "Failed to parse count response: invalid")

      @given odata_count_endpoint("Account",
               format: :plain_text,
               count: "503 Service Unavailable"
             )
      @upon counting_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata_count_endpoint("Account", format: :plain_text, count: "404 Not Found")
      @upon counting_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata_count_endpoint("Account", format: :plain_text, count: "2026-11-15 Error")
      @upon counting_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata_count_endpoint("Account", format: :plain_text, count: "-1")
      @upon counting_entities("Account")
      @then operation_failed_with(status: 200)

      @given odata_collection("Contact",
               status: 500,
               error: %{"error" => %{"code" => "ServerError", "message" => "Count failed"}}
             )
      @upon counting_entities("Contact", strategy: :top_zero)
      @then operation_failed_with(status: 500, code: "ServerError", message: "Count failed")
    end
  end

  describe "OData 4 Mutations & Field Uploads" do
    scenario "creates entities with Creatio session headers and return: :minimal 204 responses" do
      @given odata_creatable_entity("Contact", assigned_id: "created-1")
      @upon creating_entity("Contact", %{"Name" => "New Lead"})
      @then entity_created_with(%{"Id" => "created-1", "Name" => "New Lead"})
      @upon creating_entity("Contact", %{"Name" => "New Lead"}, bang: true)
      @then entity_created_with(%{"Id" => "created-1", "Name" => "New Lead"})

      @given odata_creatable_entity("Contact",
               status: 204,
               odata_entityid: "https://crm.test/0/odata/Contact(abc)"
             )
      @upon creating_entity("Contact", %{"Name" => "Min"}, return: :minimal)
      @then entity_created_with(%{
              "@odata.id" => "https://crm.test/0/odata/Contact(abc)",
              "Id" => "abc"
            })
      @then last_request_header_was("prefer", "return=minimal")

      @given odata_creatable_entity("Account", status: 204, location: @location_uri)
      @upon creating_entity("Account", %{"Name" => "Loc"}, return: :minimal)
      @then entity_created_with(%{"@odata.id" => @location_uri, "Id" => @sample_guid})

      @given odata_creatable_entity("OrderItem",
               status: 204,
               odata_entityid: "https://crm.test/0/odata/OrderItem(OrderId=1,ItemId=2)"
             )
      @upon creating_entity("OrderItem", %{"Name" => "X"}, return: :minimal)
      @then entity_created_with(%{
              "@odata.id" => "https://crm.test/0/odata/OrderItem(OrderId=1,ItemId=2)"
            })
      @then entity_created_missing_key("Id")
    end

    scenario "updates entity returning 204 No Content, return: :minimal, or 200 JSON body" do
      @given odata_updatable_entity("Contact", "1")
      @upon updating_entity("Contact", "1", %{"Name" => "Updated"})
      @then mutation_succeeded()
      @upon updating_entity("Contact", "1", %{"Name" => "Updated"}, bang: true)
      @then bang_mutation_succeeded()
      @upon updating_entity("Contact", "1", %{"Name" => "Min2"}, return: :minimal)
      @then mutation_succeeded()
      @then last_request_header_was("prefer", "return=minimal")

      @given odata_updatable_entity("Contact", "2",
               status: 200,
               body: %{"Id" => "2", "Name" => "Updated Copy"}
             )
      @upon updating_entity("Contact", "2", %{"Name" => "Updated Copy"})
      @then entity_returned(%{"Id" => "2", "Name" => "Updated Copy"})
      @upon updating_entity("Contact", "2", %{"Name" => "Updated Copy"}, bang: true)
      @then entity_returned(%{"Id" => "2", "Name" => "Updated Copy"})
    end

    scenario "deletes entities on 204 or 200 response" do
      @given odata_deletable_entity("Contact", "1")
      @upon deleting_entity("Contact", "1")
      @then mutation_succeeded()
      @upon deleting_entity("Contact", "1", bang: true)
      @then bang_mutation_succeeded()

      @given odata_deletable_entity("Contact", "2", status: 200)
      @upon deleting_entity("Contact", "2")
      @then mutation_succeeded()
    end

    scenario "updates binary stream fields, scalar fields, and deletes fields" do
      @given odata_updatable_field("Contact", "1", "Photo")
      @upon updating_entity_field("Contact", "1", "Photo", <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A>>)
      @then binary_field_upload_verified(
              "Contact",
              "1",
              "Photo",
              <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A>>
            )

      @given odata_updatable_field("Contact", "1", "DoNotUseEmail")
      @upon updating_entity_field("Contact", "1", "DoNotUseEmail", true)
      @then scalar_field_update_verified("Contact", "1", "DoNotUseEmail", true)

      @given odata_updatable_field("Contact", "1", "Name")
      @upon updating_entity_field("Contact", "1", "Name", "Jane Doe")
      @then scalar_field_update_verified("Contact", "1", "Name", "Jane Doe")

      @given odata_updatable_field("SysFile", "1", "Data")
      @upon updating_entity_field_with_stream("SysFile", "1", "Data", ["chunk1", "chunk2"])
      @then binary_field_upload_verified("SysFile", "1", "Data", "chunk1chunk2")

      @given odata_updatable_field("Contact", "id-1", "Photo")
      @upon updating_entity_field_with_io_stream(
              "Contact",
              "id-1",
              "Photo",
              "binary-stream-content",
              6
            )
      @then binary_field_upload_verified("Contact", "id-1", "Photo", "binary-stream-content")

      @given odata_deletable_field("Contact", "1", "Photo")
      @upon deleting_entity_field("Contact", "1", "Photo")
      @then field_delete_verified("Contact", "1", "Photo")

      @given odata_deletable_field("Contact", "2", "Photo", status: 200)
      @upon deleting_entity_field("Contact", "2", "Photo")
      @then field_delete_verified("Contact", "2", "Photo")
    end
  end

  describe "OData 4 Streaming Pagination" do
    scenario "lazily paginates across multiple pages until exhaustion" do
      @given odata_paginated_collection("Contact", [
               %{"Id" => "1", "Name" => "Page1-A"},
               %{"Id" => "2", "Name" => "Page1-B"},
               %{"Id" => "3", "Name" => "Page2-A"}
             ])
      @upon streaming_entities("Contact", page_size: 2)
      @then streamed_entities_match([
              {:ok, %{"Id" => "1", "Name" => "Page1-A"}},
              {:ok, %{"Id" => "2", "Name" => "Page1-B"}},
              {:ok, %{"Id" => "3", "Name" => "Page2-A"}}
            ])
      @then query_parameters_mapped(skip: 3, top: 2)

      @upon streaming_entities("Contact", page_size: 2, bang: true)
      @then streamed_entities_match([
              %{"Id" => "1", "Name" => "Page1-A"},
              %{"Id" => "2", "Name" => "Page1-B"},
              %{"Id" => "3", "Name" => "Page2-A"}
            ])
    end

    scenario "streams a Query struct lazily and supports early take" do
      @given odata_paginated_collection("Contact", [
               %{"Id" => "1"},
               %{"Id" => "2"},
               %{"Id" => "3"},
               %{"Id" => "4"}
             ])
      @upon streaming_entities(
              Query.new("Contact") |> Query.filter("Active eq true"),
              query_first: true,
              page_size: 2,
              take: 2
            )
      @then streamed_entities_match([{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}])
      @then query_parameters_mapped(filter: "Active eq true", skip: 0, top: 2)
    end

    scenario "streams empty collection cleanly when string pagination bounds are provided" do
      @given odata_paginated_collection("Contact", [])
      @upon streaming_entities("Contact", page_size: "2", skip: "0")
      @then streamed_entities_match([])
    end

    scenario "inherits initial $skip offset when streaming a Query struct" do
      @given odata_paginated_collection("Contact", [
               %{"Id" => "1"},
               %{"Id" => "2"},
               %{"Id" => "3"}
             ])
      @upon streaming_entities(
              Query.new("Contact") |> Query.skip(2),
              query_first: true,
              page_size: 2
            )
      @then streamed_entities_match([{:ok, %{"Id" => "3"}}])
      @then query_parameters_mapped(skip: 3, top: 2)
    end

    scenario "honors opts[:skip], opts[:top], and string-key maps in stream and stream!" do
      @given odata_paginated_collection("Contact", [
               %{"Id" => 1},
               %{"Id" => 2},
               %{"Id" => 3},
               %{"Id" => 4},
               %{"Id" => 5},
               %{"Id" => 6},
               %{"Id" => 7},
               %{"Id" => 8},
               %{"Id" => 9}
             ])
      @upon streaming_entities(Query.new("Contact") |> Query.skip(99) |> Query.top(3),
              page_size: 2,
              skip: 5
            )
      @then streamed_entities_match([
              {:ok, %{"Id" => 6}},
              {:ok, %{"Id" => 7}},
              {:ok, %{"Id" => 8}}
            ])
      @then query_parameters_mapped(skip: 7, top: 1)

      @upon streaming_entities(Query.new("Contact") |> Query.skip(99) |> Query.top(3),
              page_size: 2,
              skip: 5,
              bang: true
            )
      @then streamed_entities_match([%{"Id" => 6}, %{"Id" => 7}, %{"Id" => 8}])

      @upon streaming_entities("Contact", facade: true, bang: true, top: 3, page_size: 2)
      @then streamed_entities_match([%{"Id" => 1}, %{"Id" => 2}, %{"Id" => 3}])

      @upon streaming_entities("Contact", %{
              "page_size" => 2,
              "top" => 2,
              facade: true,
              bang: true
            })
      @then streamed_entities_match([%{"Id" => 1}, %{"Id" => 2}])
    end

    scenario "paginates with keyset cursor_field without $skip, tie-breaks duplicates, and detects missing cursors" do
      @given odata_pages("Contact", fn req, _idx ->
               filter = req.query_params["$filter"] || ""

               records =
                 cond do
                   String.contains?(filter, "Id gt #{@cursor_id3}") ->
                     []

                   String.contains?(filter, "Id gt #{@cursor_id2}") ->
                     [%{"Id" => @cursor_id3}]

                   true ->
                     [%{"Id" => @cursor_id1}, %{"Id" => @cursor_id2}]
                 end

               {200, %{"value" => records}}
             end)
      @upon streaming_entities(Query.new("Contact") |> Query.filter_eq("Active", true),
              page_size: 2,
              cursor_field: "Id"
            )
      @then streamed_entities_match([
              {:ok, %{"Id" => @cursor_id1}},
              {:ok, %{"Id" => @cursor_id2}},
              {:ok, %{"Id" => @cursor_id3}}
            ])
      @then last_request_omitted_query_param("$skip")
      @then query_parameters_mapped(
              orderby: "Id asc",
              filter: "(Active eq true) and (Id gt #{@cursor_id2})"
            )

      @upon streaming_entities(Query.new("Contact") |> Query.filter_eq("Active", true),
              page_size: 2,
              cursor_field: "Id",
              bang: true
            )
      @then streamed_entities_match([
              %{"Id" => @cursor_id1},
              %{"Id" => @cursor_id2},
              %{"Id" => @cursor_id3}
            ])

      @given odata_pages("Account", fn req, _idx ->
               filter = req.query_params["$filter"] || ""

               records =
                 cond do
                   String.contains?(filter, "'id-3'") ->
                     []

                   String.contains?(filter, "'id-2'") ->
                     [%{"Id" => "id-3", "Name" => "C", "ModifiedOn" => @cursor_ts}]

                   true ->
                     [
                       %{"Id" => "id-1", "Name" => "A", "ModifiedOn" => @cursor_ts},
                       %{"Id" => "id-2", "Name" => "B", "ModifiedOn" => @cursor_ts}
                     ]
                 end

               {200, %{"value" => records}}
             end)
      @upon streaming_entities(
              Query.new("Account") |> Query.select(["Name"]) |> Query.filter_eq("Active", false),
              cursor_field: "ModifiedOn",
              page_size: 2,
              filter: "Active eq true"
            )
      @then streamed_entities_match([
              {:ok, %{"Id" => "id-1", "Name" => "A", "ModifiedOn" => @cursor_ts}},
              {:ok, %{"Id" => "id-2", "Name" => "B", "ModifiedOn" => @cursor_ts}},
              {:ok, %{"Id" => "id-3", "Name" => "C", "ModifiedOn" => @cursor_ts}}
            ])
      @then query_parameters_mapped(orderby: "ModifiedOn asc, Id asc")
      @then last_request_query_param_contains("$select", "ModifiedOn")
      @then last_request_query_param_contains("$select", "Id")
      @then last_request_query_param_contains("$filter", "Active eq true")
      @then last_request_query_param_omits("$filter", "Active eq false")

      @given odata_collection("Lead", records: [%{"Id" => "id-1", "Name" => "NoCursor"}])
      @upon streaming_entities("Lead", cursor_field: "ModifiedOn", page_size: 1)
      @then stream_error_returned([%{"Id" => "id-1", "Name" => "NoCursor"}],
              message_contains: "ModifiedOn"
            )
    end

    scenario "follows @odata.nextLink under low server caps without wasted page fetches" do
      @given odata_pages("Contact", [
               {200,
                %{
                  "value" => [%{"Id" => "1"}, %{"Id" => "2"}],
                  "@odata.nextLink" =>
                    "https://mycreatio.com/0/odata/Contact?$skiptoken=page2&$top=5"
                }},
               {200, %{"value" => [%{"Id" => "3"}], "@odata.nextLink" => nil}}
             ])
      @upon streaming_entities("Contact", facade: true, bang: true, page_size: 5)
      @then streamed_entities_match([%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}])
      @then query_parameters_mapped("$skiptoken": "page2")
      @then server_request_count_was(2)
    end

    scenario "handles page_size above 20,000 across multi-page nextLink and single-page tables" do
      @given odata_pages("Contact", [
               {200,
                %{"value" => [%{"Id" => 1}], "@odata.nextLink" => "/0/odata/Contact?$skip=20000"}},
               {200, %{"value" => [%{"Id" => 2}]}},
               {200, %{"value" => []}}
             ])
      @upon streaming_entities("Contact", page_size: 25_000)
      @then streamed_entities_match([{:ok, %{"Id" => 1}}, {:ok, %{"Id" => 2}}])

      @given odata_paginated_collection("Account", [%{"Id" => "only-1"}, %{"Id" => "only-2"}])
      @upon streaming_entities("Account", page_size: 25_000, bang: true)
      @then streamed_entities_match([%{"Id" => "only-1"}, %{"Id" => "only-2"}])
      @then server_request_count_was(4)
    end
  end

  describe "OData 4 IIS Content-Type & Error Resilience" do
    scenario "decodes IIS text/html BOM JSON responses across all OData 4 operations" do
      @given odata_creatable_entity("Contact",
               status: 201,
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"Id" => "c-1", "Name" => "Created"})
             )
      @upon creating_entity("Contact", %{"Name" => "Created"})
      @then entity_created_with(%{"Id" => "c-1", "Name" => "Created"})

      @given odata_collection("Contact",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"value" => [%{"Id" => "c-1"}]})
             )
      @upon listing_entities("Contact")
      @then entities_returned([%{"Id" => "c-1"}])

      @given odata_entity("Contact", "c-1",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"Id" => "c-1", "Name" => "Alice"})
             )
      @upon getting_entity("Contact", "c-1")
      @then entity_returned(%{"Id" => "c-1", "Name" => "Alice"})

      @given odata_navigation("Contact", "c-1", "Account",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"Id" => "a-1", "Name" => "Acme"})
             )
      @upon getting_navigation("Contact", "c-1", "Account")
      @then entity_returned(%{"Id" => "a-1", "Name" => "Acme"})

      @given odata_field("Contact", "c-1", "Name",
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"value" => "Alice"})
             )
      @upon getting_field("Contact", "c-1", "Name")
      @then field_value_returned("Alice")

      @given odata_count_endpoint("Contact",
               strategy: :top_zero,
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"@odata.count" => 42, "value" => []})
             )
      @upon counting_entities("Contact", strategy: :top_zero)
      @then count_returned(42)

      @given odata_count_endpoint("Contact",
               strategy: :path,
               content_type: "text/html",
               raw_body: "\uFEFF42"
             )
      @upon counting_entities("Contact", strategy: :path)
      @then count_returned(42)
    end

    scenario "rejects WAF HTML interstitials, HTTP 200 error maps, and corrupt JSON across OData 4" do
      @given odata_collection("Contact", content_type: "text/html", raw_body: @waf_html)
      @upon listing_entities("Contact")
      @then operation_failed_with(status: 200)

      @given odata_entity("Contact", @waf_entity_id,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_entity("Contact", @waf_entity_id)
      @then operation_failed_with(status: 200)

      @given odata_navigation("Contact", @waf_entity_id, "Account",
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_navigation("Contact", @waf_entity_id, "Account")
      @then operation_failed_with(status: 200)

      @given odata_field("Contact", @waf_entity_id, "Name",
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon getting_field("Contact", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)

      @given odata_creatable_entity("Contact",
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon creating_entity("Contact", %{"Name" => "X"})
      @then operation_failed_with(status: 200)

      @given odata_updatable_entity("Contact", @waf_entity_id,
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon updating_entity("Contact", @waf_entity_id, %{"Name" => "Y"})
      @then operation_failed_with(status: 200)

      @given odata_deletable_entity("Contact", @waf_entity_id,
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon deleting_entity("Contact", @waf_entity_id)
      @then operation_failed_with(status: 200)

      @given odata_updatable_field("Contact", @waf_entity_id, "Name",
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon updating_entity_field("Contact", @waf_entity_id, "Name", "X")
      @then operation_failed_with(status: 200)

      @given odata_updatable_field("Contact", @waf_entity_id, "Name",
               status: 201,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon updating_entity_field("Contact", @waf_entity_id, "Name", "X")
      @then operation_failed_with(status: 201)

      @given odata_deletable_field("Contact", @waf_entity_id, "Name",
               status: 200,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon deleting_entity_field("Contact", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)

      @given odata_count_endpoint("Contact",
               strategy: :top_zero,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon counting_entities("Contact", strategy: :top_zero)
      @then operation_failed_with(status: 200)

      @given odata_count_endpoint("Contact",
               strategy: :path,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon counting_entities("Contact", strategy: :path)
      @then operation_failed_with(status: 200)

      @given odata_entity("Account", @waf_entity_id, body: %{"error" => %{"message" => "boom"}})
      @upon getting_entity("Account", @waf_entity_id)
      @then operation_failed_with(status: 200)

      @given odata_updatable_entity("Contact", @waf_entity_id,
               status: 200,
               content_type: "application/json",
               raw_body: "{broken"
             )
      @given odata_field("Contact", @waf_entity_id, "Name",
               content_type: "application/json",
               raw_body: "{broken"
             )
      @upon updating_entity("Contact", @waf_entity_id, %{"Name" => "X"}, return: :representation)
      @then operation_failed_with(status: 200)
      @upon getting_field("Contact", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)

      @given odata_updatable_entity("Contact", @waf_entity_id,
               status: 200,
               content_type: "text/plain",
               raw_body: "Gateway Timeout"
             )
      @given odata_field("Contact", @waf_entity_id, "Name",
               content_type: "text/plain",
               raw_body: "{broken"
             )
      @upon updating_entity("Contact", @waf_entity_id, %{"Name" => "X"}, return: :representation)
      @then operation_failed_with(status: 200)
      @upon getting_field("Contact", @waf_entity_id, "Name")
      @then operation_failed_with(status: 200)
    end
  end
end
