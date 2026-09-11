defmodule CreatioTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  describe "top-level facade functions" do
    test "delegates OData 4 list, execute, get, create, update, delete, count, fields, and streams" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/0/odata/Contact"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"value" => [%{"Id" => "1", "Name" => "Test"}]}))

          {"GET", "/0/odata/Contact(1)"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"Id" => "1", "Name" => "Test"}))

          {"POST", "/0/odata/Contact"} ->
            {:ok, body, conn} = read_body(conn)
            data = Jason.decode!(body)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(Map.put(data, "Id", "new-id")))

          {"PATCH", "/0/odata/Contact(1)"} ->
            send_resp(conn, 204, "")

          {"DELETE", "/0/odata/Contact(1)"} ->
            send_resp(conn, 204, "")

          {"GET", "/0/odata/Contact/$count"} ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, "42")

          {"GET", "/0/odata/Contact(1)/Account"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"Name" => "Acme"}))

          {"GET", "/0/odata/Contact(1)/Name"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"value" => "Test"}))

          {"GET", "/0/odata/Contact(1)/Name/$value"} ->
            send_resp(conn, 200, "RawName")

          {"PUT", "/0/odata/Contact(1)/Photo"} ->
            send_resp(conn, 204, "")

          {"DELETE", "/0/odata/Contact(1)/Photo"} ->
            send_resp(conn, 204, "")
        end
      end

      client = Creatio.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      # list / execute
      assert {:ok, records} = Creatio.list(client, "Contact")
      assert hd(records)["Name"] == "Test"
      assert [%{"Name" => "Test"}] = Creatio.list!(client, "Contact")
      assert {:ok, records} = Creatio.execute(client, "Contact")
      assert hd(records)["Name"] == "Test"
      assert [%{"Name" => "Test"}] = Creatio.execute!(client, "Contact")

      # get
      assert {:ok, record} = Creatio.get(client, "Contact", "1")
      assert record["Name"] == "Test"
      assert %{"Name" => "Test"} = Creatio.get!(client, "Contact", "1")

      # create
      assert {:ok, created} = Creatio.create(client, "Contact", %{"Name" => "New"})
      assert created["Id"] == "new-id"
      assert %{"Id" => "new-id"} = Creatio.create!(client, "Contact", %{"Name" => "New"})

      # update
      assert :ok = Creatio.update(client, "Contact", "1", %{"Name" => "Updated"})
      assert :ok = Creatio.update!(client, "Contact", "1", %{"Name" => "Updated"})

      # delete
      assert :ok = Creatio.delete(client, "Contact", "1")
      assert :ok = Creatio.delete!(client, "Contact", "1")

      # count
      assert {:ok, 42} = Creatio.count(client, "Contact")
      assert 42 = Creatio.count!(client, "Contact")

      # navigation
      assert {:ok, %{"Name" => "Acme"}} =
               Creatio.get_navigation(client, "Contact", "1", "Account")

      assert %{"Name" => "Acme"} = Creatio.get_navigation!(client, "Contact", "1", "Account")

      # fields
      assert {:ok, "Test"} = Creatio.get_field(client, "Contact", "1", "Name")
      assert "Test" = Creatio.get_field!(client, "Contact", "1", "Name")
      assert {:ok, "RawName"} = Creatio.get_field_value(client, "Contact", "1", "Name")
      assert "RawName" = Creatio.get_field_value!(client, "Contact", "1", "Name")
      assert :ok = Creatio.update_field(client, "Contact", "1", "Photo", <<1, 2, 3>>)
      assert :ok = Creatio.update_field!(client, "Contact", "1", "Photo", <<1, 2, 3>>)
      assert :ok = Creatio.delete_field(client, "Contact", "1", "Photo")
      assert :ok = Creatio.delete_field!(client, "Contact", "1", "Photo")

      # Builder helpers
      q = Creatio.query("Contact") |> Creatio.OData.Query.select(["Id", "Name"])
      assert q.entity == "Contact"

      b = Creatio.batch_new(continue_on_error: true)
      assert b.continue_on_error == true

      # from_req
      req = Req.new(base_url: "https://mycreatio.com")
      client2 = Creatio.from_req(req)
      assert client2.base_url == "https://mycreatio.com"
    end

    test "delegates DataService and Custom WebServices" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/0/DataService/json/SyncReply/SelectQuery"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{"rows" => [%{"Name" => "Corp"}], "success" => true})
            )

          {"POST", "/0/rest/CustomSvc/Echo"} ->
            {:ok, body, conn} = read_body(conn)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, body)

          {"GET", "/0/rest/CustomSvc/Ping"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"status" => "pong"}))
        end
      end

      client = Creatio.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, res} = Creatio.select_query(client, %{"RootSchemaName" => "Account"})
      assert res["success"] == true

      assert %{"success" => true} =
               Creatio.select_query!(client, %{"RootSchemaName" => "Account"})

      assert {:ok, res} = Creatio.custom_service(client, "CustomSvc", "Echo", %{"msg" => "hello"})
      assert res["msg"] == "hello"

      assert %{"msg" => "hello"} =
               Creatio.custom_service!(client, "CustomSvc", "Echo", %{"msg" => "hello"})

      assert {:ok, res} = Creatio.custom_service(client, "CustomSvc", "Ping", method: :get)
      assert res["status"] == "pong"

      assert %{"status" => "pong"} =
               Creatio.custom_service!(client, "CustomSvc", "Ping", method: :get)
    end

    test "delegates OData3 functions" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"d" => %{"results" => [%{"Name" => "Legacy"}]}}))

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"d" => %{"Name" => "Legacy"}}))

          {"POST", "/0/ServiceModel/EntityDataService.svc/ContactCollection"} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(%{"d" => %{"Id" => "new-1"}}))

          {"PATCH", "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')"} ->
            send_resp(conn, 204, "")

          {"DELETE", "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')"} ->
            send_resp(conn, 204, "")
        end
      end

      client = Creatio.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, [%{"Name" => "Legacy"}]} = Creatio.odata3_list(client, "Contact")
      assert [%{"Name" => "Legacy"}] = Creatio.odata3_list!(client, "Contact")

      assert {:ok, %{"Name" => "Legacy"}} = Creatio.odata3_get(client, "Contact", "1")
      assert %{"Name" => "Legacy"} = Creatio.odata3_get!(client, "Contact", "1")

      assert {:ok, %{"Id" => "new-1"}} =
               Creatio.odata3_create(client, "Contact", %{"Name" => "Legacy"})

      assert %{"Id" => "new-1"} =
               Creatio.odata3_create!(client, "Contact", %{"Name" => "Legacy"})

      assert :ok = Creatio.odata3_update(client, "Contact", "1", %{"Name" => "Updated"})
      assert :ok = Creatio.odata3_update!(client, "Contact", "1", %{"Name" => "Updated"})

      assert :ok = Creatio.odata3_delete(client, "Contact", "1")
      assert :ok = Creatio.odata3_delete!(client, "Contact", "1")
    end
  end
end
