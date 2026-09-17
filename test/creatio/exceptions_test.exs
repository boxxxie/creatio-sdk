defmodule Creatio.ExceptionsTest do
  use ExUnit.Case

  setup do
    adapter = fn req -> {req, %Req.TransportError{reason: :timeout}} end
    req = Req.new(adapter: adapter, retry: false)

    client =
      Creatio.Client.from_req(req,
        base_url: "http://test",
        auth_mode: :anonymous,
        req_options: [adapter: adapter, retry: false]
      )

    {:ok, client: client}
  end

  test "odata exceptions", %{client: client} do
    Creatio.OData.list(client, "A")
    Creatio.OData.execute(client, "A")
    Creatio.OData.get(client, "A", "1")
    Creatio.OData.count(client, "A")
    Creatio.OData.create(client, "A", %{})
    Creatio.OData.update(client, "A", "1", %{})
    Creatio.OData.delete(client, "A", "1")
    Creatio.OData.get_navigation(client, "A", "1", "B")
    Creatio.OData.get_field(client, "A", "1", "B")
    Creatio.OData.get_field_value(client, "A", "1", "B")
    Creatio.OData.update_field(client, "A", "1", "B", "C")
    Creatio.OData.delete_field(client, "A", "1", "B")

    Creatio.OData3.list(client, "A")
    Creatio.OData3.get(client, "A", "1")
    Creatio.OData3.count(client, "A")
    Creatio.OData3.create(client, "A", %{})
    Creatio.OData3.update(client, "A", "1", %{})
    Creatio.OData3.delete(client, "A", "1")
    Creatio.OData3.get_navigation(client, "A", "1", "B")
    Creatio.OData3.get_field(client, "A", "1", "B")
    Creatio.OData3.get_field_value(client, "A", "1", "B")

    Creatio.Batch.execute(client, Creatio.Batch.new())
    Creatio.Batch.execute(client, Creatio.Batch.new(), format: :multipart)

    Creatio.DataService.select_query(client, %{})
    Creatio.DataService.insert_query(client, %{})
    Creatio.DataService.update_query(client, %{})
    Creatio.DataService.delete_query(client, %{})
    Creatio.DataService.batch_query(client, %{})
    Creatio.DataService.custom_service(client, "A", "B")
  end
end
