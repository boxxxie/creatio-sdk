defmodule Creatio.TestDrivers.CRMClientDriver do
  @moduledoc """
  Layer 3 Protocol Driver invoking `Creatio` SDK modules and capturing results in `ctx`.

  Keeps direct SDK module calls, Req client wrapping, and bang exception capture
  encapsulated below Layer 2 DSLs.
  """

  alias Creatio.{Auth, Batch, Client, DataService, Error, OData, OData3}
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
    {facade?, login_opts} = pop_driver_opt(opts, :facade, false)
    {with_server_req?, login_opts} = pop_driver_opt(login_opts, :with_server_req_options, false)

    login_opts =
      if with_server_req? do
        Keyword.put_new(login_opts, :req_options, CreatioServerDriver.req_options_for_server(ctx))
      else
        login_opts
      end

    result =
      if facade? do
        Creatio.login(target, username, password, login_opts)
      else
        Auth.login_forms(target, username, password, login_opts)
      end

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
    {with_server_req?, health_opts} = pop_driver_opt(opts, :with_server_req_options, false)

    health_opts =
      if with_server_req? do
        Keyword.put_new(
          health_opts,
          :req_options,
          CreatioServerDriver.req_options_for_server(ctx)
        )
      else
        health_opts
      end

    Map.put(ctx, :result, Auth.oauth_health_check(client, health_opts))
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
          Auth.openid_configuration(client, driver_opts)
      end

    Map.put(ctx, :result, result)
  end

  # ---------------------------------------------------------------------------
  # OData 4 Operations
  # ---------------------------------------------------------------------------

  def odata_list(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, list_opts} = pop_driver_opt(opts, :bang, false)
    {query_first?, list_opts} = pop_driver_opt(list_opts, :query_first, false)
    {facade?, list_opts} = pop_driver_opt(list_opts, :facade, false)

    result =
      cond do
        facade? and bang? and query_first? ->
          capture_bang(fn -> Creatio.list!(entity_or_query, target, list_opts) end)

        facade? and bang? ->
          capture_bang(fn -> Creatio.list!(target, entity_or_query, list_opts) end)

        facade? and query_first? ->
          Creatio.list(entity_or_query, target, list_opts)

        facade? ->
          Creatio.list(target, entity_or_query, list_opts)

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
    {bang?, exec_opts} = pop_driver_opt(opts, :bang, false)
    {query_first?, exec_opts} = pop_driver_opt(exec_opts, :query_first, false)

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
    {bang?, get_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, get_opts} = pop_driver_opt(get_opts, :facade, false)

    result =
      cond do
        facade? and bang? -> capture_bang(fn -> Creatio.get!(target, entity, id, get_opts) end)
        facade? -> Creatio.get(target, entity, id, get_opts)
        bang? -> capture_bang(fn -> OData.get!(target, entity, id, get_opts) end)
        true -> OData.get(target, entity, id, get_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_get_navigation(ctx, entity, id, nav, opts \\ []) do
    target = current_target(ctx)
    {bang?, nav_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, field_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, field_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, field_opts} = pop_driver_opt(field_opts, :facade, false)

    result =
      cond do
        facade? and bang? ->
          capture_bang(fn -> Creatio.get_field_value!(target, entity, id, field, field_opts) end)

        facade? ->
          Creatio.get_field_value(target, entity, id, field, field_opts)

        bang? ->
          capture_bang(fn -> OData.get_field_value!(target, entity, id, field, field_opts) end)

        true ->
          OData.get_field_value(target, entity, id, field, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_count(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, count_opts} = pop_driver_opt(opts, :bang, false)
    {query_first?, count_opts} = pop_driver_opt(count_opts, :query_first, false)
    {facade?, count_opts} = pop_driver_opt(count_opts, :facade, false)

    result =
      cond do
        facade? and bang? and query_first? ->
          capture_bang(fn -> Creatio.count!(entity_or_query, target, count_opts) end)

        facade? and bang? ->
          capture_bang(fn -> Creatio.count!(target, entity_or_query, count_opts) end)

        facade? and query_first? ->
          Creatio.count(entity_or_query, target, count_opts)

        facade? ->
          Creatio.count(target, entity_or_query, count_opts)

        bang? and query_first? ->
          capture_bang(fn -> OData.count!(entity_or_query, target, count_opts) end)

        bang? ->
          capture_bang(fn -> OData.count!(target, entity_or_query, count_opts) end)

        query_first? ->
          OData.count(entity_or_query, target, count_opts)

        true ->
          OData.count(target, entity_or_query, count_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_create(ctx, entity, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, create_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, create_opts} = pop_driver_opt(create_opts, :facade, false)

    result =
      cond do
        facade? and bang? ->
          capture_bang(fn -> Creatio.create!(target, entity, attrs, create_opts) end)

        facade? ->
          Creatio.create(target, entity, attrs, create_opts)

        bang? ->
          capture_bang(fn -> OData.create!(target, entity, attrs, create_opts) end)

        true ->
          OData.create(target, entity, attrs, create_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_update(ctx, entity, id, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, update_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, update_opts} = pop_driver_opt(update_opts, :facade, false)

    result =
      cond do
        facade? and bang? ->
          capture_bang(fn -> Creatio.update!(target, entity, id, attrs, update_opts) end)

        facade? ->
          Creatio.update(target, entity, id, attrs, update_opts)

        bang? ->
          capture_bang(fn -> OData.update!(target, entity, id, attrs, update_opts) end)

        true ->
          OData.update(target, entity, id, attrs, update_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata_delete(ctx, entity, id, opts \\ []) do
    target = current_target(ctx)
    {bang?, delete_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, delete_opts} = pop_driver_opt(delete_opts, :facade, false)

    result =
      cond do
        facade? and bang? ->
          capture_bang(fn -> Creatio.delete!(target, entity, id, delete_opts) end)

        facade? ->
          Creatio.delete(target, entity, id, delete_opts)

        bang? ->
          capture_bang(fn -> OData.delete!(target, entity, id, delete_opts) end)

        true ->
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
    {take_n, stream_opts} = pop_driver_opt(opts, :take)
    {bang?, stream_opts} = pop_driver_opt(stream_opts, :bang, false)
    {query_first?, stream_opts} = pop_driver_opt(stream_opts, :query_first, false)
    {facade?, stream_opts} = pop_driver_opt(stream_opts, :facade, false)

    result =
      capture_bang(fn ->
        stream =
          cond do
            facade? and bang? and query_first? ->
              Creatio.stream!(entity_or_query, target, stream_opts)

            facade? and bang? ->
              Creatio.stream!(target, entity_or_query, stream_opts)

            facade? and query_first? ->
              Creatio.stream(entity_or_query, target, stream_opts)

            facade? ->
              Creatio.stream(target, entity_or_query, stream_opts)

            bang? and query_first? ->
              OData.stream!(entity_or_query, target, stream_opts)

            bang? ->
              OData.stream!(target, entity_or_query, stream_opts)

            query_first? ->
              OData.stream(entity_or_query, target, stream_opts)

            true ->
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
    {bang?, list_opts} = pop_driver_opt(opts, :bang, false)
    {query_first?, list_opts} = pop_driver_opt(list_opts, :query_first, false)

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
    {bang?, get_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, nav_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, field_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, field_opts} = pop_driver_opt(opts, :bang, false)
    {facade?, field_opts} = pop_driver_opt(field_opts, :facade, false)

    result =
      cond do
        facade? and bang? ->
          capture_bang(fn ->
            Creatio.odata3_get_field_value!(target, entity, id, field, field_opts)
          end)

        facade? ->
          Creatio.odata3_get_field_value(target, entity, id, field, field_opts)

        bang? ->
          capture_bang(fn -> OData3.get_field_value!(target, entity, id, field, field_opts) end)

        true ->
          OData3.get_field_value(target, entity, id, field, field_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_count(ctx, entity_or_query, opts \\ []) do
    target = current_target(ctx)
    {bang?, count_opts} = pop_driver_opt(opts, :bang, false)
    {query_first?, count_opts} = pop_driver_opt(count_opts, :query_first, false)
    {facade?, count_opts} = pop_driver_opt(count_opts, :facade, false)

    result =
      cond do
        facade? and bang? and query_first? ->
          capture_bang(fn -> Creatio.odata3_count!(entity_or_query, target, count_opts) end)

        facade? and bang? ->
          capture_bang(fn -> Creatio.odata3_count!(target, entity_or_query, count_opts) end)

        facade? and query_first? ->
          Creatio.odata3_count(entity_or_query, target, count_opts)

        facade? ->
          Creatio.odata3_count(target, entity_or_query, count_opts)

        bang? and query_first? ->
          capture_bang(fn -> OData3.count!(entity_or_query, target, count_opts) end)

        bang? ->
          capture_bang(fn -> OData3.count!(target, entity_or_query, count_opts) end)

        query_first? ->
          OData3.count(entity_or_query, target, count_opts)

        true ->
          OData3.count(target, entity_or_query, count_opts)
      end

    Map.put(ctx, :result, result)
  end

  def odata3_create(ctx, entity, attrs, opts \\ []) do
    target = current_target(ctx)
    {bang?, create_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, update_opts} = pop_driver_opt(opts, :bang, false)

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
    {bang?, delete_opts} = pop_driver_opt(opts, :bang, false)

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
    {take_n, stream_opts} = pop_driver_opt(opts, :take)
    {bang?, stream_opts} = pop_driver_opt(stream_opts, :bang, false)
    {query_first?, stream_opts} = pop_driver_opt(stream_opts, :query_first, false)
    {facade?, stream_opts} = pop_driver_opt(stream_opts, :facade, false)

    result =
      capture_bang(fn ->
        stream =
          cond do
            facade? and bang? and query_first? ->
              Creatio.odata3_stream!(entity_or_query, target, stream_opts)

            facade? and bang? ->
              Creatio.odata3_stream!(target, entity_or_query, stream_opts)

            facade? and query_first? ->
              Creatio.odata3_stream(entity_or_query, target, stream_opts)

            facade? ->
              Creatio.odata3_stream(target, entity_or_query, stream_opts)

            bang? and query_first? ->
              OData3.stream!(entity_or_query, target, stream_opts)

            bang? ->
              OData3.stream!(target, entity_or_query, stream_opts)

            query_first? ->
              OData3.stream(entity_or_query, target, stream_opts)

            true ->
              OData3.stream(target, entity_or_query, stream_opts)
          end

        if is_integer(take_n), do: Enum.take(stream, take_n), else: Enum.to_list(stream)
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
  # Read-Only Safety & Transport Execution
  # ---------------------------------------------------------------------------

  @doc """
  Executes a domain-named SDK operation from read-only safety matrices.
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

        {:odata3_create, entity, attrs} ->
          OData3.create(client, entity, attrs)

        {:odata3_update, entity, id, attrs} ->
          OData3.update(client, entity, id, attrs)

        {:odata3_delete, entity, id} ->
          OData3.delete(client, entity, id)

        {:data_service_insert, payload} ->
          DataService.insert_query(client, payload)

        {:data_service_update, payload} ->
          DataService.update_query(client, payload)

        {:data_service_delete, payload} ->
          DataService.delete_query(client, payload)

        {:data_service_batch, payload} ->
          DataService.batch_query(client, payload)

        {:data_service_execute, action, payload} ->
          DataService.execute_query(client, action, payload)

        {:data_service_select_opts, payload, opts} ->
          DataService.select_query(client, payload, opts)

        {:data_service_execute_opts, action, payload, opts} ->
          DataService.execute_query(client, action, payload, opts)

        {:custom_service, svc, endpoint, payload, opts} ->
          DataService.custom_service(client, svc, endpoint, payload, opts)

        {:custom_service_opts, svc, endpoint, opts} ->
          DataService.custom_service(client, svc, endpoint, opts)

        {:batch_mutation, entity, attrs} ->
          batch = Batch.new() |> Batch.add_create(entity, attrs)
          Batch.execute(client, batch)

        {:batch_list_mutation, ops} ->
          Batch.execute(client, ops)

        {:batch_get_only, entity} ->
          batch = Batch.new() |> Batch.add_get(entity)
          Batch.execute(client, batch)

        {:batch_binary, raw_body} ->
          Batch.execute(client, raw_body)

        {:raw_req, method, path} ->
          Req.request(client.req, method: method, url: path)
      end

    Map.put(ctx, :result, result)
  end

  defp pop_driver_opt(opts, key, default \\ nil)
  defp pop_driver_opt(opts, key, default) when is_list(opts), do: Keyword.pop(opts, key, default)
  defp pop_driver_opt(opts, key, default) when is_map(opts), do: Map.pop(opts, key, default)
end
