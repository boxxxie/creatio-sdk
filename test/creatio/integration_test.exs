defmodule Creatio.IntegrationTest do
  use ExUnit.Case

  setup do
    plug_fn = fn conn ->
      path = conn.request_path

      body =
        cond do
          path == "/0/odata/Contact" ->
            if conn.method == "POST", do: ~s({"Id": "1"}), else: ~s({"value": []})

          path == "/0/odata/Contact/$count" ->
            "10"

          path == "/0/odata/Contact(1)" ->
            ~s({"Id": "1"})

          path == "/0/odata/Contact(1)/Name" ->
            ~s({"value": "A"})

          path == "/0/odata/Contact(1)/Account" ->
            ~s({"Id": "2"})

          path == "/0/odata/$batch" ->
            """
            --batch_123
            Content-Type: application/http

            HTTP/1.1 200 OK
            Content-Type: application/json

            {"d": {"Id": "1"}}
            --batch_123--
            """

          path == "/0/DataService/json/SyncReply/SelectQuery" ->
            ~s({"success": true, "rows": []})

          path == "/0/DataService/json/SyncReply/InsertQuery" ->
            ~s({"success": true})

          path == "/0/DataService/json/SyncReply/UpdateQuery" ->
            ~s({"success": true})

          path == "/0/DataService/json/SyncReply/DeleteQuery" ->
            ~s({"success": true})

          path == "/0/DataService/json/SyncReply/BatchQuery" ->
            ~s({"success": true})

          path == "/0/ServiceModel/EntityDataService.svc/ContactCollection" ->
            ~s({"d": {"results": []}})

          path == "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count" ->
            "10"

          path == "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')" ->
            ~s({"d": {"Id": "1"}})

          path == "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')/Name" ->
            ~s({"d": {"Name": "A"}})

          path == "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1')/Account" ->
            ~s({"d": {"Id": "2"}})

          path == "/identity/.well-known/openid-configuration" ->
            ~s({"issuer": "test"})

          path == "/ServiceModel/AuthService.svc/Login" ->
            ~s({"Code": 0, "Message": ""})

          path == "/connect/token" ->
            ~s({"access_token": "test"})

          path == "/core/api/ping" ->
            ~s("pong")

          true ->
            "{}"
        end

      headers = [{"content-type", "application/json"}]

      headers =
        if path == "/0/odata/$batch",
          do: [{"content-type", "multipart/mixed; boundary=batch_123"}],
          else: headers

      %{conn | resp_headers: headers}
      |> Plug.Conn.send_resp(200, body)
    end

    req = Req.new(plug: plug_fn, retry: false)

    client =
      Creatio.Client.from_req(req,
        base_url: "http://test",
        auth_mode: :anonymous,
        client_id: "c",
        client_secret: "s",
        identity_service_url: "http://test",
        req_options: [plug: plug_fn, retry: false]
      )

    {:ok, client: client}
  end

  test "OData happy paths", %{client: client} do
    assert {:ok, _} = Creatio.OData.list(client, "Contact")
    assert {:ok, _} = Creatio.OData.get(client, "Contact", "1")
    assert {:ok, _} = Creatio.OData.create(client, "Contact", %{})
    assert {:ok, _} = Creatio.OData.update(client, "Contact", "1", %{})
    assert :ok = Creatio.OData.delete(client, "Contact", "1")
    assert :ok = Creatio.OData.update_field(client, "Contact", "1", "Name", "Val")
    assert :ok = Creatio.OData.delete_field(client, "Contact", "1", "Name")
    assert {:ok, _} = Creatio.OData.count(client, "Contact")
    assert {:ok, _} = Creatio.OData.get_field(client, "Contact", "1", "Name")
    assert {:ok, _} = Creatio.OData.get_field_value(client, "Contact", "1", "Name")
    assert {:ok, _} = Creatio.OData.get_navigation(client, "Contact", "1", "Account")
    assert {:ok, _} = Creatio.OData.batch(client, Creatio.Batch.new())
    assert [] = Creatio.OData.stream(client, "Contact") |> Enum.to_list()

    q = Creatio.OData.Query.new("Contact")
    assert {:ok, _} = Creatio.OData.list(q, client)
    assert [] = Creatio.OData.stream(q, client) |> Enum.to_list()
  end

  test "OData3 happy paths", %{client: client} do
    assert {:ok, _} = Creatio.OData3.list(client, "Contact")
    assert {:ok, _} = Creatio.OData3.get(client, "Contact", "1")
    assert {:ok, _} = Creatio.OData3.create(client, "Contact", %{})
    assert {:ok, _} = Creatio.OData3.update(client, "Contact", "1", %{})
    assert :ok = Creatio.OData3.delete(client, "Contact", "1")
    assert {:ok, _} = Creatio.OData3.count(client, "Contact")
    assert {:ok, _} = Creatio.OData3.get_field(client, "Contact", "1", "Name")
    assert {:ok, _} = Creatio.OData3.get_field_value(client, "Contact", "1", "Name")
    assert {:ok, _} = Creatio.OData3.get_navigation(client, "Contact", "1", "Account")
    assert [] = Creatio.OData3.stream(client, "Contact") |> Enum.to_list()

    q = Creatio.OData.Query.new("Contact")
    assert {:ok, _} = Creatio.OData3.list(q, client)
    assert [] = Creatio.OData3.stream(q, client) |> Enum.to_list()
  end

  test "DataService happy paths", %{client: client} do
    assert {:ok, _} = Creatio.DataService.select_query(client, %{})
    assert {:ok, _} = Creatio.DataService.insert_query(client, %{})
    assert {:ok, _} = Creatio.DataService.update_query(client, %{})
    assert {:ok, _} = Creatio.DataService.delete_query(client, %{})
    assert {:ok, _} = Creatio.DataService.batch_query(client, %{})
    assert {:ok, _} = Creatio.DataService.custom_service(client, "Sys", "Method", %{})
  end

  test "Auth happy paths", %{client: client} do
    assert {:ok, _} = Creatio.Auth.login_forms(client, "u", "p")
    assert {:ok, _, _} = Creatio.Auth.login_oauth(client)
    assert {:ok, _} = Creatio.Auth.oauth_health_check(client)
    assert {:ok, _} = Creatio.Auth.openid_configuration(client)
  end

  test "Bang methods", %{client: client} do
    assert Creatio.OData.list!(client, "Contact")
    assert Creatio.OData.get!(client, "Contact", "1")
    assert Creatio.OData.count!(client, "Contact")
    assert Creatio.OData.get_field!(client, "Contact", "1", "Name")
    assert Creatio.OData.get_field_value!(client, "Contact", "1", "Name")
    assert Creatio.OData.get_navigation!(client, "Contact", "1", "Account")
    assert Creatio.OData.create!(client, "Contact", %{})
    assert Creatio.OData.update!(client, "Contact", "1", %{})
    assert :ok = Creatio.OData.delete!(client, "Contact", "1")
    assert :ok = Creatio.OData.update_field!(client, "Contact", "1", "Name", "Val")
    assert :ok = Creatio.OData.delete_field!(client, "Contact", "1", "Name")
    assert Creatio.OData.batch!(client, Creatio.Batch.new())

    assert Creatio.OData3.list!(client, "Contact")
    assert Creatio.OData3.get!(client, "Contact", "1")
    assert Creatio.OData3.count!(client, "Contact")
    assert Creatio.OData3.get_field!(client, "Contact", "1", "Name")
    assert Creatio.OData3.get_field_value!(client, "Contact", "1", "Name")
    assert Creatio.OData3.get_navigation!(client, "Contact", "1", "Account")
    assert Creatio.OData3.create!(client, "Contact", %{})
    assert Creatio.OData3.update!(client, "Contact", "1", %{})
    assert :ok = Creatio.OData3.delete!(client, "Contact", "1")
    assert [] = Creatio.OData3.stream!(client, "Contact") |> Enum.to_list()

    assert Creatio.DataService.select_query!(client, %{})
    assert Creatio.DataService.insert_query!(client, %{})
    assert Creatio.DataService.update_query!(client, %{})
    assert Creatio.DataService.delete_query!(client, %{})
    assert Creatio.DataService.batch_query!(client, %{})
    assert Creatio.DataService.custom_service!(client, "Sys", "Method", %{})
  end

  test "Creatio delegates", %{client: client} do
    assert {:ok, _} = Creatio.list(client, "Contact")
    assert Creatio.list!(client, "Contact")
    assert {:ok, _} = Creatio.execute(client, "Contact")
    assert Creatio.execute!(client, "Contact")
    assert [] = Creatio.stream(client, "Contact") |> Enum.to_list()
    assert {:ok, _} = Creatio.odata3_list(client, "Contact")
    assert Creatio.odata3_list!(client, "Contact")
    assert [] = Creatio.odata3_stream(client, "Contact") |> Enum.to_list()
    assert [] = Creatio.odata3_stream!(client, "Contact") |> Enum.to_list()
  end
end
