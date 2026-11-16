defmodule Creatio.Features.SdkFacadeAndResilienceTest do
  use ExUnit.Case, async: true

  import Creatio.FeatureScenario
  import Creatio.TestDSL.AuthDSL
  import Creatio.TestDSL.ODataDSL
  import Creatio.TestDSL.SafetyDSL

  alias Creatio.{Auth, Batch, DataService, Error, OData, OData3}
  alias Creatio.Batch.Response, as: BatchResponse
  alias Creatio.OData.Query
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

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

  describe "Core Facade Workflows & Error Resilience Scenarios" do
    scenario "executes an end-to-end Creatio facade workflow across auth, query, create, update, and delete" do
      @given creatio_forms_auth_accepting(
               cookies: [".ASPXAUTH=Tok; path=/", "BPMCSRF=csrf_1; path=/"]
             )
      @given odata_collection("Contact", records: [%{"Id" => "c-1", "Name" => "Alice"}])
      @given odata_creatable_entity("Contact", assigned_id: "c-2")
      @given odata_updatable_entity("Contact", "c-2")
      @given odata_deletable_entity("Contact", "c-2")
      @upon logging_in_with_forms("Supervisor", "Supervisor", facade: true)
      @then client_is_authenticated_via_forms(
              csrf_token: "csrf_1",
              cookies_include: [".ASPXAUTH=Tok"]
            )
      @upon listing_entities(Creatio.query("Contact"), query_first: true, facade: true)
      @then entities_returned([%{"Id" => "c-1", "Name" => "Alice"}])
      @upon creating_entity("Contact", %{"Name" => "Bob"}, facade: true)
      @then entity_created_with(%{"Id" => "c-2", "Name" => "Bob"})
      @upon updating_entity("Contact", "c-2", %{"Name" => "Bobby"}, facade: true)
      @then mutation_succeeded()
      @upon deleting_entity("Contact", "c-2", facade: true)
      @then mutation_succeeded()
    end

    scenario "bang (!) facade operations return unwrapped 200 results and raise Creatio.Error on 500 failure" do
      @given odata_entity("Contact", "c-1", record: %{"Id" => "c-1", "Name" => "Alice"})
      @upon getting_entity("Contact", "c-1", facade: true, bang: true)
      @then entity_returned(%{"Id" => "c-1", "Name" => "Alice"})
      @given crm_server_failing_with_status(500, %{"error" => %{"message" => "Internal failure"}})
      @upon getting_entity("Contact", "c-1", facade: true, bang: true)
      @then bang_raised_error(status: 500, message: "Internal failure")
    end

    scenario "non-bang facade operations propagate structured Creatio.Error tuples on HTTP 500" do
      @given crm_server_failing_with_status(
               500,
               %{"error" => %{"code" => "ServerError", "message" => "Backend down"}}
             )
      @upon getting_entity("Contact", "c-1", facade: true)
      @then operation_returned_error(status: 500, code: "ServerError", message: "Backend down")
    end

    scenario "non-bang streams yield prior records, emit error tuple, and halt while stream! raises" do
      @given odata_pages("Contact", [
               {200, %{"value" => [%{"Id" => "1"}]}},
               {500, %{"error" => %{"message" => "Page 2 failed"}}}
             ])
      @upon streaming_entities("Contact", page_size: 1, facade: true)
      @then stream_yielded_prefix_then_error(
              [%{"Id" => "1"}],
              status: 500,
              message: "Page 2 failed"
            )
      @given odata3_pages("Contact", [{500, %{"error" => %{"message" => "OData3 failure"}}}])
      @upon streaming_odata3_entities("Contact", page_size: 1, facade: true)
      @then stream_emitted_error(status: 500, message: "OData3 failure")
      @given odata_pages("Contact", [{500, %{"error" => %{"message" => "Stream boom"}}}])
      @upon streaming_entities("Contact", page_size: 1, facade: true, bang: true)
      @then bang_raised_error(status: 500, message: "Stream boom")
    end

    scenario "facade stream/3 yields ok tuples across pages while stream!/3 yields plain maps" do
      @given odata_paginated_collection("Contact", [%{"Id" => "1"}, %{"Id" => "2"}])
      @upon streaming_entities("Contact", page_size: 1, facade: true)
      @then streamed_entities_match([{:ok, %{"Id" => "1"}}, {:ok, %{"Id" => "2"}}])
      @upon streaming_entities("Contact", page_size: 1, facade: true, bang: true)
      @then streamed_entities_match([%{"Id" => "1"}, %{"Id" => "2"}])
    end

    scenario "returns structured timeout error tuple cleanly when transport times out" do
      @given crm_server_timing_out()
      @upon getting_entity("Contact", "1", facade: true)
      @then timeout_error_returned()
    end
  end

  describe "SDK API Contract Sweeps" do
    test "top-level Creatio facade delegates accurately across client-first, query-first, and entity-first signatures",
         ctx do
      ctx = stub_facade_endpoints(ctx)

      client =
        CreatioServerDriver.client(ctx,
          identity_service_url: "https://mycreatio.com",
          client_id: "c",
          client_secret: "s"
        )

      req_opts = CreatioServerDriver.req_options_for_server(ctx)

      Enum.each(facade_cases(client, req_opts), fn {label, invoke_fun, expected} ->
        actual = invoke_fun.()

        case expected do
          {:ok_batch_response_count, expected_count} ->
            assert {:ok, [%BatchResponse{} | _] = responses} = actual,
                   "Expected {:ok, [BatchResponse]} (#{expected_count}) for #{label}, got: #{inspect(actual)}"

            assert length(responses) == expected_count

          {:batch_response_count, expected_count} ->
            assert [%BatchResponse{} | _] = responses = actual,
                   "Expected [BatchResponse] (#{expected_count}) for #{label}, got: #{inspect(actual)}"

            assert length(responses) == expected_count

          expected_val ->
            assert expected_val == actual,
                   "Facade delegation mismatch for #{label}: expected #{inspect(expected_val)}, got #{inspect(actual)}"
        end
      end)
    end

    test "all 36 bang (!) SDK operations raise %Creatio.Error{status: 500} on server failure",
         ctx do
      ctx =
        ctx
        |> CreatioServerDriver.ensure_server()
        |> CreatioServerDriver.stub_all_error(500, %{"error" => %{"message" => "Boom"}})

      client = CreatioServerDriver.client(ctx)

      Enum.each(bang_error_operations(client), fn {label, invoke_fun} ->
        result = CRMClientDriver.capture_bang(invoke_fun)

        assert {:raised, %Error{status: 500}} = result,
               "Expected #{label} to raise %Creatio.Error{status: 500}, got: #{inspect(result)}"
      end)
    end

    test "non-bang operations return %Creatio.Error{} tuples (including param normalization) and streams halt on 500",
         ctx do
      ctx =
        ctx
        |> CreatioServerDriver.ensure_server()
        |> CreatioServerDriver.stub_all_error(500, %{"error" => %{"message" => "Boom"}})

      client = CreatioServerDriver.client(ctx)

      oauth_client =
        CreatioServerDriver.client(ctx,
          client_id: "c",
          client_secret: "s",
          identity_service_url: "https://mycreatio.com"
        )

      req_opts = CreatioServerDriver.req_options_for_server(ctx)

      Enum.each(stream_error_operations(client), fn {label, invoke_fun} ->
        items = invoke_fun.()

        assert [{:error, %Error{status: 500}}] = items,
               "Expected single error tuple for #{label}, got: #{inspect(items)}"
      end)

      Enum.each(tuple_error_operations(client, oauth_client, req_opts), fn {label,
                                                                            expected_status,
                                                                            invoke_fun} ->
        result = invoke_fun.()

        assert {:error, %Error{status: status}} = result,
               "Expected {:error, %Creatio.Error{}} for #{label}, got: #{inspect(result)}"

        assert status == expected_status,
               "Expected status #{inspect(expected_status)} for #{label}, got: #{inspect(status)}"
      end)
    end

    test "all 34 transport operations return timeout error tuple cleanly on transport timeout",
         ctx do
      ctx =
        ctx
        |> CreatioServerDriver.ensure_server()
        |> CreatioServerDriver.use_transport_timeout()

      client = CreatioServerDriver.client(ctx)

      oauth_client =
        CreatioServerDriver.client(ctx,
          client_id: "c",
          client_secret: "s",
          identity_service_url: "https://mycreatio.com"
        )

      req_opts = CreatioServerDriver.req_options_for_server(ctx)

      Enum.each(timeout_operations(client, oauth_client, req_opts), fn {label, invoke_fun} ->
        result = invoke_fun.()

        assert {:error, %Error{message: "timeout"}} = result,
               "Expected timeout error for #{label}, got: #{inspect(result)}"
      end)
    end
  end

  defp stub_facade_endpoints(ctx) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_list("Contact",
      records: [%{"Id" => "1", "Name" => "Test"}]
    )
    |> CreatioServerDriver.stub_odata_get("Contact", "1",
      record: %{"Id" => "1", "Name" => "Test"}
    )
    |> CreatioServerDriver.stub_odata_create("Contact", assigned_id: "new-id")
    |> CreatioServerDriver.stub_odata_update("Contact", "1")
    |> CreatioServerDriver.stub_odata_delete("Contact", "1")
    |> CreatioServerDriver.stub_odata_count("Contact", count: 42)
    |> CreatioServerDriver.stub_odata_navigation("Contact", "1", "Account",
      record: %{"Name" => "Acme"}
    )
    |> CreatioServerDriver.stub_odata_field("Contact", "1", "Name", value: "Test")
    |> CreatioServerDriver.stub_odata_field("Contact", "1", "Name", value: "RawName", raw: true)
    |> CreatioServerDriver.stub_odata_update_field("Contact", "1", "Photo")
    |> CreatioServerDriver.stub_odata_delete_field("Contact", "1", "Photo")
    |> CreatioServerDriver.stub_data_service("SelectQuery",
      body: %{"rows" => [%{"Name" => "Corp"}], "success" => true}
    )
    |> CreatioServerDriver.stub_data_service("InsertQuery", body: %{"id" => "inserted-id"})
    |> CreatioServerDriver.stub_data_service("UpdateQuery", body: %{"rowsAffected" => 1})
    |> CreatioServerDriver.stub_data_service("DeleteQuery", body: %{"rowsAffected" => 1})
    |> CreatioServerDriver.stub_data_service("BatchQuery", body: %{"responses" => []})
    |> CreatioServerDriver.stub_data_service("GenericAction", body: %{"success" => true})
    |> CreatioServerDriver.stub_custom_service("CustomSvc", "Echo", echo: true)
    |> CreatioServerDriver.stub_custom_service("CustomSvc", "Ping",
      method: :get,
      body: %{"status" => "pong"}
    )
    |> CreatioServerDriver.stub_odata3_list("Contact", records: [%{"Name" => "Legacy"}])
    |> CreatioServerDriver.stub_odata3_get("Contact", "1", record: %{"Name" => "Legacy"})
    |> CreatioServerDriver.stub_odata3_navigation("Contact", "1", "Account",
      record: %{"Name" => "Legacy Org"}
    )
    |> CreatioServerDriver.stub_odata3_field("Contact", "1", "Name", value: "Legacy Name")
    |> CreatioServerDriver.stub_odata3_field("Contact", "1", "Name",
      value: "Raw Legacy Name",
      raw: true
    )
    |> CreatioServerDriver.stub_odata3_count("Contact", count: 99)
    |> CreatioServerDriver.stub_odata3_create("Contact", body: %{"d" => %{"Id" => "new-1"}})
    |> CreatioServerDriver.stub_odata3_update("Contact", "1")
    |> CreatioServerDriver.stub_odata3_delete("Contact", "1")
    |> CreatioServerDriver.stub_batch(
      responses: [%{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}]
    )
    |> CreatioServerDriver.stub_forms_login(
      cookies: [".ASPXAUTH=FacadeToken; path=/", "BPMCSRF=facade_csrf; path=/"]
    )
    |> CreatioServerDriver.stub_oauth_token(access_token: "facade_oauth_token")
    |> CreatioServerDriver.stub_oauth_health(body: %{"status" => "Healthy"})
    |> CreatioServerDriver.stub_openid_configuration(body: %{"issuer" => "test"})
  end

  defp facade_cases(client, req_opts) do
    sample_raw =
      """
      --batchresponse_sample
      Content-Type: application/http
      Content-Transfer-Encoding: binary
      Content-ID: req_1

      HTTP/1.1 200 OK
      Content-Type: application/json

      {"Id":"1","Name":"Test"}
      --batchresponse_sample--
      """
      |> String.replace("\n", "\r\n")

    batch = Creatio.batch_new() |> Batch.add_get("Contact", "1")
    record = %{"Id" => "1", "Name" => "Test"}
    legacy = %{"Name" => "Legacy"}

    [
      {"OData list/2", fn -> Creatio.list(client, "Contact") end, {:ok, [record]}},
      {"OData list!/2", fn -> Creatio.list!(client, "Contact") end, [record]},
      {"OData list/2 query-first", fn -> Creatio.list(Query.new("Contact"), client) end,
       {:ok, [record]}},
      {"OData list!/2 query-first", fn -> Creatio.list!(Query.new("Contact"), client) end,
       [record]},
      {"OData list/2 entity-first", fn -> Creatio.list("Contact", client) end, {:ok, [record]}},
      {"OData list!/2 entity-first", fn -> Creatio.list!("Contact", client) end, [record]},
      {"OData execute/2", fn -> Creatio.execute(client, "Contact") end, {:ok, [record]}},
      {"OData execute!/2", fn -> Creatio.execute!(client, "Contact") end, [record]},
      {"OData execute/2 query-first", fn -> Creatio.execute(Query.new("Contact"), client) end,
       {:ok, [record]}},
      {"OData execute!/2 query-first", fn -> Creatio.execute!(Query.new("Contact"), client) end,
       [record]},
      {"OData execute/2 entity-first", fn -> Creatio.execute("Contact", client) end,
       {:ok, [record]}},
      {"OData execute!/2 entity-first", fn -> Creatio.execute!("Contact", client) end, [record]},
      {"OData get/3", fn -> Creatio.get(client, "Contact", "1") end, {:ok, record}},
      {"OData get!/3", fn -> Creatio.get!(client, "Contact", "1") end, record},
      {"OData create/3", fn -> Creatio.create(client, "Contact", %{"Name" => "New"}) end,
       {:ok, %{"Id" => "new-id", "Name" => "New"}}},
      {"OData create!/3", fn -> Creatio.create!(client, "Contact", %{"Name" => "New"}) end,
       %{"Id" => "new-id", "Name" => "New"}},
      {"OData update/4", fn -> Creatio.update(client, "Contact", "1", %{"Name" => "U"}) end, :ok},
      {"OData update!/4", fn -> Creatio.update!(client, "Contact", "1", %{"Name" => "U"}) end,
       :ok},
      {"OData delete/3", fn -> Creatio.delete(client, "Contact", "1") end, :ok},
      {"OData delete!/3", fn -> Creatio.delete!(client, "Contact", "1") end, :ok},
      {"OData count/2", fn -> Creatio.count(client, "Contact") end, {:ok, 42}},
      {"OData count!/2", fn -> Creatio.count!(client, "Contact") end, 42},
      {"OData get_navigation/4",
       fn -> Creatio.get_navigation(client, "Contact", "1", "Account") end,
       {:ok, %{"Name" => "Acme"}}},
      {"OData get_navigation!/4",
       fn -> Creatio.get_navigation!(client, "Contact", "1", "Account") end, %{"Name" => "Acme"}},
      {"OData get_field/4", fn -> Creatio.get_field(client, "Contact", "1", "Name") end,
       {:ok, "Test"}},
      {"OData get_field!/4", fn -> Creatio.get_field!(client, "Contact", "1", "Name") end,
       "Test"},
      {"OData get_field_value/4",
       fn -> Creatio.get_field_value(client, "Contact", "1", "Name") end, {:ok, "RawName"}},
      {"OData get_field_value!/4",
       fn -> Creatio.get_field_value!(client, "Contact", "1", "Name") end, "RawName"},
      {"OData update_field/5",
       fn -> Creatio.update_field(client, "Contact", "1", "Photo", "bin") end, :ok},
      {"OData update_field!/5",
       fn -> Creatio.update_field!(client, "Contact", "1", "Photo", "bin") end, :ok},
      {"OData delete_field/4", fn -> Creatio.delete_field(client, "Contact", "1", "Photo") end,
       :ok},
      {"OData delete_field!/4", fn -> Creatio.delete_field!(client, "Contact", "1", "Photo") end,
       :ok},
      {"OData stream/3", fn -> Creatio.stream(client, "Contact", []) |> Enum.to_list() end,
       [{:ok, record}]},
      {"OData stream!/3", fn -> Creatio.stream!(client, "Contact", []) |> Enum.to_list() end,
       [record]},
      {"OData stream/3 query-first",
       fn -> Creatio.stream(Query.new("Contact"), client, []) |> Enum.to_list() end,
       [{:ok, record}]},
      {"OData stream!/3 query-first",
       fn -> Creatio.stream!(Query.new("Contact"), client, []) |> Enum.to_list() end, [record]},
      {"OData stream/2 entity-first", fn -> Creatio.stream("Contact", client) |> Enum.take(1) end,
       [{:ok, record}]},
      {"OData stream!/2 entity-first",
       fn -> Creatio.stream!("Contact", client) |> Enum.take(1) end, [record]},
      {"DataService select_query/2", fn -> Creatio.select_query(client, %{}) end,
       {:ok, %{"rows" => [%{"Name" => "Corp"}], "success" => true}}},
      {"DataService select_query!/2", fn -> Creatio.select_query!(client, %{}) end,
       %{"rows" => [%{"Name" => "Corp"}], "success" => true}},
      {"DataService insert_query/2", fn -> Creatio.insert_query(client, %{}) end,
       {:ok, %{"id" => "inserted-id"}}},
      {"DataService insert_query!/2", fn -> Creatio.insert_query!(client, %{}) end,
       %{"id" => "inserted-id"}},
      {"DataService update_query/2", fn -> Creatio.update_query(client, %{}) end,
       {:ok, %{"rowsAffected" => 1}}},
      {"DataService update_query!/2", fn -> Creatio.update_query!(client, %{}) end,
       %{"rowsAffected" => 1}},
      {"DataService delete_query/2", fn -> Creatio.delete_query(client, %{}) end,
       {:ok, %{"rowsAffected" => 1}}},
      {"DataService delete_query!/2", fn -> Creatio.delete_query!(client, %{}) end,
       %{"rowsAffected" => 1}},
      {"DataService batch_query/2", fn -> Creatio.batch_query(client, %{}) end,
       {:ok, %{"responses" => []}}},
      {"DataService batch_query!/2", fn -> Creatio.batch_query!(client, %{}) end,
       %{"responses" => []}},
      {"DataService data_service_query/3",
       fn -> Creatio.data_service_query(client, "GenericAction", %{}) end,
       {:ok, %{"success" => true}}},
      {"DataService data_service_query!/3",
       fn -> Creatio.data_service_query!(client, "GenericAction", %{}) end, %{"success" => true}},
      {"CustomService 5-arg POST echo",
       fn -> Creatio.custom_service(client, "CustomSvc", "Echo", %{"a" => 1}, []) end,
       {:ok, %{"a" => 1}}},
      {"CustomService! 5-arg POST echo",
       fn -> Creatio.custom_service!(client, "CustomSvc", "Echo", %{"a" => 1}, []) end,
       %{"a" => 1}},
      {"CustomService 4-arg GET",
       fn -> Creatio.custom_service(client, "CustomSvc", "Ping", method: :get) end,
       {:ok, %{"status" => "pong"}}},
      {"CustomService! 4-arg GET",
       fn -> Creatio.custom_service!(client, "CustomSvc", "Ping", method: :get) end,
       %{"status" => "pong"}},
      {"OData 3 list/2", fn -> Creatio.odata3_list(client, "Contact") end, {:ok, [legacy]}},
      {"OData 3 list!/2", fn -> Creatio.odata3_list!(client, "Contact") end, [legacy]},
      {"OData 3 list/2 query-first", fn -> Creatio.odata3_list(Query.new("Contact"), client) end,
       {:ok, [legacy]}},
      {"OData 3 list!/2 query-first",
       fn -> Creatio.odata3_list!(Query.new("Contact"), client) end, [legacy]},
      {"OData 3 list/2 entity-first", fn -> Creatio.odata3_list("Contact", client) end,
       {:ok, [legacy]}},
      {"OData 3 list!/2 entity-first", fn -> Creatio.odata3_list!("Contact", client) end,
       [legacy]},
      {"OData 3 get/3", fn -> Creatio.odata3_get(client, "Contact", "1") end, {:ok, legacy}},
      {"OData 3 get!/3", fn -> Creatio.odata3_get!(client, "Contact", "1") end, legacy},
      {"OData 3 get_navigation/4",
       fn -> Creatio.odata3_get_navigation(client, "Contact", "1", "Account") end,
       {:ok, %{"Name" => "Legacy Org"}}},
      {"OData 3 get_navigation!/4",
       fn -> Creatio.odata3_get_navigation!(client, "Contact", "1", "Account") end,
       %{"Name" => "Legacy Org"}},
      {"OData 3 get_field/4", fn -> Creatio.odata3_get_field(client, "Contact", "1", "Name") end,
       {:ok, "Legacy Name"}},
      {"OData 3 get_field!/4",
       fn -> Creatio.odata3_get_field!(client, "Contact", "1", "Name") end, "Legacy Name"},
      {"OData 3 get_field_value/4",
       fn -> Creatio.odata3_get_field_value(client, "Contact", "1", "Name") end,
       {:ok, "Raw Legacy Name"}},
      {"OData 3 get_field_value!/4",
       fn -> Creatio.odata3_get_field_value!(client, "Contact", "1", "Name") end,
       "Raw Legacy Name"},
      {"OData 3 count/2", fn -> Creatio.odata3_count(client, "Contact") end, {:ok, 99}},
      {"OData 3 count!/2", fn -> Creatio.odata3_count!(client, "Contact") end, 99},
      {"OData 3 create/3", fn -> Creatio.odata3_create(client, "Contact", %{"Name" => "L"}) end,
       {:ok, %{"Id" => "new-1"}}},
      {"OData 3 create!/3", fn -> Creatio.odata3_create!(client, "Contact", %{"Name" => "L"}) end,
       %{"Id" => "new-1"}},
      {"OData 3 update/4",
       fn -> Creatio.odata3_update(client, "Contact", "1", %{"Name" => "U"}) end, :ok},
      {"OData 3 update!/4",
       fn -> Creatio.odata3_update!(client, "Contact", "1", %{"Name" => "U"}) end, :ok},
      {"OData 3 delete/3", fn -> Creatio.odata3_delete(client, "Contact", "1") end, :ok},
      {"OData 3 delete!/3", fn -> Creatio.odata3_delete!(client, "Contact", "1") end, :ok},
      {"OData 3 stream/3",
       fn -> Creatio.odata3_stream(client, "Contact", []) |> Enum.to_list() end, [{:ok, legacy}]},
      {"OData 3 stream!/3",
       fn -> Creatio.odata3_stream!(client, "Contact", []) |> Enum.to_list() end, [legacy]},
      {"OData 3 stream/3 query-first",
       fn -> Creatio.odata3_stream(Query.new("Contact"), client, []) |> Enum.to_list() end,
       [{:ok, legacy}]},
      {"OData 3 stream!/3 query-first",
       fn -> Creatio.odata3_stream!(Query.new("Contact"), client, []) |> Enum.to_list() end,
       [legacy]},
      {"OData 3 stream/2 entity-first",
       fn -> Creatio.odata3_stream("Contact", client) |> Enum.take(1) end, [{:ok, legacy}]},
      {"OData 3 stream!/2 entity-first",
       fn -> Creatio.odata3_stream!("Contact", client) |> Enum.take(1) end, [legacy]},
      {"Batch execute/2", fn -> Creatio.batch(client, batch) end, {:ok_batch_response_count, 1}},
      {"Batch execute!/2", fn -> Creatio.batch!(client, batch) end, {:batch_response_count, 1}},
      {"Batch to_multipart/1",
       fn ->
         {boundary, _body} = Creatio.batch_to_multipart(batch)
         is_binary(boundary)
       end, true},
      {"Batch to_multipart_iodata/2",
       fn ->
         {boundary, iodata} = Creatio.batch_to_multipart_iodata(batch, boundary: "b_custom")
         {boundary, is_list(iodata)}
       end, {"b_custom", true}},
      {"Batch parse_multipart/2",
       fn -> Creatio.batch_parse_multipart(sample_raw, "batchresponse_sample") end,
       {:ok_batch_response_count, 1}},
      {"Query builder query/1",
       fn ->
         q = Creatio.query("Contact") |> Query.select(["Id", "Name"])
         %{entity: Query.entity(q), select: Query.to_params(q)["$select"]}
       end, %{entity: "Contact", select: "Id,Name"}},
      {"Client constructor new/1",
       fn -> Creatio.new(base_url: "https://mycreatio.com").base_url end,
       "https://mycreatio.com"},
      {"Client constructor from_req/1",
       fn ->
         Req.new(base_url: "https://mycreatio.com") |> Creatio.from_req() |> Map.get(:base_url)
       end, "https://mycreatio.com"},
      {"Auth login/3",
       fn ->
         {:ok, authed} = Creatio.login(client, "Supervisor", "Supervisor")
         authed.auth_mode
       end, :forms},
      {"Auth login_oauth/1",
       fn ->
         {:ok, authed, token} = Creatio.login_oauth(client)
         {authed.auth_mode, token["access_token"]}
       end, {:bearer, "facade_oauth_token"}},
      {"Auth oauth_health_check/1", fn -> Creatio.oauth_health_check(client) end,
       {:ok, %{"status" => "Healthy"}}},
      {"Auth openid_configuration/1",
       fn -> Creatio.openid_configuration(client, req_options: req_opts) end,
       {:ok, %{"issuer" => "test"}}}
    ]
  end

  defp bang_error_operations(client) do
    [
      {"OData list!", fn -> OData.list!(client, "Contact") end},
      {"OData list! query-first", fn -> OData.list!(Query.new("Contact"), client, []) end},
      {"OData execute!", fn -> OData.execute!(client, "Contact") end},
      {"OData get!", fn -> OData.get!(client, "Contact", "123") end},
      {"OData get_navigation!",
       fn -> OData.get_navigation!(client, "Contact", "123", "Account") end},
      {"OData get_field!", fn -> OData.get_field!(client, "Contact", "123", "Name") end},
      {"OData get_field_value!",
       fn -> OData.get_field_value!(client, "Contact", "123", "Name") end},
      {"OData count!", fn -> OData.count!(client, "Contact") end},
      {"OData create!", fn -> OData.create!(client, "Contact", %{}) end},
      {"OData update!", fn -> OData.update!(client, "Contact", "123", %{}) end},
      {"OData delete!", fn -> OData.delete!(client, "Contact", "123") end},
      {"OData update_field!",
       fn -> OData.update_field!(client, "Contact", "123", "Name", "X") end},
      {"OData delete_field!", fn -> OData.delete_field!(client, "Contact", "123", "Name") end},
      {"OData stream! query-first",
       fn -> OData.stream!(Query.new("Contact"), client, []) |> Enum.to_list() end},
      {"OData 3 list!", fn -> OData3.list!(client, "Contact") end},
      {"OData 3 list! query-first", fn -> OData3.list!(Query.new("Contact"), client, []) end},
      {"OData 3 get!", fn -> OData3.get!(client, "Contact", "123") end},
      {"OData 3 get_navigation!",
       fn -> OData3.get_navigation!(client, "Contact", "123", "Account") end},
      {"OData 3 get_field!", fn -> OData3.get_field!(client, "Contact", "123", "Name") end},
      {"OData 3 get_field_value!",
       fn -> OData3.get_field_value!(client, "Contact", "123", "Name") end},
      {"OData 3 count!", fn -> OData3.count!(client, "Contact") end},
      {"OData 3 create!", fn -> OData3.create!(client, "Contact", %{}) end},
      {"OData 3 update!", fn -> OData3.update!(client, "Contact", "123", %{}) end},
      {"OData 3 delete!", fn -> OData3.delete!(client, "Contact", "123") end},
      {"OData 3 stream! query-first",
       fn -> OData3.stream!(Query.new("Contact"), client, []) |> Enum.to_list() end},
      {"DataService select_query!", fn -> DataService.select_query!(client, %{}) end},
      {"DataService insert_query!", fn -> DataService.insert_query!(client, %{}) end},
      {"DataService update_query!", fn -> DataService.update_query!(client, %{}) end},
      {"DataService delete_query!", fn -> DataService.delete_query!(client, %{}) end},
      {"DataService batch_query!", fn -> DataService.batch_query!(client, %{}) end},
      {"DataService execute_query!",
       fn -> DataService.execute_query!(client, "GenericAction", %{}) end},
      {"CustomService 4-arg bang",
       fn -> DataService.custom_service!(client, "CustomSvc", "Ping", method: :get) end},
      {"CustomService 5-arg bang",
       fn ->
         DataService.custom_service!(client, "CustomSvc", "Echo", %{"a" => 1}, method: :post)
       end},
      {"Creatio batch! with empty requests", fn -> Creatio.batch!(client, []) end},
      {"Creatio stream!", fn -> Creatio.stream!(client, "Contact") |> Enum.to_list() end},
      {"Creatio odata3_stream!",
       fn -> Creatio.odata3_stream!(client, "Contact") |> Enum.to_list() end}
    ]
  end

  defp stream_error_operations(client) do
    [
      {"OData stream/3 query-first",
       fn -> OData.stream(Query.new("Contact"), client, []) |> Enum.to_list() end},
      {"OData 3 stream/3 query-first",
       fn -> OData3.stream(Query.new("Contact"), client, []) |> Enum.to_list() end},
      {"Creatio stream/3", fn -> Creatio.stream(client, "Contact") |> Enum.to_list() end},
      {"Creatio odata3_stream/3",
       fn -> Creatio.odata3_stream(client, "Contact") |> Enum.to_list() end}
    ]
  end

  defp tuple_error_operations(client, oauth_client, req_opts) do
    map_params = %{"$select" => ["Id", "Name"], "$filter" => "Active eq true"}

    [
      {"OData list with full keyword parameter normalization", 500,
       fn -> OData.list(client, "Contact", @normalized_params) end},
      {"OData list with map parameter normalization", 500,
       fn -> OData.list(client, "Contact", map_params) end},
      {"OData 3 list with full keyword parameter normalization", 500,
       fn -> OData3.list(client, "Contact", @normalized_params) end},
      {"OData 3 list with map parameter normalization", 500,
       fn -> OData3.list(client, "Contact", map_params) end},
      {"DataService execute_query", 500,
       fn -> DataService.execute_query(client, "GenericAction", %{}) end},
      {"Creatio batch with empty requests", 500, fn -> Creatio.batch(client, []) end},
      {"Creatio Forms login", 500, fn -> Creatio.login(client, "u", "p") end},
      {"Creatio OAuth login with explicit token_path", 500,
       fn ->
         Auth.login_oauth(oauth_client,
           token_path: "https://identity.mycreatio.com/connect/token"
         )
       end},
      {"Creatio OAuth login without credentials", nil, fn -> Creatio.login_oauth(client) end},
      {"Creatio OAuth health check", 500, fn -> Creatio.oauth_health_check(client) end},
      {"Creatio OpenID config with explicit url opt", 500,
       fn ->
         Auth.openid_configuration(
           client,
           Keyword.merge([req_options: req_opts],
             url: "https://identity.mycreatio.com/.well-known/openid-configuration"
           )
         )
       end},
      {"Creatio OpenID config via client", 500,
       fn -> Creatio.openid_configuration(client, req_options: req_opts) end},
      {"Creatio OpenID config via direct URL", 500,
       fn ->
         Creatio.openid_configuration("https://identity.mycreatio.com", req_options: req_opts)
       end}
    ]
  end

  defp timeout_operations(client, oauth_client, req_opts) do
    [
      {"Auth login_forms", fn -> Auth.login_forms(client, "u", "p") end},
      {"Auth login_oauth", fn -> Auth.login_oauth(oauth_client, []) end},
      {"Auth oauth_health_check", fn -> Auth.oauth_health_check(client) end},
      {"Auth openid_configuration",
       fn -> Auth.openid_configuration(client, req_options: req_opts) end},
      {"OData list", fn -> OData.list(client, "Account") end},
      {"OData execute", fn -> OData.execute(client, "Account") end},
      {"OData get", fn -> OData.get(client, "Account", "1") end},
      {"OData count", fn -> OData.count(client, "Account") end},
      {"OData count top_zero", fn -> OData.count(client, "Account", strategy: :top_zero) end},
      {"OData create", fn -> OData.create(client, "Account", %{}) end},
      {"OData update", fn -> OData.update(client, "Account", "1", %{}) end},
      {"OData delete", fn -> OData.delete(client, "Account", "1") end},
      {"OData get_navigation",
       fn -> OData.get_navigation(client, "Account", "1", "PrimaryContact") end},
      {"OData get_field", fn -> OData.get_field(client, "Account", "1", "Name") end},
      {"OData get_field_value", fn -> OData.get_field_value(client, "Account", "1", "Name") end},
      {"OData update_field",
       fn -> OData.update_field(client, "Account", "1", "Name", "Acme") end},
      {"OData delete_field", fn -> OData.delete_field(client, "Account", "1", "Name") end},
      {"OData 3 list", fn -> OData3.list(client, "Account") end},
      {"OData 3 get", fn -> OData3.get(client, "Account", "1") end},
      {"OData 3 count", fn -> OData3.count(client, "Account") end},
      {"OData 3 create", fn -> OData3.create(client, "Account", %{}) end},
      {"OData 3 update", fn -> OData3.update(client, "Account", "1", %{}) end},
      {"OData 3 delete", fn -> OData3.delete(client, "Account", "1") end},
      {"OData 3 get_navigation",
       fn -> OData3.get_navigation(client, "Account", "1", "PrimaryContact") end},
      {"OData 3 get_field", fn -> OData3.get_field(client, "Account", "1", "Name") end},
      {"OData 3 get_field_value",
       fn -> OData3.get_field_value(client, "Account", "1", "Name") end},
      {"JSON Batch execute", fn -> Batch.execute(client, Batch.new()) end},
      {"Multipart Batch execute",
       fn -> Batch.execute(client, Batch.new(), format: :multipart) end},
      {"DataService select_query", fn -> DataService.select_query(client, %{}) end},
      {"DataService insert_query", fn -> DataService.insert_query(client, %{}) end},
      {"DataService update_query", fn -> DataService.update_query(client, %{}) end},
      {"DataService delete_query", fn -> DataService.delete_query(client, %{}) end},
      {"DataService batch_query", fn -> DataService.batch_query(client, %{}) end},
      {"Custom REST service", fn -> DataService.custom_service(client, "CustomSvc", "Ping") end}
    ]
  end
end
