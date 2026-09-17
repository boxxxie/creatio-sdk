defmodule Creatio.DataServiceTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Client, DataService, Error}

  describe "select_query/3" do
    test "sends SelectQuery JSON payload to DataService endpoint" do
      plug = fn conn ->
        assert conn.request_path == "/0/DataService/json/SyncReply/SelectQuery"
        assert conn.method == "POST"

        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert payload["RootSchemaName"] == "Account"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "success" => true,
            "rows" => [%{"Name" => "Global Corp"}]
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      query = %{
        "RootSchemaName" => "Account",
        "columns" => %{"items" => %{"Name" => %{"expression" => %{"columnPath" => "Name"}}}}
      }

      assert {:ok, resp} = DataService.select_query(client, query)
      assert resp["success"] == true
      assert hd(resp["rows"])["Name"] == "Global Corp"
      assert %{"success" => true} = DataService.select_query!(client, query)
    end

    test "returns error when success is false in response body" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "success" => false,
            "errorInfo" => %{
              "errorCode" => "QueryExecutionError",
              "message" => "Column 'Unknown' not found"
            }
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:error, %Error{} = err} = DataService.select_query(client, %{})
      assert err.code == "QueryExecutionError"
      assert err.message == "Column 'Unknown' not found"

      assert_raise Error, ~r/Column 'Unknown' not found/, fn ->
        DataService.select_query!(client, %{})
      end
    end
  end

  describe "insert_query/3, update_query/3, delete_query/3, batch_query/3" do
    test "executes InsertQuery, UpdateQuery, DeleteQuery, and BatchQuery" do
      plug = fn conn ->
        case conn.request_path do
          "/0/DataService/json/SyncReply/InsertQuery" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"success" => true, "id" => "new-id"}))

          "/0/DataService/json/SyncReply/UpdateQuery" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"success" => true, "rowsAffected" => 1}))

          "/0/DataService/json/SyncReply/DeleteQuery" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"success" => true, "rowsAffected" => 1}))

          "/0/DataService/json/SyncReply/BatchQuery" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"success" => true, "responses" => []}))

          "/0/DataService/json/SyncReply/CustomAction" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"success" => true, "result" => 42}))
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, resp} = DataService.insert_query(client, %{"RootSchemaName" => "Contact"})
      assert resp["id"] == "new-id"

      assert %{"id" => "new-id"} =
               DataService.insert_query!(client, %{"RootSchemaName" => "Contact"})

      assert {:ok, resp} = DataService.update_query(client, %{"RootSchemaName" => "Contact"})
      assert resp["rowsAffected"] == 1

      assert %{"rowsAffected" => 1} =
               DataService.update_query!(client, %{"RootSchemaName" => "Contact"})

      assert {:ok, resp} = DataService.delete_query(client, %{"RootSchemaName" => "Contact"})
      assert resp["rowsAffected"] == 1

      assert %{"rowsAffected" => 1} =
               DataService.delete_query!(client, %{"RootSchemaName" => "Contact"})

      assert {:ok, resp} = DataService.batch_query(client, %{"items" => []})
      assert resp["responses"] == []
      assert %{"responses" => []} = DataService.batch_query!(client, %{"items" => []})

      assert {:ok, resp} = DataService.execute_query(client, "CustomAction", %{})
      assert resp["result"] == 42
      assert %{"result" => 42} = DataService.execute_query!(client, "CustomAction", %{})
    end
  end

  describe "custom_service/5" do
    test "calls custom web service endpoint with POST, GET, PUT, PATCH, DELETE" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/0/rest/CustomReportService/Generate"} ->
            {:ok, body, conn} = read_body(conn)
            payload = Jason.decode!(body)
            assert payload["report_id"] == 123

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{"report_url" => "/downloads/report123.pdf"}))

          {"PATCH", "/0/rest/CustomReportService/Update"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"updated" => true}))

          {"PUT", "/0/rest/CustomReportService/Replace"} ->
            conn
            |> send_resp(204, "")

          {"DELETE", "/0/rest/CustomReportService/Remove"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"deleted" => true}))
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      # 201 Created supported
      assert {:ok, resp} =
               DataService.custom_service(
                 client,
                 "CustomReportService",
                 "Generate",
                 %{"report_id" => 123}
               )

      assert resp["report_url"] == "/downloads/report123.pdf"

      # PATCH supported
      assert {:ok, resp} =
               DataService.custom_service(
                 client,
                 "CustomReportService",
                 "Update",
                 %{"field" => "val"},
                 method: :patch
               )

      assert resp["updated"] == true

      # 204 No Content supported
      assert {:ok, _} =
               DataService.custom_service(
                 client,
                 "CustomReportService",
                 "Replace",
                 %{},
                 method: :put
               )

      # DELETE supported
      assert {:ok, resp} =
               DataService.custom_service(
                 client,
                 "CustomReportService",
                 "Remove",
                 %{},
                 method: :delete
               )

      assert resp["deleted"] == true
    end

    test "execute_query decodes binary string responses and detects success: false" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          200,
          "{\"success\": false, \"message\": \"Execution aborted\", \"errorCode\": \"ERR01\"}"
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:error, %Error{status: 200, message: "Execution aborted", code: "ERR01"}} =
               DataService.execute_query(client, "CustomAction", %{})
    end
  end
end
