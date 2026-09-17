defmodule Creatio.OData3Test do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Client, OData3}

  describe "OData 3 legacy endpoints" do
    test "list/3 retrieves collection with odata=verbose Accept header" do
      plug = fn conn ->
        assert conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection"
        assert conn.method == "GET"
        assert get_req_header(conn, "accept") == ["application/json; odata=verbose"]
        assert get_req_header(conn, "forceusesession") == ["true"]

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
      assert [%{"Name" => "Legacy Contact"}] = OData3.list!(client, "Contact")
    end

    test "list/3 with count: true requests inline count via $inlinecount=allpages" do
      plug = fn conn ->
        assert conn.request_path == "/0/ServiceModel/EntityDataService.svc/ContactCollection"
        assert URI.decode(conn.query_string) =~ "$inlinecount=allpages"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "d" => %{
              "__count" => "42",
              "results" => [%{"Name" => "Contact 1"}]
            }
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, %{records: records, count: 42}} = OData3.list(client, "Contact", count: true)
      assert length(records) == 1
    end

    test "get/4 retrieves entity and cleans pre-wrapped guid" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222')"

        assert conn.method == "GET"
        assert get_req_header(conn, "accept") == ["application/json; odata=verbose"]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"d" => %{"Id" => "1111-2222", "Name" => "Legacy Contact"}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      # Pass unquoted ID
      assert {:ok, record} = OData3.get(client, "Contact", "1111-2222")
      assert record["Id"] == "1111-2222"
      assert %{"Id" => "1111-2222"} = OData3.get!(client, "Contact", "1111-2222")

      # Pass pre-wrapped guid'...' ID
      assert {:ok, record2} = OData3.get(client, "Contact", "guid'1111-2222'")
      assert record2["Id"] == "1111-2222"
    end

    test "get_navigation/5 retrieves related records via navigation property" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222')/Account"

        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"d" => %{"Name" => "Acme Org"}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, res} = OData3.get_navigation(client, "Contact", "1111-2222", "Account")
      assert res["Name"] == "Acme Org"

      assert %{"Name" => "Acme Org"} =
               OData3.get_navigation!(client, "Contact", "1111-2222", "Account")
    end

    test "get_field/5 and get_field_value/4 retrieve field and scalar value" do
      plug = fn conn ->
        case conn.request_path do
          "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222')/Name" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"d" => %{"Name" => "William Walker"}}))

          "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222')/Name/$value" ->
            conn
            |> send_resp(200, "William Walker")
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, "William Walker"} = OData3.get_field(client, "Contact", "1111-2222", "Name")
      assert "William Walker" = OData3.get_field!(client, "Contact", "1111-2222", "Name")

      assert {:ok, "William Walker"} =
               OData3.get_field_value(client, "Contact", "1111-2222", "Name")

      assert "William Walker" = OData3.get_field_value!(client, "Contact", "1111-2222", "Name")
    end

    test "count/3 retrieves count from /$count endpoint" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count"

        assert conn.method == "GET"

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "13")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, 13} = OData3.count(client, "Contact")
      assert 13 = OData3.count!(client, "Contact")
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

      assert %{"Id" => "guid-new"} =
               OData3.create!(client, "Contact", %{"Name" => "OData3 Contact"})
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
      assert :ok = OData3.update!(client, "Contact", "guid-123", %{"Name" => "Updated"})
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
      assert :ok = OData3.delete!(client, "Contact", "guid-123")
    end

    test "clean_guid strips curly braces and quotes" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection(guid'1111-2222-3333')"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"d" => %{"Id" => "1111-2222-3333"}}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, _} = OData3.get(client, "Contact", "{1111-2222-3333}")
      assert {:ok, _} = OData3.get(client, "Contact", "'1111-2222-3333'")
      assert {:ok, _} = OData3.get(client, "Contact", "guid'1111-2222-3333'")
    end

    test "list/3 supports Creatio.OData.Query struct" do
      plug = fn conn ->
        assert conn.query_string =~ "%24filter=Active+eq+true"
        assert conn.query_string =~ "%24inlinecount=allpages"
        assert conn.query_string =~ "%24top=10"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "d" => %{
              "__count" => "42",
              "results" => [%{"Name" => "Alice"}]
            }
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      query =
        Creatio.OData.Query.new("Contact")
        |> Creatio.OData.Query.filter_eq("Active", true)
        |> Creatio.OData.Query.top(10)
        |> Creatio.OData.Query.count()

      assert {:ok, %{records: [%{"Name" => "Alice"}], count: 42}} =
               OData3.list(client, query)

      assert %{records: [%{"Name" => "Alice"}], count: 42} =
               OData3.list!(client, query)
    end

    test "count/3 supports strategy: :query (?/$count)" do
      plug = fn conn ->
        assert conn.request_path ==
                 "/0/ServiceModel/EntityDataService.svc/ContactCollection"

        assert conn.query_string == "/$count"

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "27")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, 27} = OData3.count(client, "Contact", strategy: :query)
      assert 27 = OData3.count!(client, "Contact", strategy: :query)
    end

    test "stream/3 paginates entity records" do
      plug = fn conn ->
        cond do
          String.contains?(conn.query_string, "%24skip=0") ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{
                "d" => %{"results" => [%{"Name" => "Page1_1"}, %{"Name" => "Page1_2"}]}
              })
            )

          String.contains?(conn.query_string, "%24skip=2") ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              200,
              Jason.encode!(%{
                "d" => %{"results" => [%{"Name" => "Page2_1"}]}
              })
            )
        end
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      results =
        OData3.stream(client, "Contact", page_size: 2)
        |> Enum.to_list()

      assert length(results) == 3
      assert Enum.map(results, & &1["Name"]) == ["Page1_1", "Page1_2", "Page2_1"]
    end
  end
end
