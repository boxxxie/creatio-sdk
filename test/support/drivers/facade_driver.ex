defmodule Creatio.TestDrivers.FacadeDriver do
  @moduledoc """
  Layer 3 Protocol Driver exercising top-level `Creatio` facade functions.
  """

  alias Creatio.Batch
  alias Creatio.OData.Query
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

  @doc """
  Configures server stubs for all facade endpoints used across delegation tests.
  """
  def stub_full_crm_server(ctx) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_list("Contact",
      records: [%{"Id" => "1", "Name" => "Test"}]
    )
    |> CreatioServerDriver.stub_odata_get("Contact", "1",
      record: %{"Id" => "1", "Name" => "Test"}
    )
    |> CreatioServerDriver.stub_odata_create("Contact", assigned_id: "new-id")
    |> CreatioServerDriver.stub_odata_update("Contact", "1")
    |> CreatioServerDriver.stub_odata_delete("Contact", "1")
    |> CreatioServerDriver.stub_odata_count("Contact", count: 42)
    |> CreatioServerDriver.stub_odata_navigation("Contact", "1", "Account",
      record: %{"Name" => "Acme"}
    )
    |> CreatioServerDriver.stub_odata_field("Contact", "1", "Name", value: "Test")
    |> CreatioServerDriver.stub_odata_field("Contact", "1", "Name", value: "RawName", raw: true)
    |> CreatioServerDriver.stub_odata_update_field("Contact", "1", "Photo")
    |> CreatioServerDriver.stub_odata_delete_field("Contact", "1", "Photo")
    |> CreatioServerDriver.stub_data_service("SelectQuery",
      body: %{"rows" => [%{"Name" => "Corp"}], "success" => true}
    )
    |> CreatioServerDriver.stub_data_service("InsertQuery", body: %{"id" => "inserted-id"})
    |> CreatioServerDriver.stub_data_service("UpdateQuery", body: %{"rowsAffected" => 1})
    |> CreatioServerDriver.stub_data_service("DeleteQuery", body: %{"rowsAffected" => 1})
    |> CreatioServerDriver.stub_data_service("BatchQuery", body: %{"responses" => []})
    |> CreatioServerDriver.stub_data_service("GenericAction", body: %{"success" => true})
    |> CreatioServerDriver.stub_custom_service("CustomSvc", "Echo", echo: true)
    |> CreatioServerDriver.stub_custom_service("CustomSvc", "Ping",
      method: :get,
      body: %{"status" => "pong"}
    )
    |> CreatioServerDriver.stub_odata3_list("Contact", records: [%{"Name" => "Legacy"}])
    |> CreatioServerDriver.stub_odata3_get("Contact", "1", record: %{"Name" => "Legacy"})
    |> CreatioServerDriver.stub_odata3_navigation("Contact", "1", "Account",
      record: %{"Name" => "Legacy Org"}
    )
    |> CreatioServerDriver.stub_odata3_field("Contact", "1", "Name", value: "Legacy Name")
    |> CreatioServerDriver.stub_odata3_field("Contact", "1", "Name",
      value: "Raw Legacy Name",
      raw: true
    )
    |> CreatioServerDriver.stub_odata3_count("Contact", count: 99)
    |> CreatioServerDriver.stub_odata3_create("Contact", body: %{"d" => %{"Id" => "new-1"}})
    |> CreatioServerDriver.stub_odata3_update("Contact", "1")
    |> CreatioServerDriver.stub_odata3_delete("Contact", "1")
    |> CreatioServerDriver.stub_batch(
      responses: [%{"id" => "req_1", "status" => 200, "body" => %{"Id" => "1"}}]
    )
    |> CreatioServerDriver.stub_forms_login(
      cookies: [".ASPXAUTH=FacadeToken; path=/", "BPMCSRF=facade_csrf; path=/"]
    )
    |> CreatioServerDriver.stub_oauth_token(access_token: "facade_oauth_token")
    |> CreatioServerDriver.stub_oauth_health(body: %{"status" => "Healthy"})
    |> CreatioServerDriver.stub_openid_configuration(body: %{"issuer" => "test"})
  end

  @doc """
  Invokes a top-level `Creatio` facade operation by specification tuple and stores `:result` in `ctx`.
  """
  def invoke_facade(ctx, spec) do
    client =
      CreatioServerDriver.client(ctx,
        identity_service_url: "https://mycreatio.com",
        client_id: "c",
        client_secret: "s"
      )

    result = dispatch(ctx, client, spec)
    Map.put(ctx, :result, result)
  end

  defp dispatch(_ctx, client, {:list, entity}), do: Creatio.list(client, entity)

  defp dispatch(_ctx, client, {:list!, entity}),
    do: capture(fn -> Creatio.list!(client, entity) end)

  defp dispatch(_ctx, client, {:list_query_first, entity}),
    do: Creatio.list(Query.new(entity), client)

  defp dispatch(_ctx, client, {:list_query_first!, entity}),
    do: capture(fn -> Creatio.list!(Query.new(entity), client) end)

  defp dispatch(_ctx, client, {:execute, entity}), do: Creatio.execute(client, entity)

  defp dispatch(_ctx, client, {:execute!, entity}),
    do: capture(fn -> Creatio.execute!(client, entity) end)

  defp dispatch(_ctx, client, {:execute_query_first, entity}),
    do: Creatio.execute(Query.new(entity), client)

  defp dispatch(_ctx, client, {:execute_query_first!, entity}),
    do: capture(fn -> Creatio.execute!(Query.new(entity), client) end)

  defp dispatch(_ctx, client, {:get, entity, id}), do: Creatio.get(client, entity, id)

  defp dispatch(_ctx, client, {:get!, entity, id}),
    do: capture(fn -> Creatio.get!(client, entity, id) end)

  defp dispatch(_ctx, client, {:create, entity, attrs}), do: Creatio.create(client, entity, attrs)

  defp dispatch(_ctx, client, {:create!, entity, attrs}),
    do: capture(fn -> Creatio.create!(client, entity, attrs) end)

  defp dispatch(_ctx, client, {:update, entity, id, attrs}),
    do: Creatio.update(client, entity, id, attrs)

  defp dispatch(_ctx, client, {:update!, entity, id, attrs}),
    do: capture(fn -> Creatio.update!(client, entity, id, attrs) end)

  defp dispatch(_ctx, client, {:delete, entity, id}), do: Creatio.delete(client, entity, id)

  defp dispatch(_ctx, client, {:delete!, entity, id}),
    do: capture(fn -> Creatio.delete!(client, entity, id) end)

  defp dispatch(_ctx, client, {:count, entity}), do: Creatio.count(client, entity)

  defp dispatch(_ctx, client, {:count!, entity}),
    do: capture(fn -> Creatio.count!(client, entity) end)

  defp dispatch(_ctx, client, {:get_navigation, entity, id, nav}),
    do: Creatio.get_navigation(client, entity, id, nav)

  defp dispatch(_ctx, client, {:get_navigation!, entity, id, nav}),
    do: capture(fn -> Creatio.get_navigation!(client, entity, id, nav) end)

  defp dispatch(_ctx, client, {:get_field, entity, id, field}),
    do: Creatio.get_field(client, entity, id, field)

  defp dispatch(_ctx, client, {:get_field!, entity, id, field}),
    do: capture(fn -> Creatio.get_field!(client, entity, id, field) end)

  defp dispatch(_ctx, client, {:get_field_value, entity, id, field}),
    do: Creatio.get_field_value(client, entity, id, field)

  defp dispatch(_ctx, client, {:get_field_value!, entity, id, field}),
    do: capture(fn -> Creatio.get_field_value!(client, entity, id, field) end)

  defp dispatch(_ctx, client, {:update_field, entity, id, field, val}),
    do: Creatio.update_field(client, entity, id, field, val)

  defp dispatch(_ctx, client, {:update_field!, entity, id, field, val}),
    do: capture(fn -> Creatio.update_field!(client, entity, id, field, val) end)

  defp dispatch(_ctx, client, {:delete_field, entity, id, field}),
    do: Creatio.delete_field(client, entity, id, field)

  defp dispatch(_ctx, client, {:delete_field!, entity, id, field}),
    do: capture(fn -> Creatio.delete_field!(client, entity, id, field) end)

  defp dispatch(_ctx, client, {:stream, entity, opts}),
    do: {:ok, Creatio.stream(client, entity, opts) |> Enum.to_list()}

  defp dispatch(_ctx, client, {:stream!, entity, opts}),
    do: capture(fn -> Creatio.stream!(client, entity, opts) |> Enum.to_list() end)

  defp dispatch(_ctx, client, {:stream_query_first, entity, opts}),
    do: {:ok, Creatio.stream(Query.new(entity), client, opts) |> Enum.to_list()}

  defp dispatch(_ctx, client, {:stream_query_first!, entity, opts}),
    do: capture(fn -> Creatio.stream!(Query.new(entity), client, opts) |> Enum.to_list() end)

  defp dispatch(_ctx, client, {:select_query, payload}), do: Creatio.select_query(client, payload)

  defp dispatch(_ctx, client, {:select_query!, payload}),
    do: capture(fn -> Creatio.select_query!(client, payload) end)

  defp dispatch(_ctx, client, {:insert_query, payload}), do: Creatio.insert_query(client, payload)

  defp dispatch(_ctx, client, {:insert_query!, payload}),
    do: capture(fn -> Creatio.insert_query!(client, payload) end)

  defp dispatch(_ctx, client, {:update_query, payload}), do: Creatio.update_query(client, payload)

  defp dispatch(_ctx, client, {:update_query!, payload}),
    do: capture(fn -> Creatio.update_query!(client, payload) end)

  defp dispatch(_ctx, client, {:delete_query, payload}), do: Creatio.delete_query(client, payload)

  defp dispatch(_ctx, client, {:delete_query!, payload}),
    do: capture(fn -> Creatio.delete_query!(client, payload) end)

  defp dispatch(_ctx, client, {:batch_query, payload}), do: Creatio.batch_query(client, payload)

  defp dispatch(_ctx, client, {:batch_query!, payload}),
    do: capture(fn -> Creatio.batch_query!(client, payload) end)

  defp dispatch(_ctx, client, {:data_service_query, action, payload}),
    do: Creatio.data_service_query(client, action, payload)

  defp dispatch(_ctx, client, {:data_service_query!, action, payload}),
    do: capture(fn -> Creatio.data_service_query!(client, action, payload) end)

  defp dispatch(_ctx, client, {:custom_service, svc, endpoint, payload, opts}),
    do: Creatio.custom_service(client, svc, endpoint, payload, opts)

  defp dispatch(_ctx, client, {:custom_service!, svc, endpoint, payload, opts}),
    do: capture(fn -> Creatio.custom_service!(client, svc, endpoint, payload, opts) end)

  defp dispatch(_ctx, client, {:custom_service_opts, svc, endpoint, opts}),
    do: Creatio.custom_service(client, svc, endpoint, opts)

  defp dispatch(_ctx, client, {:custom_service_opts!, svc, endpoint, opts}),
    do: capture(fn -> Creatio.custom_service!(client, svc, endpoint, opts) end)

  defp dispatch(_ctx, client, {:odata3_list, entity}), do: Creatio.odata3_list(client, entity)

  defp dispatch(_ctx, client, {:odata3_list!, entity}),
    do: capture(fn -> Creatio.odata3_list!(client, entity) end)

  defp dispatch(_ctx, client, {:odata3_list_query_first, entity}),
    do: Creatio.odata3_list(Query.new(entity), client)

  defp dispatch(_ctx, client, {:odata3_list_query_first!, entity}),
    do: capture(fn -> Creatio.odata3_list!(Query.new(entity), client) end)

  defp dispatch(_ctx, client, {:odata3_get, entity, id}),
    do: Creatio.odata3_get(client, entity, id)

  defp dispatch(_ctx, client, {:odata3_get!, entity, id}),
    do: capture(fn -> Creatio.odata3_get!(client, entity, id) end)

  defp dispatch(_ctx, client, {:odata3_get_navigation, entity, id, nav}),
    do: Creatio.odata3_get_navigation(client, entity, id, nav)

  defp dispatch(_ctx, client, {:odata3_get_navigation!, entity, id, nav}),
    do: capture(fn -> Creatio.odata3_get_navigation!(client, entity, id, nav) end)

  defp dispatch(_ctx, client, {:odata3_get_field, entity, id, field}),
    do: Creatio.odata3_get_field(client, entity, id, field)

  defp dispatch(_ctx, client, {:odata3_get_field!, entity, id, field}),
    do: capture(fn -> Creatio.odata3_get_field!(client, entity, id, field) end)

  defp dispatch(_ctx, client, {:odata3_get_field_value, entity, id, field}),
    do: Creatio.odata3_get_field_value(client, entity, id, field)

  defp dispatch(_ctx, client, {:odata3_get_field_value!, entity, id, field}),
    do: capture(fn -> Creatio.odata3_get_field_value!(client, entity, id, field) end)

  defp dispatch(_ctx, client, {:odata3_count, entity}), do: Creatio.odata3_count(client, entity)

  defp dispatch(_ctx, client, {:odata3_count!, entity}),
    do: capture(fn -> Creatio.odata3_count!(client, entity) end)

  defp dispatch(_ctx, client, {:odata3_create, entity, attrs}),
    do: Creatio.odata3_create(client, entity, attrs)

  defp dispatch(_ctx, client, {:odata3_create!, entity, attrs}),
    do: capture(fn -> Creatio.odata3_create!(client, entity, attrs) end)

  defp dispatch(_ctx, client, {:odata3_update, entity, id, attrs}),
    do: Creatio.odata3_update(client, entity, id, attrs)

  defp dispatch(_ctx, client, {:odata3_update!, entity, id, attrs}),
    do: capture(fn -> Creatio.odata3_update!(client, entity, id, attrs) end)

  defp dispatch(_ctx, client, {:odata3_delete, entity, id}),
    do: Creatio.odata3_delete(client, entity, id)

  defp dispatch(_ctx, client, {:odata3_delete!, entity, id}),
    do: capture(fn -> Creatio.odata3_delete!(client, entity, id) end)

  defp dispatch(_ctx, client, {:odata3_stream, entity, opts}),
    do: {:ok, Creatio.odata3_stream(client, entity, opts) |> Enum.to_list()}

  defp dispatch(_ctx, client, {:odata3_stream!, entity, opts}),
    do: capture(fn -> Creatio.odata3_stream!(client, entity, opts) |> Enum.to_list() end)

  defp dispatch(_ctx, client, {:odata3_stream_query_first, entity, opts}),
    do: {:ok, Creatio.odata3_stream(Query.new(entity), client, opts) |> Enum.to_list()}

  defp dispatch(_ctx, client, {:odata3_stream_query_first!, entity, opts}),
    do:
      capture(fn -> Creatio.odata3_stream!(Query.new(entity), client, opts) |> Enum.to_list() end)

  defp dispatch(_ctx, client, {:batch_get, entity, id}) do
    batch = Creatio.batch_new() |> Batch.add_get(entity, id)
    Creatio.batch(client, batch)
  end

  defp dispatch(_ctx, client, {:batch_get!, entity, id}) do
    batch = Creatio.batch_new() |> Batch.add_get(entity, id)
    capture(fn -> Creatio.batch!(client, batch) end)
  end

  defp dispatch(_ctx, _client, {:batch_to_multipart, entity, id}) do
    batch = Creatio.batch_new() |> Batch.add_get(entity, id)
    {boundary, _body} = Creatio.batch_to_multipart(batch)
    {:ok, %{has_boundary: is_binary(boundary)}}
  end

  defp dispatch(_ctx, _client, {:batch_parse_multipart, raw, boundary}),
    do: Creatio.batch_parse_multipart(raw, boundary)

  defp dispatch(_ctx, _client, {:batch_parse_multipart_sample}) do
    raw = """
    --batchresponse_sample
    Content-Type: application/http
    Content-Transfer-Encoding: binary
    Content-ID: req_1

    HTTP/1.1 200 OK
    Content-Type: application/json

    {"Id":"1","Name":"Test"}
    --batchresponse_sample--
    """

    raw
    |> String.replace("\n", "\r\n")
    |> Creatio.batch_parse_multipart("batchresponse_sample")
  end

  defp dispatch(_ctx, _client, {:query_helper, entity, fields}) do
    q = Creatio.query(entity) |> Query.select(fields)
    select_fields = (Query.to_params(q)["$select"] || "") |> String.split(",", trim: true)
    {:ok, %{entity: Query.entity(q), select: select_fields}}
  end

  defp dispatch(_ctx, _client, {:new_client, base_url}),
    do: {:ok, Creatio.new(base_url: base_url).base_url}

  defp dispatch(_ctx, _client, {:from_req, base_url}) do
    req = Req.new(base_url: base_url)
    {:ok, Creatio.from_req(req).base_url}
  end

  defp dispatch(_ctx, client, {:login, user, pass}) do
    case Creatio.login(client, user, pass) do
      {:ok, authed} -> {:ok, %{auth_mode: authed.auth_mode}}
      other -> other
    end
  end

  defp dispatch(_ctx, client, {:login_oauth}) do
    case Creatio.login_oauth(client) do
      {:ok, authed, token} ->
        {:ok, %{auth_mode: authed.auth_mode, access_token: token["access_token"]}}

      other ->
        other
    end
  end

  defp dispatch(_ctx, client, {:oauth_health_check}), do: Creatio.oauth_health_check(client)

  defp dispatch(ctx, client, {:openid_configuration}) do
    req_opts = CreatioServerDriver.req_options_for_server(ctx)
    Creatio.openid_configuration(client, req_options: req_opts)
  end

  defp capture(fun), do: CRMClientDriver.capture_bang(fun)
end
