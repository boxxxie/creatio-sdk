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
    {"DataService BatchQuery", {:data_service_batch, %{"items" => []}}},
    {"DataService execute_query InsertQuery",
     {:data_service_execute, "InsertQuery", %{"rootSchemaName" => "Contact"}}},
    {"DataService select_query :url override to DeleteQuery",
     {:data_service_select_opts, %{}, [url: "/0/DataService/json/SyncReply/DeleteQuery"]}},
    {"DataService execute_query :url override to InsertQuery",
     {:data_service_execute_opts, "SelectQuery", %{},
      [url: "/0/DataService/json/SyncReply/InsertQuery"]}},
    {"Custom REST POST service call", {:custom_service, "MySvc", "Mutate", %{"x" => 1}, []}},
    {"Custom REST DELETE service call",
     {:custom_service_opts, "MySvc", "DeleteIt", [method: :delete]}},
    {"OData $batch containing write operations",
     {:batch_mutation, "Contact", %{"Name" => "Alice"}}},
    {"OData $batch raw operation list mutation",
     {:batch_list_mutation, [%{method: "POST", url: "Contact", body: %{"Name" => "A"}}]}}
  ]

  @allowed_read_only_operations [
    {"DataService execute_query SelectQuery",
     {:data_service_execute, "SelectQuery", %{"rootSchemaName" => "Contact"}}},
    {"Custom REST GET service call", {:custom_service_opts, "MySvc", "Ping", [method: :get]}},
    {"Custom REST HEAD service call", {:custom_service_opts, "MySvc", "Ping", [method: :head]}},
    {"Custom REST OPTIONS service call",
     {:custom_service_opts, "MySvc", "Ping", [method: :options]}}
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
    {"POST custom REST mutation", :post, :custom_rest},
    {"GET OData dot-segment path traversal to custom REST", :get, :path_traversal_custom_rest}
  ]

  describe "Read-Only Client Configuration & Local SDK Guards" do
    scenario "configures client read_only flag and exposes guarded Req client" do
      @given read_only_crm_client()
      @then client_is_in_read_only_mode()
    end

    scenario "blocks all write operations locally without sending any HTTP request" do
      @given crm_server_accepting_requests()
      @given read_only_crm_client()
      @upon attempting_all_operations(@blocked_mutations)
      @then all_operations_blocked_locally()
    end

    scenario "permits read-only DataService SelectQuery and GET/HEAD/OPTIONS custom services" do
      @given read_only_crm_client_with_server()
      @upon attempting_all_operations(@allowed_read_only_operations)
      @then all_operations_succeeded()
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
    scenario "permits read-only and auth endpoints through read-only transport guard" do
      @given read_only_crm_client_with_server()
      @upon sending_transport_requests(@allowed_transport_requests)
      @then all_transport_requests_succeeded()
    end

    scenario "blocks mutation endpoints at transport guard before network dispatch" do
      @given read_only_crm_client_with_server()
      @upon sending_transport_requests(@blocked_transport_requests)
      @then all_transport_requests_blocked()
    end
  end
end
