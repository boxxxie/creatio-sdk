defmodule Creatio.Features.DataServiceAndRestTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.DataServiceDSL

  describe "Creatio DataService SyncReply Queries" do
    scenario "executes SelectQuery against Creatio DataService" do
      @given data_service_endpoint("SelectQuery",
               body: %{"rows" => [%{"Id" => "1", "Name" => "Alice"}], "success" => true}
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact", "allColumns" => true})
      @then data_service_returned(%{
              "rows" => [%{"Id" => "1", "Name" => "Alice"}],
              "success" => true
            })
      @then data_service_sent_payload("SelectQuery", rootSchemaName: "Contact", allColumns: true)
    end

    scenario "executes InsertQuery, UpdateQuery, DeleteQuery, BatchQuery, and custom query actions" do
      @given data_service_endpoint("InsertQuery", body: %{"id" => "ins-1", "success" => true})
      @upon running_insert_query(%{"rootSchemaName" => "Contact"})
      @then data_service_returned(%{"id" => "ins-1", "success" => true})
      @then data_service_sent_payload("InsertQuery", rootSchemaName: "Contact")

      @given data_service_endpoint("UpdateQuery", body: %{"rowsAffected" => 1, "success" => true})
      @upon running_update_query(%{"rootSchemaName" => "Contact"})
      @then data_service_returned(%{"rowsAffected" => 1, "success" => true})

      @given data_service_endpoint("DeleteQuery", body: %{"rowsAffected" => 1, "success" => true})
      @upon running_delete_query(%{"rootSchemaName" => "Contact"})
      @then data_service_returned(%{"rowsAffected" => 1, "success" => true})

      @given data_service_endpoint("BatchQuery", body: %{"responses" => [%{"success" => true}]})
      @upon running_batch_query(%{"queries" => []})
      @then data_service_returned(%{"responses" => [%{"success" => true}]})

      @given data_service_endpoint("SchemaQuery", body: %{"schema" => "Contact"})
      @upon executing_data_service_action("SchemaQuery", %{"name" => "Contact"})
      @then data_service_returned(%{"schema" => "Contact"})
    end

    scenario "converts application-level DataService failure (success: false) into Creatio error" do
      @given data_service_endpoint("SelectQuery",
               status: 200,
               body: %{
                 "success" => false,
                 "errorInfo" => %{
                   "errorCode" => "SecurityException",
                   "message" => "Access denied"
                 }
               }
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_failed_with(
              status: 200,
              code: "SecurityException",
              message: "Access denied"
            )
      @upon running_select_query(%{"rootSchemaName" => "Contact"}, bang: true)
      @then bang_raised_creatio_error("Access denied")
    end

    scenario "decodes plain-text JSON responses from DataService for both success and error payloads" do
      @given data_service_endpoint("SelectQuery",
               content_type: "text/plain",
               body: Jason.encode!(%{"rows" => [%{"Id" => "1"}], "success" => true})
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_returned(%{"rows" => [%{"Id" => "1"}], "success" => true})

      @given data_service_endpoint("SelectQuery",
               content_type: "text/plain",
               body:
                 Jason.encode!(%{
                   "success" => false,
                   "errorInfo" => %{"errorCode" => "PlainErr", "message" => "Plain error"}
                 })
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_failed_with(status: 200, code: "PlainErr", message: "Plain error")

      @given data_service_endpoint("SelectQuery",
               content_type: "text/plain",
               body: "plain ok response"
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_failed_with(status: 200, message: "plain ok response")
    end
  end

  describe "Custom Creatio REST Services" do
    scenario "calls POST JSON, GET, keyword list payload, binary payload, headers, and 204 No Content custom REST endpoints" do
      @given custom_rest_endpoint("LeadService", "CreateLead", echo: true)
      @upon calling_custom_service("LeadService", "CreateLead", %{"Email" => "vip@acme.com"})
      @then custom_service_returned(%{"Email" => "vip@acme.com"})
      @upon calling_custom_service("LeadService", "CreateLead", [email: "kw@acme.com"],
              method: :post
            )
      @then custom_service_returned(%{"email" => "kw@acme.com"})

      @given custom_rest_endpoint("RawService", "Upload", body: %{"received" => true})
      @upon calling_custom_service("RawService", "Upload", "raw-payload",
              headers: %{"x-map-hdr" => "1"},
              params: [mode: "fast"]
            )
      @then custom_service_returned(%{"received" => true})
      @upon calling_custom_service("RawService", "Upload", "raw-payload",
              headers: [x_kw_hdr: "2"]
            )
      @then custom_service_returned(%{"received" => true})

      @given custom_rest_endpoint("HealthService", "Ping",
               method: :get,
               body: %{"status" => "ok"}
             )
      @upon calling_custom_service("HealthService", "Ping", method: :get)
      @then custom_service_returned(%{"status" => "ok"})

      @given custom_rest_endpoint("SyncService", "Trigger", status: 204)
      @upon calling_custom_service("SyncService", "Trigger", %{"force" => true})
      @then custom_service_returned("")
    end

    scenario "returns HTTP errors across POST map, GET options, list payload, and DELETE method" do
      @given custom_rest_service_failing(500)
      @upon calling_custom_service("LeadService", "CreateLead", %{})
      @then custom_service_failed_with_status(500)
      @upon calling_custom_service("HealthService", "Ping", method: :get)
      @then custom_service_failed_with_status(500)
      @upon calling_custom_service("BatchSvc", "Process", [1, 2, 3], [])
      @then custom_service_failed_with_status(500)
      @upon calling_custom_service("LeadService", "Remove", %{"x" => 1}, method: :delete)
      @then custom_service_failed_with_status(500)
    end

    scenario "handles 4-arg custom_service! with non-keyword list payload on success and failure" do
      @given custom_rest_endpoint("BatchSvc", "Process", body: %{"processed" => 3})
      @upon calling_custom_service("BatchSvc", "Process", [1, 2, 3], bang: true)
      @then custom_service_returned(%{"processed" => 3})

      @given custom_rest_endpoint("BatchSvc", "Process",
               status: 500,
               body: %{"error" => %{"message" => "Batch failed"}}
             )
      @upon calling_custom_service("BatchSvc", "Process", [1, 2, 3], bang: true)
      @then bang_raised_creatio_error("Batch failed")
    end
  end
end
