defmodule Creatio.ODataTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  alias Creatio.{Client, Error, OData}
  alias Creatio.OData.Query

  describe "list/3" do
    test "lists entity collection and maps query parameters" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact"
        assert conn.method == "GET"

        query = URI.decode_query(conn.query_string)
        assert query["$select"] == "Id,Name,Email"
        assert query["$filter"] == "Age gt 18"
        assert query["$orderby"] == "Name asc"
        assert query["$top"] == "10"
        assert query["$skip"] == "20"
        assert query["$expand"] == "Account"

        records = [
          %{"Id" => "1", "Name" => "Alice", "Email" => "alice@example.com"},
          %{"Id" => "2", "Name" => "Bob", "Email" => "bob@example.com"}
        ]

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => records}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, records} =
               OData.list(client, "Contact",
                 select: ["Id", "Name", "Email"],
                 filter: "Age gt 18",
                 orderby: "Name asc",
                 top: 10,
                 skip: 20,
                 expand: "Account"
               )

      assert length(records) == 2
      assert hd(records)["Name"] == "Alice"
    end

    test "returns count when count: true is requested" do
      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["$count"] == "true"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "@odata.count" => 42,
            "value" => [%{"Id" => "1", "Name" => "Alice"}]
          })
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, result} = OData.list(client, "Contact", count: true)
      assert result.count == 42
      assert length(result.records) == 1
    end

    test "supports %Creatio.OData.Query{} struct" do
      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["$select"] == "Id,Name"
        assert query["$filter"] == "contains(Name,'Smith')"
        assert query["$top"] == "5"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => [%{"Id" => "uuid-1", "Name" => "Smith"}]}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      query =
        Query.new("Contact")
        |> Query.select(["Id", "Name"])
        |> Query.filter("contains(Name,'Smith')")
        |> Query.top(5)

      assert {:ok, [rec]} = OData.list(client, query)
      assert rec["Name"] == "Smith"
    end

    test "supports order_by snake_case and keyword list without crashing" do
      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["$orderby"] == "Name asc,CreatedOn desc"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => []}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, []} = OData.list(client, "Contact", order_by: [Name: :asc, CreatedOn: :desc])
    end

    test "supports execute/2 and execute!/2" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => [%{"Id" => "1", "Name" => "Exec"}]}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      q = Query.new("Contact")

      assert {:ok, [rec]} = OData.execute(client, q)
      assert rec["Name"] == "Exec"

      assert [rec_bang] = OData.execute!(client, q)
      assert rec_bang["Name"] == "Exec"
    end

    test "handles direct JSON array response body in do_list" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!([%{"Id" => "arr-1", "Name" => "Direct Array"}]))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, [item]} = OData.list(client, "Contact")
      assert item["Name"] == "Direct Array"
    end
  end

  describe "get/4" do
    test "retrieves an entity by ID" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(1234-uuid)"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"Id" => "1234-uuid", "Name" => "John Doe", "Phone" => "555-1234"})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, record} = OData.get(client, "Contact", "1234-uuid")
      assert record["Id"] == "1234-uuid"
      assert record["Name"] == "John Doe"
    end

    test "handles 404 not found" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{"error" => %{"message" => "Entity not found", "code" => "404"}})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:error, %Error{status: 404, message: "Entity not found"}} =
               OData.get(client, "Contact", "nonexistent")
    end
  end

  describe "get_navigation/5" do
    test "retrieves related entities through navigation property" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(1234-uuid)/Account"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{"value" => [%{"Id" => "acc-1", "Name" => "Acme Corp"}]})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, [acc]} = OData.get_navigation(client, "Contact", "1234-uuid", "Account")
      assert acc["Name"] == "Acme Corp"
    end
  end

  describe "get_field/5 and get_field_value/4" do
    test "retrieves field object" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(1234-uuid)/JobTitle"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => "Managing Director"}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, "Managing Director"} =
               OData.get_field(client, "Contact", "1234-uuid", "JobTitle")
    end

    test "retrieves raw scalar field value ($value)" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(1234-uuid)/Name/$value"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "William Walker")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, "William Walker"} =
               OData.get_field_value(client, "Contact", "1234-uuid", "Name")
    end
  end

  describe "count/3" do
    test "retrieves total count of entity collection" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact/$count"
        assert conn.method == "GET"

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "1542")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, 1542} = OData.count(client, "Contact")
      assert OData.count!(client, "Contact") == 1542
    end

    test "handles count response as JSON map with @odata.count" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"@odata.count" => 99}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, 99} = OData.count(client, "Contact")
    end
  end

  describe "create/4" do
    test "creates record and returns created entity" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact"
        assert conn.method == "POST"
        assert get_req_header(conn, "forceusesession") == ["true"]

        {:ok, body, conn} = read_body(conn)
        attrs = Jason.decode!(body)
        assert attrs["Name"] == "New Contact"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          201,
          Jason.encode!(%{"Id" => "new-uuid-1", "Name" => "New Contact"})
        )
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, created} = OData.create(client, "Contact", %{"Name" => "New Contact"})
      assert created["Id"] == "new-uuid-1"
      assert created["Name"] == "New Contact"

      assert %{"Id" => "new-uuid-1"} =
               OData.create!(client, "Contact", %{"Name" => "New Contact"})
    end
  end

  describe "update/5" do
    test "updates existing entity via PATCH" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(uuid-123)"
        assert conn.method == "PATCH"
        assert get_req_header(conn, "forceusesession") == ["true"]

        {:ok, body, conn} = read_body(conn)
        attrs = Jason.decode!(body)
        assert attrs["JobTitle"] == "Senior Partner"

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok = OData.update(client, "Contact", "uuid-123", %{"JobTitle" => "Senior Partner"})
      assert :ok = OData.update!(client, "Contact", "uuid-123", %{"JobTitle" => "Senior Partner"})
    end
  end

  describe "delete/4" do
    test "deletes entity via DELETE" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(uuid-123)"
        assert conn.method == "DELETE"
        assert get_req_header(conn, "forceusesession") == ["true"]

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok = OData.delete(client, "Contact", "uuid-123")
      assert :ok = OData.delete!(client, "Contact", "uuid-123")
    end
  end

  describe "update_field/6 and delete_field/5" do
    test "updates octet-stream binary field" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(uuid-123)/Photo"
        assert conn.method == "PUT"

        assert get_req_header(conn, "content-type") == [
                 "application/octet-stream; IEEE754Compatible=true"
               ]

        {:ok, body, conn} = read_body(conn)
        assert body == <<1, 2, 3, 4, 5>>

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok =
               OData.update_field(client, "Contact", "uuid-123", "Photo", <<1, 2, 3, 4, 5>>)

      assert :ok =
               OData.update_field!(client, "Contact", "uuid-123", "Photo", <<1, 2, 3, 4, 5>>)
    end

    test "updates scalar primitive fields (boolean, integer, string)" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(uuid-123)/Active"
        assert conn.method == "PUT"

        {:ok, body, conn} = read_body(conn)
        assert body == Jason.encode!(%{"value" => true})

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert :ok = OData.update_field(client, "Contact", "uuid-123", "Active", true)
      assert :ok = OData.update_field!(client, "Contact", "uuid-123", "Active", true)
    end

    test "deletes a field with proper stream headers" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(uuid-123)/Photo"
        assert conn.method == "DELETE"

        assert get_req_header(conn, "accept") == ["application/json; text/plain; */*"]

        assert get_req_header(conn, "content-type") == [
                 "application/octet-stream; IEEE754Compatible=true"
               ]

        conn
        |> send_resp(204, "")
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert :ok = OData.delete_field(client, "Contact", "uuid-123", "Photo")
      assert :ok = OData.delete_field!(client, "Contact", "uuid-123", "Photo")
    end
  end

  describe "stream/3" do
    test "auto-paginates across multiple pages" do
      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        top = String.to_integer(query["$top"])
        skip = String.to_integer(query["$skip"])

        # Simulate 5 items total with page_size = 2
        items =
          Enum.map((skip + 1)..(skip + top), fn idx ->
            %{"Id" => "id-#{idx}", "Name" => "Item #{idx}"}
          end)
          |> Enum.filter(fn %{"Id" => "id-" <> n} -> String.to_integer(n) <= 5 end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => items}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      results =
        OData.stream(client, "Contact", page_size: 2)
        |> Enum.to_list()

      assert length(results) == 5
      assert hd(results)["Name"] == "Item 1"
      assert List.last(results)["Name"] == "Item 5"
    end

    test "auto-paginates without crashing when count: true is passed" do
      plug = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => [%{"Id" => "1"}]}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      items = OData.stream(client, "Contact", count: true, page_size: 10) |> Enum.to_list()
      assert length(items) == 1
    end

    test "streams query builder structs and Req requests directly" do
      plug = fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["$select"] == "Id,Name"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => [%{"Id" => "q1", "Name" => "Item"}]}))
      end

      req = Req.new(base_url: "https://mycreatio.com", plug: plug)
      q = Query.new("Contact") |> Query.select(["Id", "Name"])

      items = OData.stream(req, q, page_size: 10) |> Enum.to_list()
      assert length(items) == 1
      assert hd(items)["Name"] == "Item"
    end
  end

  describe "Query builder enhancements" do
    test "supports atoms, keyword order_by, where, filter_in, and query string" do
      q =
        Query.new("Contact")
        |> Query.select(:Id)
        |> Query.select([:Name, :Email])
        |> Query.expand(:Account)
        |> Query.where("Age gt 20")
        |> Query.where("City/Name eq 'Toronto'")
        |> Query.filter_in("Status", ["Active", "Pending"])
        |> Query.order_by(Name: :asc, CreatedOn: :desc)

      params = Query.to_params(q)
      assert params["$select"] == "Id,Name,Email"
      assert params["$expand"] == "Account"
      assert params["$orderby"] == "Name asc,CreatedOn desc"
      assert String.contains?(params["$filter"], "Age gt 20")
      assert String.contains?(params["$filter"], "City/Name eq 'Toronto'")
      assert String.contains?(params["$filter"], "Status eq 'Active' or Status eq 'Pending'")

      qs = Query.to_query_string(q)
      assert String.contains?(qs, "%24select=Id%2CName%2CEmail")
    end

    test "supports all Postman collection filtration functions and operators" do
      # eq, ne, contains, startswith, endswith
      q1 =
        Query.new("Collection1")
        |> Query.filter_eq("Field2", "Field2Value")
        |> Query.filter_ne("Field3", "OtherVal")
        |> Query.filter_contains("Field4", "needle")
        |> Query.filter_startswith("Field5", "prefix")
        |> Query.filter_endswith("Field6", "suffix")

      params1 = Query.to_params(q1)
      assert params1["$filter"] =~ "Field2 eq 'Field2Value'"
      assert params1["$filter"] =~ "Field3 ne 'OtherVal'"
      assert params1["$filter"] =~ "contains(Field4,'needle')"
      assert params1["$filter"] =~ "startswith(Field5,'prefix')"
      assert params1["$filter"] =~ "endswith(Field6,'suffix')"

      # Unquoted GUID eq (Postman Collection3?$filter=Collection6/Field6 eq Id)
      q2 =
        Query.new("Collection3")
        |> Query.filter_eq("Collection6/Field6", "e9621f72-42bd-47c1", quoted: false)

      assert Query.to_params(q2)["$filter"] == "Collection6/Field6 eq e9621f72-42bd-47c1"

      # Boolean, number, null literal formatting
      q3 =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.filter_eq("Age", 30)
        |> Query.filter_eq("MiddleName", nil)

      params3 = Query.to_params(q3)
      assert params3["$filter"] =~ "Active eq true"
      assert params3["$filter"] =~ "Age eq 30"
      assert params3["$filter"] =~ "MiddleName eq null"

      # Comparison operators: gt, ge, lt, le
      q4 =
        Query.new("Product")
        |> Query.filter_gt("Price", 100)
        |> Query.filter_ge("Rating", 4.5)
        |> Query.filter_lt("Stock", 10)
        |> Query.filter_le("Discount", 0.5)

      params4 = Query.to_params(q4)
      assert params4["$filter"] =~ "Price gt 100"
      assert params4["$filter"] =~ "Rating ge 4.5"
      assert params4["$filter"] =~ "Stock lt 10"
      assert params4["$filter"] =~ "Discount le 0.5"

      # Date and string functions: day, length
      q5 =
        Query.new("Collection1")
        |> Query.filter_day("Field3", "Field3Value")
        |> Query.filter_length("Field2", "Field2Value", "gt")

      params5 = Query.to_params(q5)
      assert params5["$filter"] =~ "day(Field3) eq Field3Value"
      assert params5["$filter"] =~ "length(Field2) gt Field2Value"

      # not operator
      q6 =
        Query.new("Collection1")
        |> Query.filter_endswith("Field2", "Field2Value")
        |> Query.filter_not()

      assert Query.to_params(q6)["$filter"] == "not (endswith(Field2,'Field2Value'))"

      # filter_in_ids for GUIDs without quotes
      q7 =
        Query.new("Contact")
        |> Query.filter_in_ids("Id", ["uuid-1", "uuid-2"])

      assert Query.to_params(q7)["$filter"] == "(Id eq uuid-1 or Id eq uuid-2)"

      # OR combinators
      q8 =
        Query.new("Contact")
        |> Query.filter_eq("City", "Toronto")
        |> Query.or_filter_eq("City", "Montreal")
        |> Query.or_filter_contains("Name", "Smith")

      params8 = Query.to_params(q8)
      assert params8["$filter"] =~ "or (City eq 'Montreal')"
      assert params8["$filter"] =~ "or (contains(Name,'Smith'))"
    end

    test "count/3 handles string count inside @odata.count and value" do
      plug1 = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"@odata.count" => "25"}))
      end

      client1 = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug1])
      assert {:ok, 25} = OData.count(client1, "Contact")

      plug2 = fn conn ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => "50"}))
      end

      client2 = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug2])
      assert {:ok, 50} = OData.count(client2, "Contact")

      # Raw text/plain response with UTF-8 BOM (\uFEFF) as sent by Creatio IIS servers
      plug3 = fn conn ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, "\uFEFF22345")
      end

      client3 = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug3])
      assert {:ok, 22_345} = OData.count(client3, "Contact")
    end

    test "normalize_params accepts keyword list params" do
      plug = fn conn ->
        assert conn.query_string =~ "custom_key=custom_val"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => []}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])
      assert {:ok, []} = OData.list(client, "Contact", params: [custom_key: "custom_val"])
    end

    test "clean_id strips braces, quotes, and guid prefixes across CRUD operations" do
      plug = fn conn ->
        assert conn.request_path == "/0/odata/Contact(1111-2222-3333)"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"Id" => "1111-2222-3333"}))
      end

      client = Client.new(base_url: "https://mycreatio.com", req_options: [plug: plug])

      assert {:ok, _} = OData.get(client, "Contact", "{1111-2222-3333}")
      assert {:ok, _} = OData.get(client, "Contact", "'1111-2222-3333'")
      assert {:ok, _} = OData.get(client, "Contact", "guid'1111-2222-3333'")
    end

    test "Query builder supports filter_guid, or_filter_guid, or_filter_in, and additional OR functions" do
      # filter_guid OData 4 (unquoted) vs OData 3 (guid'...')
      q1 =
        Query.new("Contact")
        |> Query.filter_guid("AccountId", "{4c63c8fa-467b-48a6-973f-b2069298404f}")
        |> Query.or_filter_guid("OwnerId", "1111-2222-3333-4444")

      params1 = Query.to_params(q1)
      assert params1["$filter"] =~ "AccountId eq 4c63c8fa-467b-48a6-973f-b2069298404f"
      assert params1["$filter"] =~ "OwnerId eq 1111-2222-3333-4444"

      q2 =
        Query.new("Contact")
        |> Query.filter_guid("AccountId", "4c63c8fa-467b-48a6-973f-b2069298404f",
          protocol: :odata3
        )

      assert Query.to_params(q2)["$filter"] ==
               "AccountId eq guid'4c63c8fa-467b-48a6-973f-b2069298404f'"

      # or_filter_gt, or_filter_ge, or_filter_lt, or_filter_le, or_filter_day, or_filter_length
      q3 =
        Query.new("Product")
        |> Query.filter_gt("Price", 50)
        |> Query.or_filter_gt("Price", 100)
        |> Query.or_filter_ge("Rating", 4.0)
        |> Query.or_filter_lt("Stock", 5)
        |> Query.or_filter_le("Discount", 0.1)
        |> Query.or_filter_day("CreatedOn", 15)
        |> Query.or_filter_length("Name", 20, "lt")

      params3 = Query.to_params(q3)
      assert params3["$filter"] =~ "or (Price gt 100)"
      assert params3["$filter"] =~ "or (Rating ge 4.0)"
      assert params3["$filter"] =~ "or (Stock lt 5)"
      assert params3["$filter"] =~ "or (Discount le 0.1)"
      assert params3["$filter"] =~ "or (day(CreatedOn) eq 15)"
      assert params3["$filter"] =~ "or (length(Name) lt 20)"

      # or_filter_in
      q4 =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.or_filter_in("Department", ["Sales", "Marketing", "Sales"])

      params4 = Query.to_params(q4)
      assert params4["$filter"] =~ "or ((Department eq 'Sales' or Department eq 'Marketing'))"

      # Preformatted guid'...' not double quoted in filter_eq
      q5 =
        Query.new("Contact")
        |> Query.filter_eq("Id", "guid'4c63c8fa-467b-48a6-973f-b2069298404f'")

      assert Query.to_params(q5)["$filter"] == "Id eq guid'4c63c8fa-467b-48a6-973f-b2069298404f'"
    end
  end
end
