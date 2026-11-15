defmodule Creatio.Features.OData3LegacyEntitiesTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.ODataDSL

  alias Creatio.OData.Query

  @odata3_count_cases [
    {"path strategy plain text integer", [strategy: :path, format: :plain_text, count: 10], [],
     10},
    {"path strategy UTF-8 BOM plain text", [strategy: :path, format: :bom_plain_text, count: 123],
     [], 123},
    {"path strategy JSON integer body", [strategy: :path, format: :json_integer, count: 42], [],
     42},
    {"path strategy integer inside d envelope",
     [strategy: :path, format: :d_count_int, count: 55], [], 55},
    {"path strategy nested count inside d object",
     [strategy: :path, format: :d_nested_count, count: 1], [], 1},
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
    end
  end

  describe "OData 3 Counting" do
    for {desc, stub_opts, call_opts, expected} <- @odata3_count_cases do
      scenario "counts OData 3 entities with #{desc}" do
        @given odata3_count_endpoint("Contact", unquote(stub_opts))
        @upon counting_odata3_entities("Contact", unquote(call_opts))
        @then count_returned(unquote(expected))
      end
    end

    scenario "records query-strategy /$count URL format on legacy OData 3 endpoints" do
      @given odata3_count_endpoint("Contact", strategy: :query, format: :plain_text, count: 33)
      @upon counting_odata3_entities("Contact", strategy: :query)
      @then count_returned(33)
      @then odata3_query_count_strategy_used("Contact")
    end

    scenario "counts OData 3 entities using bang variant" do
      @given odata3_count_endpoint("Contact", strategy: :path, format: :plain_text, count: 19)
      @upon counting_odata3_entities("Contact", bang: true)
      @then count_returned(19)
    end

    scenario "returns error when OData 3 count response is non-numeric text" do
      @given odata3_count_endpoint("Contact",
               strategy: :path,
               format: :plain_text,
               count: "invalid"
             )
      @upon counting_odata3_entities("Contact")
      @then operation_failed_with(message: "Failed to parse count response: invalid")
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
      @then streamed_entities_match([%{"Id" => "1"}, %{"Id" => "2"}, %{"Id" => "3"}])
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
      @then streamed_entities_match([%{"Id" => "3"}])
      @then query_parameters_mapped(skip: 2, top: 2)
    end
  end
end
