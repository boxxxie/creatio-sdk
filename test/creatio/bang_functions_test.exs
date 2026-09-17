defmodule Creatio.BangFunctionsTest do
  use ExUnit.Case

  test "odata error paths" do
    req_err = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req_err, base_url: "http://test")

    assert_raise Creatio.Error, fn -> Creatio.OData.list!(client, "Contact") end
    assert_raise Creatio.Error, fn -> Creatio.OData.get!(client, "Contact", "123") end

    assert_raise Creatio.Error, fn ->
      Creatio.OData.get_navigation!(client, "Contact", "123", "Account")
    end

    assert_raise Creatio.Error, fn ->
      Creatio.OData.get_field!(client, "Contact", "123", "Name")
    end

    assert_raise Creatio.Error, fn -> Creatio.OData.count!(client, "Contact") end
    assert_raise Creatio.Error, fn -> Creatio.OData.create!(client, "Contact", %{}) end
    assert_raise Creatio.Error, fn -> Creatio.OData.update!(client, "Contact", "123", %{}) end
    assert_raise Creatio.Error, fn -> Creatio.OData.delete!(client, "Contact", "123") end

    q = %Creatio.OData.Query{entity: "Contact"}
    assert_raise Creatio.Error, fn -> Creatio.OData.list!(q, client, []) end

    assert {:error, _} = Creatio.OData.list(q, client, [])
    assert_raise Creatio.Error, fn -> Creatio.OData.stream(q, client, []) |> Enum.to_list() end
  end

  test "odata3 error paths" do
    req_err = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req_err, base_url: "http://test")

    assert_raise Creatio.Error, fn -> Creatio.OData3.list!(client, "Contact") end
    assert_raise Creatio.Error, fn -> Creatio.OData3.get!(client, "Contact", "123") end
    assert_raise Creatio.Error, fn -> Creatio.OData3.count!(client, "Contact") end
    assert_raise Creatio.Error, fn -> Creatio.OData3.create!(client, "Contact", %{}) end
    assert_raise Creatio.Error, fn -> Creatio.OData3.update!(client, "Contact", "123", %{}) end
    assert_raise Creatio.Error, fn -> Creatio.OData3.delete!(client, "Contact", "123") end

    q = %Creatio.OData.Query{entity: "Contact"}
    assert_raise Creatio.Error, fn -> Creatio.OData3.list!(q, client, []) end
    assert_raise Creatio.Error, fn -> Creatio.OData3.stream!(q, client, []) |> Enum.to_list() end

    assert {:error, _} = Creatio.OData3.list(q, client, [])
    assert_raise Creatio.Error, fn -> Creatio.OData3.stream(q, client, []) |> Enum.to_list() end
  end

  test "query options" do
    q = %Creatio.OData.Query{entity: "Contact", select: [], filter: "", orderby: [], expand: []}
    p = Creatio.OData.Query.to_params(q)
    assert p["$select"] == nil
  end

  test "DataService.custom_service error" do
    req_err = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req_err, base_url: "http://test")

    assert {:error, _} = Creatio.DataService.custom_service(client, "A", "B", %{})
    assert {:error, _} = Creatio.DataService.custom_service(client, "A", "B", method: :get)
    assert {:error, _} = Creatio.DataService.custom_service(client, "A", "B", [1, 2, 3], [])

    assert {:error, _} =
             Creatio.DataService.custom_service(client, "A", "B", %{"x" => 1}, method: :delete)
  end

  test "OData success paths" do
    req_ok =
      Req.new(
        plug: fn conn ->
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"value" => []}))
        end,
        retry: false
      )

    client = Creatio.Client.from_req(req_ok, base_url: "http://test")

    q = %Creatio.OData.Query{entity: "Contact"}
    assert Creatio.OData.list!(q, client, []) == []
    assert Creatio.OData.stream(q, client, []) |> Enum.to_list() == []
  end

  test "OData3 success paths" do
    req_ok =
      Req.new(
        plug: fn conn ->
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"d" => %{"results" => []}}))
        end,
        retry: false
      )

    client = Creatio.Client.from_req(req_ok, base_url: "http://test")

    q = %Creatio.OData.Query{entity: "Contact"}
    assert Creatio.OData3.list!(q, client, []) == []
    assert Creatio.OData3.stream!(q, client, []) |> Enum.to_list() == []
  end

  test "Auth openid config error" do
    req_err = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req_err, base_url: "http://test")

    assert {:error, _} = Creatio.openid_configuration(client)
  end

  test "batch success paths" do
    resp = """
    --batchresponse_123
    Content-Type: application/http

    HTTP/1.1 200 OK
    Content-Type: application/json; odata=verbose

    {"d": {"results": []}}
    --batchresponse_123--
    """

    req_ok =
      Req.new(
        plug: fn conn ->
          Plug.Conn.put_resp_header(
            conn,
            "content-type",
            "multipart/mixed; boundary=batchresponse_123"
          )
          |> Plug.Conn.send_resp(200, resp)
        end,
        retry: false
      )

    client = Creatio.Client.from_req(req_ok, base_url: "http://test")

    batch = Creatio.Batch.new()
    batch = Creatio.Batch.add(batch, "GET", "Contact")
    assert {:ok, _} = Creatio.OData.batch(client, batch)
  end

  test "Creatio delegates" do
    req = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req, base_url: "http://test")

    assert {:error, _} = Creatio.login(client, "u", "p")
    assert {:error, _} = Creatio.login_oauth(client)
    assert {:error, _} = Creatio.oauth_health_check(client)
    assert {:error, _} = Creatio.openid_configuration("http://url")

    assert {:error, _} = Creatio.batch(client, [])
    assert_raise Creatio.Error, fn -> Creatio.batch!(client, []) end

    assert_raise Creatio.Error, fn -> Creatio.stream(client, "A") |> Enum.to_list() end
  end

  test "OData params normalization" do
    req = Req.new(plug: fn conn -> Plug.Conn.send_resp(conn, 500, "{}") end, retry: false)
    client = Creatio.Client.from_req(req, base_url: "http://test")

    params = [
      select: ["Id", :Name],
      select: "Id",
      expand: ["Account", :Owner],
      expand: "Account",
      orderby: ["Id desc", :Name],
      orderby: "Id desc",
      params: %{"$select" => "Id"},
      some_key: ["A", "B"],
      some_key2: "A",
      some_key3: :A
    ]

    assert {:error, _} = Creatio.OData.list(client, "Contact", params)
    assert {:error, _} = Creatio.OData3.list(client, "Contact", params)
  end

  test "Error coverage" do
    Creatio.Error.from_response(%Req.Response{
      status: 400,
      body: %{"error" => %{"message" => "A", "code" => "B"}}
    })

    Creatio.Error.from_response(%Req.Response{
      status: 400,
      body: %{"error" => %{"Message" => "A", "ErrorCode" => "B"}}
    })

    Creatio.Error.from_response(%Req.Response{
      status: 400,
      body: %{"message" => "A", "code" => "B"}
    })

    Creatio.Error.from_response(%Req.Response{
      status: 400,
      body: %{"Exception" => %{"Message" => "A", "ErrorCode" => "B"}}
    })

    Creatio.Error.from_response(%Req.Response{
      status: 400,
      body: %{"Exception" => %{"message" => "A", "errorCode" => "B"}}
    })

    Creatio.Error.from_response(%Req.Response{status: 400, body: %{"error_description" => "A"}})
  end

  test "OData / OData3 extra success paths" do
    req_ok =
      Req.new(
        plug: fn conn ->
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"value" => 42, "@odata.count" => 1}))
        end,
        retry: false
      )

    client = Creatio.Client.from_req(req_ok, base_url: "http://test")
    assert {:ok, _} = Creatio.OData.count(client, "Contact")
    assert {:ok, _} = Creatio.OData.get(client, "Contact", "1")
    assert {:ok, _} = Creatio.OData.get_navigation(client, "Contact", "1", "nav")
    assert {:ok, _} = Creatio.OData.get_field(client, "Contact", "1", "field")
    assert {:ok, _} = Creatio.OData.create(client, "Contact", %{})
    assert {:ok, _} = Creatio.OData.update(client, "Contact", "1", %{})
    assert :ok = Creatio.OData.delete(client, "Contact", "1")

    assert Creatio.OData.get!(client, "Contact", "1")
    assert Creatio.OData.get_navigation!(client, "Contact", "1", "nav")
    assert Creatio.OData.get_field!(client, "Contact", "1", "field")
    assert Creatio.OData.create!(client, "Contact", %{})
    assert Creatio.OData.update!(client, "Contact", "1", %{})
    assert Creatio.OData.delete!(client, "Contact", "1")
    assert Creatio.OData.count!(client, "Contact")

    req_ok3 =
      Req.new(
        plug: fn conn ->
          Plug.Conn.put_resp_content_type(conn, "application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"d" => %{"results" => [], "count" => 1}}))
        end,
        retry: false
      )

    client3 = Creatio.Client.from_req(req_ok3, base_url: "http://test")
    assert {:ok, _} = Creatio.OData3.count(client3, "Contact")
    assert {:ok, _} = Creatio.OData3.get(client3, "Contact", "1")
    assert {:ok, _} = Creatio.OData3.create(client3, "Contact", %{})
    assert {:ok, _} = Creatio.OData3.update(client3, "Contact", "1", %{})
    assert :ok = Creatio.OData3.delete(client3, "Contact", "1")

    assert Creatio.OData3.get!(client3, "Contact", "1")
    assert Creatio.OData3.create!(client3, "Contact", %{})
    assert Creatio.OData3.update!(client3, "Contact", "1", %{})
    assert Creatio.OData3.delete!(client3, "Contact", "1")
    assert Creatio.OData3.count!(client3, "Contact")
  end
end
