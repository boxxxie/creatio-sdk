defmodule Creatio.Features.ODataEntitiesTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.ODataDSL

  alias Creatio.OData.Query

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
  end

  describe "OData 4 Single Entity, Navigation & Field Access" do
    scenario "fetches a single entity by GUID and normalizes braces" do
      @given odata_entity("Contact", "abc-123", record: %{"Id" => "abc-123", "Name" => "John"})
      @upon getting_entity("Contact", "{abc-123}")
      @then entity_returned(%{"Id" => "abc-123", "Name" => "John"})
      @then requested_odata_entity_id("Contact", "abc-123")
      @upon getting_entity("Contact", "abc-123", bang: true)
      @then entity_returned(%{"Id" => "abc-123", "Name" => "John"})
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

    scenario "retrieves wrapped and raw entity field values" do
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
    end
  end

  describe "OData 4 Counting" do
    for {desc, stub_opts, call_opts, expected} <- @count_format_cases do
      scenario "counts entities with #{desc}" do
        @given odata_count_endpoint("Contact", unquote(stub_opts))
        @upon counting_entities("Contact", unquote(call_opts))
        @then count_returned(unquote(expected))
      end
    end

    scenario "counts entities with bang variant" do
      @given odata_count_endpoint("Contact", format: :plain_text, count: 77)
      @upon counting_entities("Contact", bang: true)
      @then count_returned(77)
    end

    scenario "returns errors when count endpoint lacks @odata.count or returns non-numeric text" do
      @given odata_collection("Contact", records: [])
      @upon counting_entities("Contact", strategy: :top_zero)
      @then operation_failed_with(message: "No @odata.count found in response")

      @given odata_count_endpoint("Contact", format: :plain_text, count: "invalid")
      @upon counting_entities("Contact")
      @then operation_failed_with(message: "Failed to parse count response: invalid")

      @given odata_collection("Contact",
               status: 500,
               error: %{"error" => %{"code" => "ServerError", "message" => "Count failed"}}
             )
      @upon counting_entities("Contact", strategy: :top_zero)
      @then operation_failed_with(status: 500, code: "ServerError", message: "Count failed")
    end
  end

  describe "OData 4 Mutations & Field Uploads" do
    scenario "creates entities with Creatio session headers" do
      @given odata_creatable_entity("Contact", assigned_id: "created-1")
      @upon creating_entity("Contact", %{"Name" => "New Lead"})
      @then entity_created_with(%{"Id" => "created-1", "Name" => "New Lead"})
      @upon creating_entity("Contact", %{"Name" => "New Lead"}, bang: true)
      @then entity_created_with(%{"Id" => "created-1", "Name" => "New Lead"})
    end

    scenario "updates entity returning 204 No Content or 200 JSON body" do
      @given odata_updatable_entity("Contact", "1")
      @upon updating_entity("Contact", "1", %{"Name" => "Updated"})
      @then mutation_succeeded()
      @upon updating_entity("Contact", "1", %{"Name" => "Updated"}, bang: true)
      @then bang_mutation_succeeded()

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
      @then query_parameters_mapped(skip: 2, top: 2)

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
      @then query_parameters_mapped(skip: 2, top: 2)
    end
  end
end
