defmodule Creatio.OData.QueryTest do
  use ExUnit.Case, async: true

  alias Creatio.OData.Query

  describe "query building and parameters" do
    test "select, expand, order_by, and pagination" do
      q =
        Query.new("Contact")
        |> Query.select(["Id", "Name"])
        |> Query.select("Email,MobilePhone")
        |> Query.expand(["Account", "Owner"])
        |> Query.expand("City")
        |> Query.order_by(["CreatedOn desc", "Name asc"])
        |> Query.top(25)
        |> Query.skip(50)
        |> Query.count(true)

      params = Query.to_params(q)

      assert params["$select"] == "Id,Name,Email,MobilePhone"
      assert params["$expand"] == "Account,Owner,City"
      assert params["$orderby"] == "CreatedOn desc,Name asc"
      assert params["$top"] == "25"
      assert params["$skip"] == "50"
      assert params["$count"] == "true"
    end

    test "omits empty select, expand, and order_by" do
      q =
        Query.new("Contact")
        |> Query.select([])
        |> Query.select("")
        |> Query.expand([])
        |> Query.expand("")
        |> Query.order_by([])
        |> Query.order_by("")

      params = Query.to_params(q)

      refute Map.has_key?(params, "$select")
      refute Map.has_key?(params, "$expand")
      refute Map.has_key?(params, "$orderby")
    end

    test "filter conditions and boolean logic" do
      q =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.filter_ne("Type", "Customer")
        |> Query.filter_gt("Age", 18)
        |> Query.filter_ge("Score", 85.5)
        |> Query.filter_lt("BirthDate", ~D[2000-01-01])
        |> Query.filter_le("CreatedOn", ~U[2024-01-01 00:00:00Z])
        |> Query.filter_in("Status", ["Lead", "Active"])
        |> Query.filter_contains("Name", "Smith")
        |> Query.filter_startswith("Email", "john")
        |> Query.filter_endswith("Email", ".com")
        |> Query.filter_day("CreatedOn", ~D[2024-01-01])
        |> Query.filter_day("CreatedOn", ~D[2024-01-01], :odata3)

      params = Query.to_params(q)
      assert is_binary(params["$filter"])
      assert params["$filter"] =~ "Active eq true"
      assert params["$filter"] =~ "Age gt 18"
      assert params["$filter"] =~ "day(CreatedOn)"
    end

    test "or_filter conditions" do
      q =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.or_filter_eq("VIP", true)
        |> Query.or_filter_ne("Status", "Archived")
        |> Query.or_filter_gt("Score", 90)
        |> Query.or_filter_ge("Rating", 4.5)
        |> Query.or_filter_lt("Debt", 100)
        |> Query.or_filter_le("Risk", 0.2)
        |> Query.or_filter_in("Category", [1, 2, 3])
        |> Query.or_filter_contains("Notes", "priority")
        |> Query.or_filter_startswith("Code", "VIP")
        |> Query.or_filter_endswith("Code", "99")
        |> Query.or_filter_day("UpdatedOn", ~D[2024-06-01])
        |> Query.or_filter_length("Name", 5)

      params = Query.to_params(q)
      assert params["$filter"] =~ " or "
    end

    test "GUID and identifier helpers" do
      q =
        Query.new("Contact")
        |> Query.filter_guid("Id", "c3b96696-22cf-46d4-8d4e-123456789abc")
        |> Query.or_filter_guid("AccountId", "guid'{e3b96696-22cf-46d4-8d4e-123456789abc}'")
        |> Query.filter_in_ids("CategoryId", ["id-1", "id-2"])
        |> Query.filter_not("Inactive eq true")

      params = Query.to_params(q)
      assert params["$filter"] =~ "not (Inactive eq true)"
      assert params["$filter"] =~ "c3b96696-22cf-46d4-8d4e-123456789abc"
    end

    test "query aliases and empty in-filters" do
      q =
        Query.new("Contact")
        |> Query.where("Active eq true")
        |> Query.or_where("VIP eq true")
        |> Query.where_eq("Department", "Sales")
        |> Query.filter_in("EmptyList", [])
        |> Query.or_filter_in("EmptyOrList", [])
        |> Query.filter_in_ids("EmptyIds", [])

      params = Query.to_params(q)
      assert params["$filter"] =~ "Active eq true"
      assert params["$filter"] =~ "Department eq 'Sales'"
    end
  end
end
