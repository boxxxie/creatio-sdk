defmodule Creatio.Features.SdkFacadeAndResilienceTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.SafetyDSL

  @facade_cases [
    {"OData list/2", {:list, "Contact"}, {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData list!/2", {:list!, "Contact"}, {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData list/2 query-first", {:list_query_first, "Contact"},
     {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData list!/2 query-first", {:list_query_first!, "Contact"},
     {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData execute/2", {:execute, "Contact"}, {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData execute!/2", {:execute!, "Contact"}, {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData execute/2 query-first", {:execute_query_first, "Contact"},
     {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData execute!/2 query-first", {:execute_query_first!, "Contact"},
     {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData get/3", {:get, "Contact", "1"}, {:ok, %{"Id" => "1", "Name" => "Test"}}},
    {"OData get!/3", {:get!, "Contact", "1"}, {:ok, %{"Id" => "1", "Name" => "Test"}}},
    {"OData create/3", {:create, "Contact", %{"Name" => "New"}},
     {:ok, %{"Id" => "new-id", "Name" => "New"}}},
    {"OData create!/3", {:create!, "Contact", %{"Name" => "New"}},
     {:ok, %{"Id" => "new-id", "Name" => "New"}}},
    {"OData update/4", {:update, "Contact", "1", %{"Name" => "U"}}, :ok},
    {"OData update!/4", {:update!, "Contact", "1", %{"Name" => "U"}}, {:ok, :ok}},
    {"OData delete/3", {:delete, "Contact", "1"}, :ok},
    {"OData delete!/3", {:delete!, "Contact", "1"}, {:ok, :ok}},
    {"OData count/2", {:count, "Contact"}, {:ok, 42}},
    {"OData count!/2", {:count!, "Contact"}, {:ok, 42}},
    {"OData get_navigation/4", {:get_navigation, "Contact", "1", "Account"},
     {:ok, %{"Name" => "Acme"}}},
    {"OData get_navigation!/4", {:get_navigation!, "Contact", "1", "Account"},
     {:ok, %{"Name" => "Acme"}}},
    {"OData get_field/4", {:get_field, "Contact", "1", "Name"}, {:ok, "Test"}},
    {"OData get_field!/4", {:get_field!, "Contact", "1", "Name"}, {:ok, "Test"}},
    {"OData get_field_value/4", {:get_field_value, "Contact", "1", "Name"}, {:ok, "RawName"}},
    {"OData get_field_value!/4", {:get_field_value!, "Contact", "1", "Name"}, {:ok, "RawName"}},
    {"OData update_field/5", {:update_field, "Contact", "1", "Photo", "bin"}, :ok},
    {"OData update_field!/5", {:update_field!, "Contact", "1", "Photo", "bin"}, {:ok, :ok}},
    {"OData delete_field/4", {:delete_field, "Contact", "1", "Photo"}, :ok},
    {"OData delete_field!/4", {:delete_field!, "Contact", "1", "Photo"}, {:ok, :ok}},
    {"OData stream/3", {:stream, "Contact", []},
     {:ok, [{:ok, %{"Id" => "1", "Name" => "Test"}}]}},
    {"OData stream!/3", {:stream!, "Contact", []}, {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"OData stream/3 query-first", {:stream_query_first, "Contact", []},
     {:ok, [{:ok, %{"Id" => "1", "Name" => "Test"}}]}},
    {"OData stream!/3 query-first", {:stream_query_first!, "Contact", []},
     {:ok, [%{"Id" => "1", "Name" => "Test"}]}},
    {"DataService select_query/2", {:select_query, %{}},
     {:ok, %{"rows" => [%{"Name" => "Corp"}], "success" => true}}},
    {"DataService select_query!/2", {:select_query!, %{}},
     {:ok, %{"rows" => [%{"Name" => "Corp"}], "success" => true}}},
    {"DataService insert_query/2", {:insert_query, %{}}, {:ok, %{"id" => "inserted-id"}}},
    {"DataService insert_query!/2", {:insert_query!, %{}}, {:ok, %{"id" => "inserted-id"}}},
    {"DataService update_query/2", {:update_query, %{}}, {:ok, %{"rowsAffected" => 1}}},
    {"DataService update_query!/2", {:update_query!, %{}}, {:ok, %{"rowsAffected" => 1}}},
    {"DataService delete_query/2", {:delete_query, %{}}, {:ok, %{"rowsAffected" => 1}}},
    {"DataService delete_query!/2", {:delete_query!, %{}}, {:ok, %{"rowsAffected" => 1}}},
    {"DataService batch_query/2", {:batch_query, %{}}, {:ok, %{"responses" => []}}},
    {"DataService batch_query!/2", {:batch_query!, %{}}, {:ok, %{"responses" => []}}},
    {"DataService data_service_query/3", {:data_service_query, "GenericAction", %{}},
     {:ok, %{"success" => true}}},
    {"DataService data_service_query!/3", {:data_service_query!, "GenericAction", %{}},
     {:ok, %{"success" => true}}},
    {"CustomService 5-arg POST echo", {:custom_service, "CustomSvc", "Echo", %{"a" => 1}, []},
     {:ok, %{"a" => 1}}},
    {"CustomService! 5-arg POST echo", {:custom_service!, "CustomSvc", "Echo", %{"a" => 1}, []},
     {:ok, %{"a" => 1}}},
    {"CustomService 4-arg GET", {:custom_service_opts, "CustomSvc", "Ping", [method: :get]},
     {:ok, %{"status" => "pong"}}},
    {"CustomService! 4-arg GET", {:custom_service_opts!, "CustomSvc", "Ping", [method: :get]},
     {:ok, %{"status" => "pong"}}},
    {"OData 3 list/2", {:odata3_list, "Contact"}, {:ok, [%{"Name" => "Legacy"}]}},
    {"OData 3 list!/2", {:odata3_list!, "Contact"}, {:ok, [%{"Name" => "Legacy"}]}},
    {"OData 3 list/2 query-first", {:odata3_list_query_first, "Contact"},
     {:ok, [%{"Name" => "Legacy"}]}},
    {"OData 3 list!/2 query-first", {:odata3_list_query_first!, "Contact"},
     {:ok, [%{"Name" => "Legacy"}]}},
    {"OData 3 get/3", {:odata3_get, "Contact", "1"}, {:ok, %{"Name" => "Legacy"}}},
    {"OData 3 get!/3", {:odata3_get!, "Contact", "1"}, {:ok, %{"Name" => "Legacy"}}},
    {"OData 3 get_navigation/4", {:odata3_get_navigation, "Contact", "1", "Account"},
     {:ok, %{"Name" => "Legacy Org"}}},
    {"OData 3 get_navigation!/4", {:odata3_get_navigation!, "Contact", "1", "Account"},
     {:ok, %{"Name" => "Legacy Org"}}},
    {"OData 3 get_field/4", {:odata3_get_field, "Contact", "1", "Name"}, {:ok, "Legacy Name"}},
    {"OData 3 get_field!/4", {:odata3_get_field!, "Contact", "1", "Name"}, {:ok, "Legacy Name"}},
    {"OData 3 get_field_value/4", {:odata3_get_field_value, "Contact", "1", "Name"},
     {:ok, "Raw Legacy Name"}},
    {"OData 3 get_field_value!/4", {:odata3_get_field_value!, "Contact", "1", "Name"},
     {:ok, "Raw Legacy Name"}},
    {"OData 3 count/2", {:odata3_count, "Contact"}, {:ok, 99}},
    {"OData 3 count!/2", {:odata3_count!, "Contact"}, {:ok, 99}},
    {"OData 3 create/3", {:odata3_create, "Contact", %{"Name" => "L"}},
     {:ok, %{"Id" => "new-1"}}},
    {"OData 3 create!/3", {:odata3_create!, "Contact", %{"Name" => "L"}},
     {:ok, %{"Id" => "new-1"}}},
    {"OData 3 update/4", {:odata3_update, "Contact", "1", %{"Name" => "U"}}, :ok},
    {"OData 3 update!/4", {:odata3_update!, "Contact", "1", %{"Name" => "U"}}, {:ok, :ok}},
    {"OData 3 delete/3", {:odata3_delete, "Contact", "1"}, :ok},
    {"OData 3 delete!/3", {:odata3_delete!, "Contact", "1"}, {:ok, :ok}},
    {"OData 3 stream/3", {:odata3_stream, "Contact", []}, {:ok, [{:ok, %{"Name" => "Legacy"}}]}},
    {"OData 3 stream!/3", {:odata3_stream!, "Contact", []}, {:ok, [%{"Name" => "Legacy"}]}},
    {"OData 3 stream/3 query-first", {:odata3_stream_query_first, "Contact", []},
     {:ok, [{:ok, %{"Name" => "Legacy"}}]}},
    {"OData 3 stream!/3 query-first", {:odata3_stream_query_first!, "Contact", []},
     {:ok, [%{"Name" => "Legacy"}]}},
    {"Batch execute/2", {:batch_get, "Contact", "1"}, {:batch_response_count, 1}},
    {"Batch execute!/2", {:batch_get!, "Contact", "1"}, {:batch_response_count, 1}},
    {"Batch to_multipart/1", {:batch_to_multipart, "Contact", "1"}, {:ok, %{has_boundary: true}}},
    {"Batch parse_multipart/2", {:batch_parse_multipart_sample}, {:batch_response_count, 1}},
    {"Query builder query/1", {:query_helper, "Contact", ["Id", "Name"]},
     {:ok, %{entity: "Contact", select: ["Id", "Name"]}}},
    {"Client constructor new/1", {:new_client, "https://mycreatio.com"},
     {:ok, "https://mycreatio.com"}},
    {"Client constructor from_req/1", {:from_req, "https://mycreatio.com"},
     {:ok, "https://mycreatio.com"}},
    {"Auth login/3", {:login, "Supervisor", "Supervisor"}, {:ok, %{auth_mode: :forms}}},
    {"Auth login_oauth/1", {:login_oauth},
     {:ok, %{auth_mode: :bearer, access_token: "facade_oauth_token"}}},
    {"Auth oauth_health_check/1", {:oauth_health_check}, {:ok, %{"status" => "Healthy"}}},
    {"Auth openid_configuration/1", {:openid_configuration}, {:ok, %{"issuer" => "test"}}}
  ]

  @bang_error_operations [
    {"OData list!", {:bang_odata_list, "Contact"}},
    {"OData list! query-first", {:bang_odata_list_query_first, "Contact"}},
    {"OData execute!", {:bang_odata_execute, "Contact"}},
    {"OData get!", {:bang_odata_get, "Contact", "123"}},
    {"OData get_navigation!", {:bang_odata_get_navigation, "Contact", "123", "Account"}},
    {"OData get_field!", {:bang_odata_get_field, "Contact", "123", "Name"}},
    {"OData get_field_value!", {:bang_odata_get_field_value, "Contact", "123", "Name"}},
    {"OData count!", {:bang_odata_count, "Contact"}},
    {"OData create!", {:bang_odata_create, "Contact", %{}}},
    {"OData update!", {:bang_odata_update, "Contact", "123", %{}}},
    {"OData delete!", {:bang_odata_delete, "Contact", "123"}},
    {"OData update_field!", {:bang_odata_update_field, "Contact", "123", "Name", "X"}},
    {"OData delete_field!", {:bang_odata_delete_field, "Contact", "123", "Name"}},
    {"OData stream! query-first", {:bang_odata_stream_query_first, "Contact"}},
    {"OData 3 list!", {:bang_odata3_list, "Contact"}},
    {"OData 3 list! query-first", {:bang_odata3_list_query_first, "Contact"}},
    {"OData 3 get!", {:bang_odata3_get, "Contact", "123"}},
    {"OData 3 get_navigation!", {:bang_odata3_get_navigation, "Contact", "123", "Account"}},
    {"OData 3 get_field!", {:bang_odata3_get_field, "Contact", "123", "Name"}},
    {"OData 3 get_field_value!", {:bang_odata3_get_field_value, "Contact", "123", "Name"}},
    {"OData 3 count!", {:bang_odata3_count, "Contact"}},
    {"OData 3 create!", {:bang_odata3_create, "Contact", %{}}},
    {"OData 3 update!", {:bang_odata3_update, "Contact", "123", %{}}},
    {"OData 3 delete!", {:bang_odata3_delete, "Contact", "123"}},
    {"OData 3 stream! query-first", {:bang_odata3_stream!, "Contact"}},
    {"DataService select_query!", {:bang_data_service_select, %{}}},
    {"DataService insert_query!", {:bang_data_service_insert, %{}}},
    {"DataService update_query!", {:bang_data_service_update, %{}}},
    {"DataService delete_query!", {:bang_data_service_delete, %{}}},
    {"DataService batch_query!", {:bang_data_service_batch, %{}}},
    {"DataService execute_query!", {:bang_data_service_execute, "GenericAction", %{}}},
    {"CustomService 4-arg bang", {:bang_custom_service_4, "CustomSvc", "Ping", [method: :get]}},
    {"CustomService 5-arg bang",
     {:bang_custom_service_5, "CustomSvc", "Echo", %{"a" => 1}, [method: :post]}},
    {"Creatio batch! with empty requests", {:facade_batch_empty!}},
    {"Creatio stream!", {:facade_stream!, "Contact"}},
    {"Creatio odata3_stream!", {:facade_odata3_stream!, "Contact"}}
  ]

  @stream_error_operations [
    {"OData stream/3 query-first", {:stream_error_odata_query_first, "Contact"}},
    {"OData 3 stream/3 query-first", {:stream_error_odata3_query_first, "Contact"}},
    {"Creatio stream/3", {:stream_error_facade, "Contact"}},
    {"Creatio odata3_stream/3", {:stream_error_facade_odata3, "Contact"}}
  ]

  @normalized_params [
    select: ["Id", :Name],
    select: "Id",
    select: [],
    expand: ["Account", :Owner],
    expand: "Account",
    expand: [],
    orderby: ["Id desc", :Name],
    orderby: "Id desc",
    order_by: [Name: :asc],
    inlinecount: :allpages,
    params: %{"$select" => "Id"},
    params: [{"$top", 5}],
    some_key: ["A", "B"],
    some_key2: "A",
    some_key3: :A
  ]

  @tuple_error_operations [
    {"OData list with full keyword parameter normalization",
     {:odata_list_opts, "Contact", @normalized_params}},
    {"OData list with map parameter normalization",
     {:odata_list_opts, "Contact", %{"$select" => ["Id", "Name"], "$filter" => "Active eq true"}}},
    {"OData 3 list with full keyword parameter normalization",
     {:odata3_list_opts, "Contact", @normalized_params}},
    {"OData 3 list with map parameter normalization",
     {:odata3_list_opts, "Contact", %{"$select" => ["Id", "Name"], "$filter" => "Active eq true"}}},
    {"DataService execute_query", {:data_service_execute, "GenericAction", %{}}},
    {"Creatio batch with empty requests", {:facade_batch_empty}},
    {"Creatio Forms login", {:facade_login, "u", "p"}},
    {"Creatio OAuth login with explicit token_path",
     {:auth_login_oauth, [token_path: "https://identity.mycreatio.com/connect/token"]}},
    {"Creatio OAuth login without credentials", {:facade_login_oauth}},
    {"Creatio OAuth health check", {:facade_oauth_health_check}},
    {"Creatio OpenID config with explicit url opt",
     {:auth_openid_configuration,
      [url: "https://identity.mycreatio.com/.well-known/openid-configuration"]}},
    {"Creatio OpenID config via client", {:facade_openid_configuration_client}},
    {"Creatio OpenID config via direct URL",
     {:facade_openid_configuration_url, "https://identity.mycreatio.com"}}
  ]

  @timeout_operations [
    {"Auth login_forms", {:auth_login_forms, "u", "p"}},
    {"Auth login_oauth", {:auth_login_oauth, []}},
    {"Auth oauth_health_check", {:auth_oauth_health_check}},
    {"Auth openid_configuration", {:auth_openid_configuration, []}},
    {"OData list", {:odata_list, "Account"}},
    {"OData execute", {:odata_execute, "Account"}},
    {"OData get", {:odata_get, "Account", "1"}},
    {"OData count", {:odata_count, "Account"}},
    {"OData count top_zero", {:odata_count_top_zero, "Account"}},
    {"OData create", {:odata_create, "Account", %{}}},
    {"OData update", {:odata_update, "Account", "1", %{}}},
    {"OData delete", {:odata_delete, "Account", "1"}},
    {"OData get_navigation", {:odata_get_navigation, "Account", "1", "PrimaryContact"}},
    {"OData get_field", {:odata_get_field, "Account", "1", "Name"}},
    {"OData get_field_value", {:odata_get_field_value, "Account", "1", "Name"}},
    {"OData update_field", {:odata_update_field, "Account", "1", "Name", "Acme"}},
    {"OData delete_field", {:odata_delete_field, "Account", "1", "Name"}},
    {"OData 3 list", {:odata3_list, "Account"}},
    {"OData 3 get", {:odata3_get, "Account", "1"}},
    {"OData 3 count", {:odata3_count, "Account"}},
    {"OData 3 create", {:odata3_create, "Account", %{}}},
    {"OData 3 update", {:odata3_update, "Account", "1", %{}}},
    {"OData 3 delete", {:odata3_delete, "Account", "1"}},
    {"OData 3 get_navigation", {:odata3_get_navigation, "Account", "1", "PrimaryContact"}},
    {"OData 3 get_field", {:odata3_get_field, "Account", "1", "Name"}},
    {"OData 3 get_field_value", {:odata3_get_field_value, "Account", "1", "Name"}},
    {"JSON Batch execute", {:batch_empty_json}},
    {"Multipart Batch execute", {:batch_empty_multipart}},
    {"DataService select_query", {:data_service_select, %{}}},
    {"DataService insert_query", {:data_service_insert, %{}}},
    {"DataService update_query", {:data_service_update, %{}}},
    {"DataService delete_query", {:data_service_delete, %{}}},
    {"DataService batch_query", {:data_service_batch, %{}}},
    {"Custom REST service", {:custom_service, "CustomSvc", "Ping"}}
  ]

  describe "Top-Level Creatio Facade Delegation" do
    for {label, spec, expected} <- @facade_cases do
      scenario "delegates #{label}" do
        @given crm_facade_server()
        @upon invoking_facade(unquote(Macro.escape(spec)))
        @then facade_result_matches(unquote(Macro.escape(expected)))
      end
    end
  end

  describe "Bang (!) Raising Behavior on Server Failure" do
    for {label, operation} <- @bang_error_operations do
      scenario "raises Creatio.Error on 500 server failure for #{label}" do
        @given crm_server_failing_with_status(500, %{})
        @upon attempting_operation(unquote(Macro.escape(operation)))
        @then bang_raised_error(status: 500)
      end
    end
  end

  describe "Tuple Error Propagation & Parameter Normalization" do
    for {label, operation} <- @stream_error_operations do
      scenario "emits {:error, %Creatio.Error{}} and halts on 500 server failure for #{label}" do
        @given crm_server_failing_with_status(500, %{})
        @upon attempting_operation(unquote(Macro.escape(operation)))
        @then stream_emitted_error(status: 500)
      end
    end

    for {label, operation} <- @tuple_error_operations do
      scenario "returns Creatio.Error tuple for #{label}" do
        @given crm_server_failing_with_status(500, %{})
        @upon attempting_operation(unquote(Macro.escape(operation)))
        @then operation_returned_error()
      end
    end
  end

  describe "Transport Timeout Resilience" do
    for {label, operation} <- @timeout_operations do
      scenario "returns timeout error tuple cleanly on transport failure for #{label}" do
        @given crm_server_timing_out()
        @upon attempting_operation(unquote(Macro.escape(operation)))
        @then timeout_error_returned()
      end
    end
  end
end
