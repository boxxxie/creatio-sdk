defmodule Creatio.Features.BatchOperationsTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.BatchDSL

  describe "JSON OData $batch Execution" do
    scenario "executes mixed create, get, and delete operations and maps responses" do
      @given batch_endpoint_returning_responses([
               %{"id" => "req_1", "status" => 201, "body" => %{"Id" => "new-1"}},
               %{"id" => "req_2", "status" => 200, "body" => %{"Name" => "Alice"}},
               %{"id" => "req_3", "status" => 204, "body" => nil}
             ])
      @given new_batch()
      @given batch_create_operation("Contact", %{"Name" => "Lead"})
      @given batch_get_operation("Contact", "1")
      @given batch_delete_operation("Contact", "2")
      @upon executing_batch()
      @then batch_responses_returned([
              %{id: "req_1", status: 201, body: %{"Id" => "new-1"}, success: true},
              %{id: "req_2", status: 200, body: %{"Name" => "Alice"}, success: true},
              %{id: "req_3", status: 204, body: nil, success: true}
            ])
      @then batch_json_request_sent(request_count: 3)
    end

    scenario "converts failed batch sub-responses to structured Creatio errors" do
      @given batch_endpoint_returning_responses([
               %{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}},
               %{
                 "id" => "req_2",
                 "status" => 404,
                 "body" => %{"error" => %{"message" => "Contact does not exist"}}
               }
             ])
      @given batch_get_operation("Contact", "1")
      @given batch_get_operation("Contact", "missing")
      @upon executing_batch()
      @then batch_responses_returned([
              %{id: "req_1", status: 200, success: true},
              %{id: "req_2", status: 404, success: false}
            ])
      @then batch_response_error_converts_to(1, status: 404, message: "Contact does not exist")
    end

    scenario "sends Prefer continue-on-error header when requested" do
      @given batch_endpoint_returning_responses([
               %{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}
             ])
      @given batch_get_operation("Contact", "1")
      @upon executing_batch(continue_on_error: true)
      @then batch_prefer_header_sent("continue-on-error")
    end

    scenario "sends Prefer return=minimal and minimal metadata headers alongside continue-on-error" do
      @given batch_endpoint_returning_responses([
               %{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}
             ])
      @given new_batch(continue_on_error: true, return: :minimal)
      @given batch_get_operation("Contact", "1")
      @upon executing_batch()
      @then batch_prefer_header_sent("continue-on-error, return=minimal")
      @then batch_json_request_sent(
              request_count: 1,
              first_request_headers: %{
                "Accept" => "application/json; odata.metadata=minimal",
                "Prefer" => "continue-on-error, return=minimal"
              },
              omitted_first_request_headers: ["Content-Type"]
            )
    end

    scenario "decodes IIS text/html BOM JSON responses and rejects HTML WAF interstitials" do
      @given batch_endpoint_returning_raw(
               content_type: "text/html",
               raw_body:
                 "\uFEFF" <>
                   Jason.encode!(%{
                     "responses" => [%{"id" => "req_1", "status" => 200, "body" => %{}}]
                   })
             )
      @given batch_get_operation("Contact")
      @upon executing_batch()
      @then batch_responses_returned([%{id: "req_1", status: 200, success: true}])

      @given batch_endpoint_returning_raw(
               content_type: "text/html",
               raw_body:
                 "<html><body><iframe src=\"/_Incapsula_Resource\"></iframe></body></html>"
             )
      @given batch_get_operation("Contact")
      @upon executing_batch()
      @then batch_failed_with(status: 200)
    end

    scenario "handles single-entity JSON fallback response from Creatio batch endpoint" do
      @given batch_endpoint_returning_single_entity(%{"Id" => "solo-1", "Name" => "Solo"})
      @given batch_get_operation("Contact", "solo-1")
      @upon executing_batch()
      @then batch_responses_returned([
              %{
                id: "solo-1",
                status: 200,
                body: %{"Id" => "solo-1", "Name" => "Solo"},
                success: true
              }
            ])
    end

    scenario "executes raw request list and request map payloads and parses string status codes" do
      @given batch_endpoint_returning_responses([
               %{"id" => "raw_1", "status" => "200", "body" => %{"Name" => "RawList"}}
             ])
      @given raw_batch_requests([
               %{"id" => "raw_1", "method" => "GET", "url" => "Contact"}
             ])
      @upon executing_batch()
      @then batch_responses_returned([
              %{id: "raw_1", status: 200, body: %{"Name" => "RawList"}, success: true}
            ])
      @then batch_json_request_sent(request_count: 1)

      @given raw_batch_requests(%{
               "requests" => [%{"id" => "raw_map_1", "method" => "GET", "url" => "Account"}]
             })
      @upon executing_batch()
      @then batch_responses_returned([
              %{id: "raw_1", status: 200, body: %{"Name" => "RawList"}, success: true}
            ])
      @then batch_json_request_sent(request_count: 1)
    end
  end

  describe "Multipart/Mixed OData $batch Execution" do
    scenario "executes a multipart batch request and parses multipart sub-responses" do
      @given batch_endpoint_returning_multipart_items("batchresponse_abc", [
               %{id: "req_1", status: 201, reason: "Created", body: %{"Id" => "created-9"}},
               %{id: "req_2", status: 200, reason: "OK", body: %{"Name" => "Jane"}}
             ])
      @given batch_create_operation("Contact", %{"Name" => "Jane"})
      @given batch_get_operation("Contact", "1")
      @upon executing_batch(format: :multipart)
      @then batch_responses_returned([
              %{id: "req_1", status: 201, body: %{"Id" => "created-9"}, success: true},
              %{id: "req_2", status: 200, body: %{"Name" => "Jane"}, success: true}
            ])
      @then batch_multipart_request_sent(body_includes: "Contact")
    end

    scenario "sends a pre-encoded raw binary multipart batch payload" do
      @given batch_endpoint_returning_multipart_items("batchresponse_raw", [
               %{id: "req_1", status: 201, reason: "Created", body: %{"Id" => "raw-1"}}
             ])
      @given pre_encoded_multipart_batch("Contact", %{"Name" => "PreEncoded"})
      @upon executing_batch()
      @then batch_responses_returned([
              %{id: "req_1", status: 201, body: %{"Id" => "raw-1"}, success: true}
            ])
      @then batch_multipart_request_sent(body_includes: "PreEncoded")
    end

    scenario "delegates batch execution via OData module with multipart response" do
      @given batch_endpoint_returning_multipart_items("batchresponse_odata", [
               %{status: 200, reason: "OK", body: %{"d" => %{"results" => []}}}
             ])
      @given batch_get_operation("Contact")
      @upon executing_batch(via: :odata, format: :multipart)
      @then batch_responses_returned([
              %{status: 200, body: %{"d" => %{"results" => []}}, success: true}
            ])
    end

    scenario "executes bang batch execution via OData module" do
      @given batch_endpoint_returning_responses([
               %{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}
             ])
      @given batch_get_operation("Contact", "1")
      @upon executing_batch(via: :odata, bang: true)
      @then batch_responses_returned([%{id: "req_1", status: 200, success: true}])
    end

    scenario "sends Prefer continue-on-error header in multipart batch and surfaces HTTP errors" do
      @given batch_endpoint_returning_multipart_items("batchresponse_coe", [
               %{id: "req_1", status: 200, reason: "OK", body: %{"Id" => "1"}}
             ])
      @given batch_get_operation("Contact", "1")
      @upon executing_batch(format: :multipart, continue_on_error: true)
      @then batch_responses_returned([%{id: "req_1", status: 200, success: true}])
      @then batch_prefer_header_sent("continue-on-error")
      @then batch_multipart_request_sent(body_includes: "GET Contact(1)")

      @given batch_endpoint_failing(500, %{
               "error" => %{"code" => "BatchFailed", "message" => "Multipart batch error"}
             })
      @given batch_get_operation("Contact", "1")
      @upon executing_batch(format: :multipart)
      @then batch_failed_with(status: 500, code: "BatchFailed", message: "Multipart batch error")
    end
  end
end
