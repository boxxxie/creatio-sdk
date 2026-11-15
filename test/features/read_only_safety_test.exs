defmodule Creatio.Features.ReadOnlySafetyTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.SafetyDSL

  @blocked_mutations [
    {"OData 4 entity creation", {:odata_create, "Contact", %{"Name" => "Alice"}}},
    {"OData 4 entity update", {:odata_update, "Contact", "1", %{"Name" => "Alice"}}},
    {"OData 4 entity deletion", {:odata_delete, "Contact", "1"}},
    {"OData 4 field upload", {:odata_update_field, "Contact", "1", "Notes", "note"}},
    {"OData 4 field deletion", {:odata_delete_field, "Contact", "1", "Notes"}},
    {"OData 3 entity creation", {:odata3_create, "Contact", %{"Name" => "Alice"}}},
    {"OData 3 entity update", {:odata3_update, "Contact", "1", %{"Name" => "Alice"}}},
    {"OData 3 entity deletion", {:odata3_delete, "Contact", "1"}},
    {"DataService InsertQuery", {:data_service_insert, %{"rootSchemaName" => "Contact"}}},
    {"DataService UpdateQuery", {:data_service_update, %{"rootSchemaName" => "Contact"}}},
    {"DataService DeleteQuery", {:data_service_delete, %{"rootSchemaName" => "Contact"}}},
    {"OData $batch containing write operations",
     {:batch_mutation, "Contact", %{"Name" => "Alice"}}}
  ]

  @allowed_transport_requests [
    {"GET OData entity query", :get, :odata_entity_query},
    {"POST DataService SelectQuery", :post, :select_query},
    {"POST AuthService Forms Login", :post, :forms_login},
    {"POST Legacy AuthService Login", :post, :legacy_auth_login},
    {"POST OAuth token endpoint", :post, :oauth_token},
    {"POST OData $batch endpoint", :post, :batch_endpoint}
  ]

  @blocked_transport_requests [
    {"POST OData collection creation", :post, :odata_collection},
    {"POST DataService InsertQuery", :post, :insert_query},
    {"POST custom REST mutation", :post, :custom_rest}
  ]

  describe "Read-Only Client Configuration & Local SDK Guards" do
    scenario "configures client read_only flag and exposes guarded Req client" do
      @given read_only_crm_client()
      @then client_is_in_read_only_mode()
    end

    for {label, operation} <- @blocked_mutations do
      scenario "blocks #{label} locally without sending any HTTP request" do
        @given crm_server_accepting_requests()
        @given read_only_crm_client()
        @upon attempting_operation(unquote(Macro.escape(operation)))
        @then blocked_locally_by_read_only_mode()
      end
    end

    scenario "allows read-only GET-only $batch requests" do
      @given read_only_crm_client_with_server(
               batch_responses: [%{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}]
             )
      @upon attempting_operation({:batch_get_only, "Contact"})
      @then batch_succeeded_with_responses(1)
    end

    scenario "blocks raw binary batches locally in read-only mode" do
      @given read_only_crm_client_with_server()
      @upon attempting_operation({:batch_binary, "--batch_raw_payload--"})
      @then blocked_locally_by_read_only_mode()
    end
  end

  describe "Transport-Layer Req Read-Only Guard" do
    for {label, method, endpoint} <- @allowed_transport_requests do
      scenario "permits #{label} through read-only transport guard" do
        @given read_only_crm_client_with_server()
        @upon sending_transport_request(unquote(method), unquote(endpoint))
        @then raw_request_succeeded()
      end
    end

    for {label, method, endpoint} <- @blocked_transport_requests do
      scenario "blocks #{label} at transport guard before network dispatch" do
        @given read_only_crm_client_with_server()
        @upon sending_transport_request(unquote(method), unquote(endpoint))
        @then blocked_at_transport_by_read_only_mode()
      end
    end
  end
end
