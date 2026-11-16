defmodule Creatio.Features.DataServiceAndRestTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.DataServiceDSL

  @waf_html "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"

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

      @given custom_rest_endpoint("Svc", "EmptyList", echo: true)
      @upon calling_custom_service("Svc", "EmptyList", [])
      @then custom_service_returned([])
      @then custom_service_sent_request(method: "POST", decoded_body: [])

      @given custom_rest_endpoint("Svc", "Fetch", method: :get, body: %{"ok" => true})
      @upon calling_custom_service("Svc", "Fetch",
              method: :get,
              params: %{"id" => "42", :extra => "yes"}
            )
      @then custom_service_returned(%{"ok" => true})

      @then custom_service_sent_request(
              method: "GET",
              query_params: %{"id" => "42", "extra" => "yes"}
            )

      @given custom_rest_endpoint("Svc", "Remove", method: :delete, echo: true)
      @upon calling_custom_service("Svc", "Remove", %{"ids" => ["1"]}, method: :delete)
      @then custom_service_returned(%{"ids" => ["1"]})
      @then custom_service_sent_request(method: "DELETE", decoded_body: %{"ids" => ["1"]})

      @given custom_rest_endpoint("CustomSvc", "DoWork", echo: true)
      @upon calling_custom_service("CustomSvc", "DoWork", alpha: 1, beta: "two")
      @then custom_service_returned(%{"alpha" => 1, "beta" => "two"})
      @then custom_service_sent_request(
              method: "POST",
              decoded_body: %{"alpha" => 1, "beta" => "two"}
            )
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

    scenario "decodes IIS text/html BOM JSON and rejects WAF HTML and corrupt payloads" do
      @given data_service_endpoint("SelectQuery",
               content_type: "text/html",
               raw_body:
                 "\uFEFF" <> Jason.encode!(%{"success" => true, "rows" => [%{"Id" => "ds-1"}]})
             )
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_returned(%{"success" => true, "rows" => [%{"Id" => "ds-1"}]})

      @given custom_rest_endpoint("MySvc", "Info",
               method: :get,
               content_type: "text/html",
               raw_body: "\uFEFF" <> Jason.encode!(%{"ok" => true})
             )
      @upon calling_custom_service("MySvc", "Info", method: :get)
      @then custom_service_returned(%{"ok" => true})

      @given data_service_endpoint("SelectQuery", content_type: "text/html", raw_body: @waf_html)
      @upon running_select_query(%{"rootSchemaName" => "Contact"})
      @then data_service_failed_with(status: 200)

      @given custom_rest_endpoint("MySvc", "Info",
               method: :get,
               content_type: "text/html",
               raw_body: @waf_html
             )
      @upon calling_custom_service("MySvc", "Info", method: :get)
      @then custom_service_failed_with_status(200)

      @given data_service_endpoint("SelectQuery",
               content_type: "application/json",
               raw_body: "{broken"
             )
      @upon running_select_query(%{})
      @then data_service_failed_with(status: nil)

      @given data_service_endpoint("SelectQuery", content_type: "text/plain", raw_body: "{broken")
      @upon running_select_query(%{})
      @then data_service_failed_with(status: 200)

      @given data_service_endpoint("SelectQuery",
               content_type: "text/plain",
               raw_body: "Gateway Timeout"
             )
      @upon running_select_query(%{})
      @then data_service_failed_with(status: 200)
    end
  end
end
