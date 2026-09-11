defmodule Creatio.OData3Test do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Client, OData3}

  describe "OData 3 legacy endpoints" do
    test "list/3 retrieves collection from ServiceModel/EntityDataService.svc" do
      plug = fn conn ->
        assert conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"d" => %{"results" => [%{"Name" => "Legacy Contact"}]}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, results} = OData3.list(client, "Contact")
      assert hd(results)["Name"] == "Legacy Contact"
    end

    test "get/4 retrieves entity with guid syntax" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222')"

        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"d" => %{"Id" => "1111-2222", "Name" => "Legacy Contact"}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, record} = OData3.get(client, "Contact", "1111-2222")
      assert record["Id"] == "1111-2222"
    end

    test "create/4 creates entity" do
      plug = fn conn ->
        assert conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection"
        assert conn.method == "POST"

        {:ok, body, conn} = read_body(conn)
        attrs = Jason.decode!(body)
        assert attrs["Name"] == "OData3 Contact"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(%{"Id" => "guid-new", "Name" => "OData3 Contact"}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, record} = OData3.create(client, "Contact", %{"Name" => "OData3 Contact"})
      assert record["Id"] == "guid-new"
    end

    test "update/5 patches entity" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'guid-123')"

        assert conn.method == "PATCH"

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok = OData3.update(client, "Contact", "guid-123", %{"Name" => "Updated"})
    end

    test "delete/4 deletes entity" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'guid-123')"

        assert conn.method == "DELETE"

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok = OData3.delete(client, "Contact", "guid-123")
    end
  end
end
