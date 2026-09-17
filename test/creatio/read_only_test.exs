defmodule Creatio.ReadOnlyTest do
  use ExUnit.Case, async: true
  alias Creatio.{Client, OData, OData3, DataService, Batch, Error}

  setup do
    client = Client.new(base_url: "https://example.creatio.com", read_only: true)
    %{client: client}
  end

  test "Client struct tracks read_only state", %{client: client} do
    assert client.read_only == true
  end

  test "OData create is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode", status: 403}} =
             OData.create(client, "Contact", %{"Name" => "Test"})
  end

  test "OData update is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             OData.update(client, "Contact", "id", %{"Name" => "Test"})
  end

  test "OData delete is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} = OData.delete(client, "Contact", "id")
  end

  test "OData update_field is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             OData.update_field(client, "Contact", "id", "Name", "Test")
  end

  test "OData delete_field is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             OData.delete_field(client, "Contact", "id", "Name")
  end

  test "OData3 create is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             OData3.create(client, "Contact", %{"Name" => "Test"})
  end

  test "OData3 update is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             OData3.update(client, "Contact", "id", %{"Name" => "Test"})
  end

  test "OData3 delete is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} = OData3.delete(client, "Contact", "id")
  end

  test "DataService insert_query is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             DataService.insert_query(client, %{})
  end

  test "DataService update_query is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             DataService.update_query(client, %{})
  end

  test "DataService delete_query is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} =
             DataService.delete_query(client, %{})
  end

  test "Batch containing mutation is blocked", %{client: client} do
    batch = Batch.new() |> Batch.add_create("Contact", %{"Name" => "Test"})
    assert {:error, %Error{code: "ReadOnlyMode"}} = Batch.execute(client, batch)
  end

  test "Batch with only GET is NOT blocked by Batch.execute guard (HTTP layer catches it or passes)", %{client: client} do
    # We stub the HTTP layer to avoid actually sending a request to example.creatio.com
    Req.Test.stub(Creatio.Batch, fn conn ->
      Req.Test.json(conn, %{"responses" => []})
    end)
    
    batch = Batch.new() |> Batch.add_get("Contact")
    client = %{client | req: Req.Request.put_option(client.req, :plug, {Req.Test, Creatio.Batch})}
    
    assert {:ok, []} = Batch.execute(client, batch)
  end
  
  test "Binary batch is blocked", %{client: client} do
    assert {:error, %Error{code: "ReadOnlyMode"}} = Batch.execute(client, "binary-body")
  end
  
  test "Req step blocks network mutations but permits GET" do
    Req.Test.stub(Creatio.ReadOnly, fn conn ->
      Req.Test.json(conn, %{})
    end)
    
    client = Client.new(base_url: "https://example.creatio.com", read_only: true, req_options: [plug: {Req.Test, Creatio.ReadOnly}])
    
    # GET should pass
    assert {:ok, _} = Req.get(client.req, url: "/0/odata/Contact")
    
    # POST to arbitrary endpoint should fail
    assert {:error, %Error{code: "ReadOnlyMode"}} = Req.post(client.req, url: "/0/odata/Contact")
    
    # POST to allowed paths should pass (SelectQuery)
    assert {:ok, _} = Req.post(client.req, url: "/0/DataService/json/SyncReply/SelectQuery")
    
    # POST to allowed paths should pass (Login)
    assert {:ok, _} = Req.post(client.req, url: "/ServiceModel/AuthService.svc/Login")
    
    # POST to batch
    assert {:ok, _} = Req.post(client.req, url: "/0/odata/$batch")
  end
end
