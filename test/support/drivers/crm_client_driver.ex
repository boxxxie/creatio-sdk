defmodule Creatio.TestDrivers.CRMClientDriver do
  @moduledoc """
  Layer 3 Protocol Driver invoking `Creatio` SDK modules and capturing results in `ctx`.

  Keeps direct SDK module calls, Req client wrapping, and bang exception capture
  encapsulated below Layer 2 DSLs.
  """

  alias Creatio.{Auth, Batch, Client, DataService, Error, OData, OData3}
  alias Creatio.OData.Query
  alias Creatio.TestDrivers.CreatioServerDriver

  @doc """
  Returns the active `%Creatio.Client{}` from `ctx` or constructs one bound to the server driver.
  """
  def current_client(%{client: %Client{} = client}), do: client
  def current_client(ctx), do: CreatioServerDriver.client(ctx)

  @doc """
  Returns either the configured `%Req.Request{}` or `%Creatio.Client{}` target from `ctx`.
  """
  def current_target(%{raw_req: %Req.Request{} = req}), do: req
  def current_target(ctx), do: current_client(ctx)

  @doc """
  Executes a function expected to return normally or raise `%Creatio.Error{}`.
  Returns `{:ok, value}` or `{:raised, %Creatio.Error{}}`.
  """
  def capture_bang(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    err in Error -> {:raised, err}
  end

  # ---------------------------------------------------------------------------
  # Authentication Operations
  # ---------------------------------------------------------------------------

  def login_forms(ctx, username, password, opts \\ []) do
    target = current_target(ctx)
    result = Auth.login_forms(target, username, password, opts)

    ctx =
      case result do
        {:ok, %Client{} = authed} -> Map.put(ctx, :client, authed)
        _ -> ctx
      end

    Map.put(ctx, :result, result)
  end

  def login_oauth(ctx, opts \\ []) do
    client = current_client(ctx)
    result = Auth.login_oauth(client, opts)

    ctx =
      case result do
        {:ok, %Client{} = authed, _token} -> Map.put(ctx, :client, authed)
        _ -> ctx
      end

    Map.put(ctx, :result, result)
  end

  def oauth_health_check(ctx, opts \\ []) do
    client = current_client(ctx)
    Map.put(ctx, :result, Auth.oauth_health_check(client, opts))
  end

  def openid_configuration(ctx, opts \\ []) do
    {target_mode, driver_opts} = Keyword.pop(opts, :target, :client)

    result =
      case target_mode do
        :url ->
          url =
            driver_opts
            |> Keyword.fetch!(:url)
            |> String.trim_trailing("/")
            |> then(fn u ->
              if String.ends_with?(u, "/.well-known/openid-configuration"),
                do: u,
                else: "#{u}/.well-known/openid-configuration"
            end)

          req_opts = CreatioServerDriver.req_options_for_server(ctx)
          Auth.openid_configuration(url, req_options: req_opts)

        _ ->
          client = current_client(ctx)
          req_opts = CreatioServerDriver.req_options_for_server(ctx)
          Auth.openid_configuration(client, Keyword.put_new(driver_opts, :req_options, req_opts))
      end

    Map.put(ctx, :result, result)
  end

  # ---------------------------------------------------------------------------
  # OData 4 Operations
  # ---------------------------------------------------------------------------

  def odata_list(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, list_opts} = Keyword.pop(opts, :bang, false)
    {query_first?, list_opts} = Keyword.pop(list_opts, :query_first, false)

    result =
      cond do
        bang? and query_first? ->
          capture_bang(fn -> OData.list!(entity_or_query, target, list_opts) end)

        bang? ->
          capture_bang(fn -> OData.list!(target, entity_or_query, list_opts) end)

        query_first? ->
          OData.list(entity_or_query, target, list_opts)

        true ->
          OData.list(target, entity_or_query, list_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_execute(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, exec_opts} = Keyword.pop(opts, :bang, false)
    {query_first?, exec_opts} = Keyword.pop(exec_opts, :query_first, false)

    result =
      cond do
        bang? and query_first? ->
          capture_bang(fn -> OData.execute!(entity_or_query, target, exec_opts) end)

        bang? ->
          capture_bang(fn -> OData.execute!(target, entity_or_query, exec_opts) end)

        query_first? ->
          OData.execute(entity_or_query, target, exec_opts)

        true ->
          OData.execute(target, entity_or_query, exec_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_get(ctx, entity, id, opts \\ []) do
    target = current_target(ctx)
    {bang?, get_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.get!(target, entity, id, get_opts) end)
      else
        OData.get(target, entity, id, get_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_get_navigation(ctx, entity, id, nav, opts \\ []) do
    target = current_target(ctx)
    {bang?, nav_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.get_navigation!(target, entity, id, nav, nav_opts) end)
      else
        OData.get_navigation(target, entity, id, nav, nav_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_get_field(ctx, entity, id, field, opts \\ []) do
    target = current_target(ctx)
    {bang?, field_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.get_field!(target, entity, id, field, field_opts) end)
      else
        OData.get_field(target, entity, id, field, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_get_field_value(ctx, entity, id, field, opts \\ []) do
    target = current_target(ctx)
    bang? = Keyword.get(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.get_field_value!(target, entity, id, field) end)
      else
        OData.get_field_value(target, entity, id, field)
      end

    Map.put(ctx, :result, result)
  end

  def odata_count(ctx, entity, opts \\ []) do
    target = current_target(ctx)
    {bang?, count_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.count!(target, entity, count_opts) end)
      else
        OData.count(target, entity, count_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_create(ctx, entity, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, create_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.create!(target, entity, attrs, create_opts) end)
      else
        OData.create(target, entity, attrs, create_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_update(ctx, entity, id, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, update_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.update!(target, entity, id, attrs, update_opts) end)
      else
        OData.update(target, entity, id, attrs, update_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_delete(ctx, entity, id, opts \\ []) do
    target = current_target(ctx)
    {bang?, delete_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.delete!(target, entity, id, delete_opts) end)
      else
        OData.delete(target, entity, id, delete_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_update_field(ctx, entity, id, field, value, opts \\ []) do
    target = current_target(ctx)
    {bang?, field_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.update_field!(target, entity, id, field, value, field_opts) end)
      else
        OData.update_field(target, entity, id, field, value, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_delete_field(ctx, entity, id, field, opts \\ []) do
    target = current_target(ctx)
    {bang?, field_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData.delete_field!(target, entity, id, field, field_opts) end)
      else
        OData.delete_field(target, entity, id, field, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_stream(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {take_n, stream_opts} = Keyword.pop(opts, :take)
    {query_first?, stream_opts} = Keyword.pop(stream_opts, :query_first, false)

    result =
      capture_bang(fn ->
        stream =
          if query_first? do
            OData.stream(entity_or_query, target, stream_opts)
          else
            OData.stream(target, entity_or_query, stream_opts)
          end

        if is_integer(take_n), do: Enum.take(stream, take_n), else: Enum.to_list(stream)
      end)

    Map.put(ctx, :result, result)
  end

  # ---------------------------------------------------------------------------
  # OData 3 Legacy Operations
  # ---------------------------------------------------------------------------

  def odata3_list(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, list_opts} = Keyword.pop(opts, :bang, false)
    {query_first?, list_opts} = Keyword.pop(list_opts, :query_first, false)

    result =
      cond do
        bang? and query_first? ->
          capture_bang(fn -> OData3.list!(entity_or_query, target, list_opts) end)

        bang? ->
          capture_bang(fn -> OData3.list!(target, entity_or_query, list_opts) end)

        query_first? ->
          OData3.list(entity_or_query, target, list_opts)

        true ->
          OData3.list(target, entity_or_query, list_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_get(ctx, entity, id, opts \\ []) do
    target = current_target(ctx)
    {bang?, get_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.get!(target, entity, id, get_opts) end)
      else
        OData3.get(target, entity, id, get_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_get_navigation(ctx, entity, id, nav, opts \\ []) do
    target = current_target(ctx)
    {bang?, nav_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.get_navigation!(target, entity, id, nav, nav_opts) end)
      else
        OData3.get_navigation(target, entity, id, nav, nav_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_get_field(ctx, entity, id, field, opts \\ []) do
    target = current_target(ctx)
    {bang?, field_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.get_field!(target, entity, id, field, field_opts) end)
      else
        OData3.get_field(target, entity, id, field, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_get_field_value(ctx, entity, id, field, opts \\ []) do
    target = current_target(ctx)
    bang? = Keyword.get(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.get_field_value!(target, entity, id, field) end)
      else
        OData3.get_field_value(target, entity, id, field)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_count(ctx, entity, opts \\ []) do
    target = current_target(ctx)
    {bang?, count_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.count!(target, entity, count_opts) end)
      else
        OData3.count(target, entity, count_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_create(ctx, entity, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, create_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.create!(target, entity, attrs, create_opts) end)
      else
        OData3.create(target, entity, attrs, create_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_update(ctx, entity, id, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, update_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.update!(target, entity, id, attrs, update_opts) end)
      else
        OData3.update(target, entity, id, attrs, update_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_delete(ctx, entity, id, opts \\ []) do
    target = current_target(ctx)
    {bang?, delete_opts} = Keyword.pop(opts, :bang, false)

    result =
      if bang? do
        capture_bang(fn -> OData3.delete!(target, entity, id, delete_opts) end)
      else
        OData3.delete(target, entity, id, delete_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_stream(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, stream_opts} = Keyword.pop(opts, :bang, false)
    {query_first?, stream_opts} = Keyword.pop(stream_opts, :query_first, false)

    result =
      capture_bang(fn ->
        stream =
          cond do
            bang? and query_first? -> OData3.stream!(entity_or_query, target, stream_opts)
            bang? -> OData3.stream!(target, entity_or_query, stream_opts)
            query_first? -> OData3.stream(entity_or_query, target, stream_opts)
            true -> OData3.stream(target, entity_or_query, stream_opts)
          end

        Enum.to_list(stream)
      end)

    Map.put(ctx, :result, result)
  end

  # ---------------------------------------------------------------------------
  # Batch & DataService Operations
  # ---------------------------------------------------------------------------

  def execute_batch(ctx, batch_or_raw, opts \\ []) do
    target = current_target(ctx)
    {via, opts} = Keyword.pop(opts, :via, :batch)
    {bang?, batch_opts} = Keyword.pop(opts, :bang, false)

    result =
      case {via, bang?} do
        {:odata, true} -> capture_bang(fn -> OData.batch!(target, batch_or_raw, batch_opts) end)
        {:odata, false} -> OData.batch(target, batch_or_raw, batch_opts)
        {:batch, false} -> Batch.execute(target, batch_or_raw, batch_opts)
      end

    Map.put(ctx, :result, result)
  end

  def data_service_call(ctx, kind, payload_or_action, opts \\ []) do
    target = current_target(ctx)
    {bang?, ds_opts} = Keyword.pop(opts, :bang, false)

    result =
      case {kind, bang?} do
        {:select, false} ->
          DataService.select_query(target, payload_or_action, ds_opts)

        {:select, true} ->
          capture_bang(fn -> DataService.select_query!(target, payload_or_action, ds_opts) end)

        {:insert, false} ->
          DataService.insert_query(target, payload_or_action, ds_opts)

        {:insert, true} ->
          capture_bang(fn -> DataService.insert_query!(target, payload_or_action, ds_opts) end)

        {:update, false} ->
          DataService.update_query(target, payload_or_action, ds_opts)

        {:update, true} ->
          capture_bang(fn -> DataService.update_query!(target, payload_or_action, ds_opts) end)

        {:delete, false} ->
          DataService.delete_query(target, payload_or_action, ds_opts)

        {:delete, true} ->
          capture_bang(fn -> DataService.delete_query!(target, payload_or_action, ds_opts) end)

        {:batch, false} ->
          DataService.batch_query(target, payload_or_action, ds_opts)

        {:batch, true} ->
          capture_bang(fn -> DataService.batch_query!(target, payload_or_action, ds_opts) end)

        {{:execute, action}, false} ->
          DataService.execute_query(target, action, payload_or_action, ds_opts)

        {{:execute, action}, true} ->
          capture_bang(fn ->
            DataService.execute_query!(target, action, payload_or_action, ds_opts)
          end)
      end

    Map.put(ctx, :result, result)
  end

  def custom_service(ctx, service_name, endpoint, payload_or_opts \\ %{}, opts \\ []) do
    target = current_target(ctx)

    result =
      if opts == [] and is_list(payload_or_opts) and payload_or_opts != [] and
           Keyword.keyword?(payload_or_opts) do
        {bang?, clean_opts} = Keyword.pop(payload_or_opts, :bang, false)

        if bang? do
          capture_bang(fn ->
            DataService.custom_service!(target, service_name, endpoint, clean_opts)
          end)
        else
          DataService.custom_service(target, service_name, endpoint, clean_opts)
        end
      else
        {bang?, clean_opts} = Keyword.pop(opts, :bang, false)

        if bang? do
          capture_bang(fn ->
            if clean_opts == [] do
              DataService.custom_service!(target, service_name, endpoint, payload_or_opts)
            else
              DataService.custom_service!(
                target,
                service_name,
                endpoint,
                payload_or_opts,
                clean_opts
              )
            end
          end)
        else
          DataService.custom_service(target, service_name, endpoint, payload_or_opts, clean_opts)
        end
      end

    Map.put(ctx, :result, result)
  end

  # ---------------------------------------------------------------------------
  # Cross-Cutting Safety, Resilience & Facade Execution
  # ---------------------------------------------------------------------------

  @doc """
  Executes a domain-named SDK operation from safety, resilience, or facade matrices.
  """
  def invoke_operation(ctx, op) do
    client = current_client(ctx)

    result =
      case op do
        {:odata_create, entity, attrs} ->
          OData.create(client, entity, attrs)

        {:odata_update, entity, id, attrs} ->
          OData.update(client, entity, id, attrs)

        {:odata_delete, entity, id} ->
          OData.delete(client, entity, id)

        {:odata_update_field, entity, id, field, val} ->
          OData.update_field(client, entity, id, field, val)

        {:odata_delete_field, entity, id, field} ->
          OData.delete_field(client, entity, id, field)

        {:odata_list, entity} ->
          OData.list(client, entity)

        {:odata_list_opts, entity, opts} ->
          OData.list(client, entity, opts)

        {:odata_execute, entity} ->
          OData.execute(client, entity)

        {:odata_get, entity, id} ->
          OData.get(client, entity, id)

        {:odata_count, entity} ->
          OData.count(client, entity)

        {:odata_get_navigation, entity, id, nav} ->
          OData.get_navigation(client, entity, id, nav)

        {:odata_get_field, entity, id, field} ->
          OData.get_field(client, entity, id, field)

        {:odata_get_field_value, entity, id, field} ->
          OData.get_field_value(client, entity, id, field)

        {:odata3_create, entity, attrs} ->
          OData3.create(client, entity, attrs)

        {:odata3_update, entity, id, attrs} ->
          OData3.update(client, entity, id, attrs)

        {:odata3_delete, entity, id} ->
          OData3.delete(client, entity, id)

        {:odata3_list, entity} ->
          OData3.list(client, entity)

        {:odata3_list_opts, entity, opts} ->
          OData3.list(client, entity, opts)

        {:odata3_get, entity, id} ->
          OData3.get(client, entity, id)

        {:odata3_count, entity} ->
          OData3.count(client, entity)

        {:odata3_get_navigation, entity, id, nav} ->
          OData3.get_navigation(client, entity, id, nav)

        {:odata3_get_field, entity, id, field} ->
          OData3.get_field(client, entity, id, field)

        {:odata3_get_field_value, entity, id, field} ->
          OData3.get_field_value(client, entity, id, field)

        {:data_service_select, payload} ->
          DataService.select_query(client, payload)

        {:data_service_insert, payload} ->
          DataService.insert_query(client, payload)

        {:data_service_update, payload} ->
          DataService.update_query(client, payload)

        {:data_service_delete, payload} ->
          DataService.delete_query(client, payload)

        {:data_service_batch, payload} ->
          DataService.batch_query(client, payload)

        {:custom_service, svc, endpoint} ->
          DataService.custom_service(client, svc, endpoint)

        {:custom_service, svc, endpoint, payload, opts} ->
          DataService.custom_service(client, svc, endpoint, payload, opts)

        {:custom_service_opts, svc, endpoint, opts} ->
          DataService.custom_service(client, svc, endpoint, opts)

        {:batch_mutation, entity, attrs} ->
          batch = Batch.new() |> Batch.add_create(entity, attrs)
          Batch.execute(client, batch)

        {:batch_get_only, entity} ->
          batch = Batch.new() |> Batch.add_get(entity)
          Batch.execute(client, batch)

        {:batch_empty_json} ->
          Batch.execute(client, Batch.new())

        {:batch_empty_multipart} ->
          Batch.execute(client, Batch.new(), format: :multipart)

        {:batch_binary, raw_body} ->
          Batch.execute(client, raw_body)

        {:facade_batch_empty} ->
          Creatio.batch(client, [])

        {:facade_batch_empty!} ->
          capture_bang(fn -> Creatio.batch!(client, []) end)

        {:facade_login, user, pass} ->
          Creatio.login(client, user, pass)

        {:facade_login_oauth} ->
          Creatio.login_oauth(client)

        {:facade_oauth_health_check} ->
          Creatio.oauth_health_check(client)

        {:facade_openid_configuration_client} ->
          req_opts = CreatioServerDriver.req_options_for_server(ctx)
          Creatio.openid_configuration(client, req_options: req_opts)

        {:facade_openid_configuration_url, url} ->
          req_opts = CreatioServerDriver.req_options_for_server(ctx)
          Creatio.openid_configuration(url, req_options: req_opts)

        {:facade_stream!, entity} ->
          capture_bang(fn -> Creatio.stream(client, entity) |> Enum.to_list() end)

        {:bang_odata_list, entity} ->
          capture_bang(fn -> OData.list!(client, entity) end)

        {:bang_odata_list_query_first, entity} ->
          capture_bang(fn -> OData.list!(Query.new(entity), client, []) end)

        {:bang_odata_get, entity, id} ->
          capture_bang(fn -> OData.get!(client, entity, id) end)

        {:bang_odata_get_navigation, entity, id, nav} ->
          capture_bang(fn -> OData.get_navigation!(client, entity, id, nav) end)

        {:bang_odata_get_field, entity, id, field} ->
          capture_bang(fn -> OData.get_field!(client, entity, id, field) end)

        {:bang_odata_count, entity} ->
          capture_bang(fn -> OData.count!(client, entity) end)

        {:bang_odata_create, entity, attrs} ->
          capture_bang(fn -> OData.create!(client, entity, attrs) end)

        {:bang_odata_update, entity, id, attrs} ->
          capture_bang(fn -> OData.update!(client, entity, id, attrs) end)

        {:bang_odata_delete, entity, id} ->
          capture_bang(fn -> OData.delete!(client, entity, id) end)

        {:bang_odata_execute, entity} ->
          capture_bang(fn -> OData.execute!(client, entity) end)

        {:bang_odata_get_field_value, entity, id, field} ->
          capture_bang(fn -> OData.get_field_value!(client, entity, id, field) end)

        {:bang_odata_update_field, entity, id, field, val} ->
          capture_bang(fn -> OData.update_field!(client, entity, id, field, val) end)

        {:bang_odata_delete_field, entity, id, field} ->
          capture_bang(fn -> OData.delete_field!(client, entity, id, field) end)

        {:odata_count_top_zero, entity} ->
          OData.count(client, entity, strategy: :top_zero)

        {:bang_odata_stream_query_first, entity} ->
          capture_bang(fn -> OData.stream(Query.new(entity), client, []) |> Enum.to_list() end)

        {:bang_odata3_list, entity} ->
          capture_bang(fn -> OData3.list!(client, entity) end)

        {:bang_odata3_list_query_first, entity} ->
          capture_bang(fn -> OData3.list!(Query.new(entity), client, []) end)

        {:bang_odata3_get, entity, id} ->
          capture_bang(fn -> OData3.get!(client, entity, id) end)

        {:bang_odata3_count, entity} ->
          capture_bang(fn -> OData3.count!(client, entity) end)

        {:bang_odata3_create, entity, attrs} ->
          capture_bang(fn -> OData3.create!(client, entity, attrs) end)

        {:bang_odata3_update, entity, id, attrs} ->
          capture_bang(fn -> OData3.update!(client, entity, id, attrs) end)

        {:bang_odata3_delete, entity, id} ->
          capture_bang(fn -> OData3.delete!(client, entity, id) end)

        {:bang_odata3_stream, entity} ->
          capture_bang(fn -> OData3.stream(Query.new(entity), client, []) |> Enum.to_list() end)

        {:bang_odata3_stream!, entity} ->
          capture_bang(fn -> OData3.stream!(Query.new(entity), client, []) |> Enum.to_list() end)

        {:bang_odata3_get_navigation, entity, id, nav} ->
          capture_bang(fn -> OData3.get_navigation!(client, entity, id, nav) end)

        {:bang_odata3_get_field, entity, id, field} ->
          capture_bang(fn -> OData3.get_field!(client, entity, id, field) end)

        {:bang_odata3_get_field_value, entity, id, field} ->
          capture_bang(fn -> OData3.get_field_value!(client, entity, id, field) end)

        {:data_service_execute, action, payload} ->
          DataService.execute_query(client, action, payload)

        {:bang_data_service_select, payload} ->
          capture_bang(fn -> DataService.select_query!(client, payload) end)

        {:bang_data_service_insert, payload} ->
          capture_bang(fn -> DataService.insert_query!(client, payload) end)

        {:bang_data_service_update, payload} ->
          capture_bang(fn -> DataService.update_query!(client, payload) end)

        {:bang_data_service_delete, payload} ->
          capture_bang(fn -> DataService.delete_query!(client, payload) end)

        {:bang_data_service_batch, payload} ->
          capture_bang(fn -> DataService.batch_query!(client, payload) end)

        {:bang_data_service_execute, action, payload} ->
          capture_bang(fn -> DataService.execute_query!(client, action, payload) end)

        {:bang_custom_service_4, svc, endpoint, opts} ->
          capture_bang(fn -> DataService.custom_service!(client, svc, endpoint, opts) end)

        {:bang_custom_service_5, svc, endpoint, payload, opts} ->
          capture_bang(fn ->
            DataService.custom_service!(client, svc, endpoint, payload, opts)
          end)

        {:auth_login_forms, user, pass} ->
          Auth.login_forms(client, user, pass)

        {:auth_login_oauth, opts} ->
          oauth_client =
            CreatioServerDriver.client(ctx,
              client_id: "c",
              client_secret: "s",
              identity_service_url: "https://mycreatio.com"
            )

          Auth.login_oauth(oauth_client, opts)

        {:auth_oauth_health_check} ->
          Auth.oauth_health_check(client)

        {:auth_openid_configuration, opts} ->
          req_opts = CreatioServerDriver.req_options_for_server(ctx)
          Auth.openid_configuration(client, Keyword.merge([req_options: req_opts], opts))

        {:raw_req, :get, path} ->
          Req.get(client.req, url: path)

        {:raw_req, :post, path} ->
          Req.post(client.req, url: path)
      end

    Map.put(ctx, :result, result)
  end
end
