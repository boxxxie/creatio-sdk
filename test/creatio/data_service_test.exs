defmodule Creatio.DataServiceTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Client, DataService}

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
    end
  end

  describe "custom_service/5" do
    test "calls custom web service endpoint" do
      plug = fn conn ->
        assert conn.request_path == "/0/rest/CustomReportService/Generate"
        assert conn.method == "POST"

        {:ok, body, conn} = read_body(conn)
        payload = Jason.decode!(body)
        assert payload["report_id"] == 123

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"report_url" => "/downloads/report123.pdf"}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, resp} =
               DataService.custom_service(
                 client,
                 "CustomReportService",
                 "Generate",
                 %{"report_id" => 123}
               )

      assert resp["report_url"] == "/downloads/report123.pdf"
    end
  end
end
