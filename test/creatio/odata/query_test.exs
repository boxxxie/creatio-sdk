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
        |> Query.filter_day("CreatedOn", 15, "ge")

      params = Query.to_params(q)
      assert is_binary(params["$filter"])
      assert params["$filter"] =~ "Active eq true"
      assert params["$filter"] =~ "Age gt 18"
      assert params["$filter"] =~ "day(CreatedOn) eq 1"
      assert params["$filter"] =~ "day(CreatedOn) ge 15"
    end

    test "filter_day validates comparison operators" do
      assert_raise ArgumentError, fn ->
        Query.new("Contact")
        |> Query.filter_day("CreatedOn", ~D[2024-01-01], :odata3)
      end

      assert_raise ArgumentError, fn ->
        Query.new("Contact")
        |> Query.or_filter_day("CreatedOn", 5, :bad_op)
      end
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
      assert params["$filter"] =~ "(Category eq 1 or Category eq 2 or Category eq 3)"
      assert params["$filter"] =~ "day(UpdatedOn) eq 1"
    end

    test "empty or_filter_in produces 1 eq 0 when filter is nil" do
      q = Query.new("Contact") |> Query.or_filter_in("Department", [])
      assert Query.to_params(q)["$filter"] == "1 eq 0"
    end

    test "filter_in_ids cleans braced and guid'-prefixed UUIDs" do
      q =
        Query.new("Contact")
        |> Query.filter_in_ids("Id", ["{aaa-111}", "guid'bbb-222'"])

      assert Query.to_params(q)["$filter"] == "(Id eq aaa-111 or Id eq bbb-222)"
    end

    test "select and expand trim comma-separated values and deduplicate" do
      q =
        Query.new("Contact")
        |> Query.select("Id, Name")
        |> Query.select(["Name", "Email"])
        |> Query.expand("Owner, Account")
        |> Query.expand(["Account", "City"])

      params = Query.to_params(q)
      assert params["$select"] == "Id,Name,Email"
      assert params["$expand"] == "Owner,Account,City"
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

    test "omits empty select, filter, orderby, and expand options from serialized params" do
      q =
        Query.new("Contact")
        |> Query.select([])
        |> Query.filter("")
        |> Query.order_by([])
        |> Query.expand([])

      p = Query.to_params(q)

      assert p == %{}
      assert Query.to_query_string(q) == ""
    end

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
        |> Query.param("customFlag", "true")

      params = Query.to_params(q)
      assert params["$select"] == "Id,Name,Email"
      assert params["$expand"] == "Account"
      assert params["$orderby"] == "Name asc,CreatedOn desc"
      assert params["customFlag"] == "true"
      assert String.contains?(params["$filter"], "Age gt 20")
      assert String.contains?(params["$filter"], "City/Name eq 'Toronto'")
      assert String.contains?(params["$filter"], "Status eq 'Active' or Status eq 'Pending'")

      qs = Query.to_query_string(q)
      assert String.contains?(qs, "%24select=Id%2CName%2CEmail")
    end

    test "supports all Postman collection filtration functions and operators" do
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

      q2 =
        Query.new("Collection3")
        |> Query.filter_eq("Collection6/Field6", "e9621f72-42bd-47c1", quoted: false)

      assert Query.to_params(q2)["$filter"] == "Collection6/Field6 eq e9621f72-42bd-47c1"

      q3 =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.filter_eq("Age", 30)
        |> Query.filter_eq("MiddleName", nil)

      params3 = Query.to_params(q3)
      assert params3["$filter"] =~ "Active eq true"
      assert params3["$filter"] =~ "Age eq 30"
      assert params3["$filter"] =~ "MiddleName eq null"

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

      q5 =
        Query.new("Collection1")
        |> Query.filter_day("Field3", "Field3Value")
        |> Query.filter_length("Field2", "Field2Value", "gt")

      params5 = Query.to_params(q5)
      assert params5["$filter"] =~ "day(Field3) eq Field3Value"
      assert params5["$filter"] =~ "length(Field2) gt Field2Value"

      q6 =
        Query.new("Collection1")
        |> Query.filter_endswith("Field2", "Field2Value")
        |> Query.filter_not()

      assert Query.to_params(q6)["$filter"] == "not (endswith(Field2,'Field2Value'))"

      q7 =
        Query.new("Contact")
        |> Query.filter_in_ids("Id", ["uuid-1", "uuid-2"])

      assert Query.to_params(q7)["$filter"] == "(Id eq uuid-1 or Id eq uuid-2)"

      q8 =
        Query.new("Contact")
        |> Query.filter_eq("City", "Toronto")
        |> Query.or_filter_eq("City", "Montreal")
        |> Query.or_filter_contains("Name", "Smith")

      params8 = Query.to_params(q8)
      assert params8["$filter"] =~ "or (City eq 'Montreal')"
      assert params8["$filter"] =~ "or (contains(Name,'Smith'))"
    end

    test "supports filter_guid, or_filter_guid, or_filter_in, and additional OR functions" do
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

      q4 =
        Query.new("Contact")
        |> Query.filter_eq("Active", true)
        |> Query.or_filter_in("Department", ["Sales", "Marketing", "Sales"])

      params4 = Query.to_params(q4)
      assert params4["$filter"] =~ "or ((Department eq 'Sales' or Department eq 'Marketing'))"

      q5 =
        Query.new("Contact")
        |> Query.filter_eq("Id", "guid'4c63c8fa-467b-48a6-973f-b2069298404f'")

      assert Query.to_params(q5)["$filter"] == "Id eq guid'4c63c8fa-467b-48a6-973f-b2069298404f'"
    end

    test "formats DateTime, NaiveDateTime, Date, and Time literals for OData 4 and OData 3" do
      dt = ~U[2024-05-01 14:30:00Z]
      ndt = ~N[2024-05-01 14:30:00]
      d = ~D[2024-05-01]
      t = ~T[09:15:30]

      odata4_query =
        Query.new("Contact")
        |> Query.filter_ge("CreatedOn", dt)
        |> Query.filter_lt("ModifiedOn", ndt)
        |> Query.filter_eq("BirthDate", d)
        |> Query.filter_gt("StartTime", t)

      odata4_filter = Query.to_params(odata4_query)["$filter"]
      assert odata4_filter =~ "CreatedOn ge 2024-05-01T14:30:00Z"
      assert odata4_filter =~ "ModifiedOn lt 2024-05-01T14:30:00Z"
      assert odata4_filter =~ "BirthDate eq 2024-05-01"
      assert odata4_filter =~ "StartTime gt 09:15:30"

      odata3_query =
        Query.new("Contact")
        |> Query.filter_ge("CreatedOn", dt, protocol: :odata3)
        |> Query.filter_lt("ModifiedOn", ndt, protocol: :odata3)
        |> Query.filter_eq("BirthDate", d, odata3: true)
        |> Query.filter_gt("StartTime", t, protocol: :odata3)

      odata3_filter = Query.to_params(odata3_query)["$filter"]
      assert odata3_filter =~ "CreatedOn ge datetime'2024-05-01T14:30:00Z'"
      assert odata3_filter =~ "ModifiedOn lt datetime'2024-05-01T14:30:00'"
      assert odata3_filter =~ "BirthDate eq datetime'2024-05-01T00:00:00'"
      assert odata3_filter =~ "StartTime gt time'09:15:30'"
    end

    test "handles empty filter_not, nil via or_filter_eq/or_filter_in, order_by/3, and false literals" do
      empty_not = Query.new("Contact") |> Query.filter_not()
      refute Map.has_key?(Query.to_params(empty_not), "$filter")

      or_nil_only = Query.new("Contact") |> Query.or_filter_eq("MiddleName", nil)
      assert Query.to_params(or_nil_only)["$filter"] == "MiddleName eq null"

      or_chained =
        Query.new("Contact")
        |> Query.filter_eq("Active", false)
        |> Query.or_filter_eq("MiddleName", nil)
        |> Query.or_filter_in("Suffix", [nil])
        |> Query.order_by(:Name, :asc)
        |> Query.order_by("CreatedOn", "desc")

      params = Query.to_params(or_chained)

      assert params["$filter"] ==
               "((Active eq false) or (MiddleName eq null)) or (Suffix eq null)"

      assert params["$orderby"] == "Name asc,CreatedOn desc"
    end

    test "expand preserves inner commas inside parentheses and splits only top-level clauses" do
      nested = "Account($expand=Type($select=Name);$select=Id,Name,Web,PrimaryContact)"

      q =
        Query.new("Contact")
        |> Query.expand("#{nested}, Owner($select=Id,Name,Title)")

      params = Query.to_params(q)

      assert params["$expand"] ==
               "#{nested},Owner($select=Id,Name,Title)"

      q_accumulated =
        Query.new("Contact")
        |> Query.expand(["Account($select=Id,Name,Web)", "City($select=Id,Name,Country)"])
        |> Query.expand("Account($select=Id,Name,Web)")

      assert Query.to_params(q_accumulated)["$expand"] ==
               "Account($select=Id,Name,Web),City($select=Id,Name,Country)"
    end

    test "expand/2 and filter helpers ignore parens and commas inside single-quoted OData strings" do
      q =
        Query.new("Contact")
        |> Query.expand(
          "Account($filter=Name eq 'Acme ) ''Quoted'', Inc.';$select=Id,Name), Owner($select=Id,Name)"
        )

      assert Query.to_params(q)["$expand"] ==
               "Account($filter=Name eq 'Acme ) ''Quoted'', Inc.';$select=Id,Name),Owner($select=Id,Name)"

      q_wrapped =
        Query.new("Contact")
        |> Query.and_filter("(Name eq 'Acme ) Corp')")
        |> Query.or_filter("City eq 'A''s, (B)'")

      assert Query.to_params(q_wrapped)["$filter"] ==
               "((Name eq 'Acme ) Corp')) or (City eq 'A''s, (B)')"
    end

    test "wraps quoted-paren OR clauses, escaped quotes, uppercase OR, and whitespace OR safely" do
      q_quoted_paren =
        Query.new("Contact")
        |> Query.filter("(Name eq 'a(') or (Name eq 'b)')")
        |> Query.filter_eq("AccountId", "tenant-1")

      assert Query.to_params(q_quoted_paren)["$filter"] ==
               "((Name eq 'a(') or (Name eq 'b)')) and AccountId eq 'tenant-1'"

      q_escaped =
        Query.new("Contact")
        |> Query.filter("(Name eq 'a''(') or (Name eq 'b)''')")
        |> Query.filter_eq("Active", true)

      assert Query.to_params(q_escaped)["$filter"] ==
               "((Name eq 'a''(') or (Name eq 'b)''')) and Active eq true"

      q_upper_or =
        Query.new("Contact")
        |> Query.filter("Name eq 'A' OR Name eq 'B'")
        |> Query.filter_eq("Active", true)

      assert Query.to_params(q_upper_or)["$filter"] ==
               "(Name eq 'A' OR Name eq 'B') and Active eq true"

      q_newline_or =
        Query.new("Contact")
        |> Query.filter("Name eq 'A'\n\tor\tName eq 'B'")
        |> Query.filter_eq("Active", true)

      assert Query.to_params(q_newline_or)["$filter"] ==
               "(Name eq 'A'\n\tor\tName eq 'B') and Active eq true"

      q_literal_or_only =
        Query.new("Contact")
        |> Query.filter("Name eq 'cat or dog'")
        |> Query.filter_eq("Active", true)

      assert Query.to_params(q_literal_or_only)["$filter"] ==
               "Name eq 'cat or dog' and Active eq true"
    end
  end

  describe "entity validation helpers" do
    test "new/1 handles nil and trims whitespace, and require_entity!/2 rejects empty targets" do
      assert Query.entity(Query.new(nil)) == ""
      assert Query.entity(Query.new("  Contact  ")) == "Contact"

      for invalid <- [Query.new(nil), Query.new("   "), nil, "   ", :Contact] do
        assert_raise ArgumentError, fn ->
          Query.require_entity!(invalid, "Creatio.OData.list/3")
        end
      end
    end
  end

  describe "encapsulation accessors & stream helpers" do
    test "entity/1, get_top/1, get_skip/1 expose builder state without struct access" do
      base = Query.new("Contact")
      assert Query.entity(base) == "Contact"
      assert Query.get_top(base) == nil
      assert Query.get_skip(base) == nil

      limited = base |> Query.top(25) |> Query.skip(50)
      assert Query.entity(limited) == "Contact"
      assert Query.get_top(limited) == 25
      assert Query.get_skip(limited) == 50
    end

    test "reset_stream_target/1 clears top and skip while preserving query clauses" do
      q =
        Query.new("Contact")
        |> Query.select(["Id", "Name"])
        |> Query.filter_eq("Active", true)
        |> Query.order_by("Name asc")
        |> Query.expand("Account($select=Id)")
        |> Query.top(10)
        |> Query.skip(20)

      reset = Query.reset_stream_target(q)
      assert Query.get_top(reset) == nil
      assert Query.get_skip(reset) == nil

      params = Query.to_params(reset)
      assert params["$select"] == "Id,Name"
      assert params["$filter"] == "Active eq true"
      assert params["$orderby"] == "Name asc"
      assert params["$expand"] == "Account($select=Id)"
      refute Map.has_key?(params, "$top")
      refute Map.has_key?(params, "$skip")
    end

    test "strip_filter_and_order/1 clears filter and orderby while keeping select, expand, top, and skip" do
      q =
        Query.new("Contact")
        |> Query.select(["Id", "Name"])
        |> Query.filter_eq("Active", true)
        |> Query.order_by("Name desc")
        |> Query.expand("Account($select=Id)")
        |> Query.top(15)
        |> Query.skip(5)

      stripped = Query.strip_filter_and_order(q)
      params = Query.to_params(stripped)

      assert params["$select"] == "Id,Name"
      assert params["$expand"] == "Account($select=Id)"
      assert params["$top"] == "15"
      assert params["$skip"] == "5"
      refute Map.has_key?(params, "$filter")
      refute Map.has_key?(params, "$orderby")
    end
  end
end
