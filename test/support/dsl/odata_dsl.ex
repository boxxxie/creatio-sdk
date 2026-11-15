defmodule Creatio.TestDSL.ODataDSL do
  @moduledoc """
  Layer 2 DSL for Creatio OData 4 and legacy OData 3 entity operations.
  """

  alias Creatio.Error
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

  # ---------------------------------------------------------------------------
  # @given steps (OData 4)
  # ---------------------------------------------------------------------------

  def raw_http_client(ctx) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> then(fn c -> Map.put(c, :raw_req, CreatioServerDriver.req(c)) end)
  end

  def odata_collection(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_list(entity, opts)
  end

  def odata_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_get(entity, id, opts)
  end

  def odata_missing_entity(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 404)
    message = Keyword.get(opts, :message, "Entity not found")
    code = Keyword.get(opts, :code, "404")

    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_get(entity, id,
      status: status,
      body: %{"error" => %{"message" => message, "code" => code}}
    )
  end

  def odata_navigation(ctx, entity, id, nav, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_navigation(entity, id, nav, opts)
  end

  def odata_field(ctx, entity, id, field, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_field(entity, id, field, opts)
  end

  def odata_count_endpoint(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_count(entity, opts)
  end

  def odata_creatable_entity(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_create(entity, opts)
  end

  def odata_updatable_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_update(entity, id, opts)
  end

  def odata_deletable_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_delete(entity, id, opts)
  end

  def odata_updatable_field(ctx, entity, id, field, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_update_field(entity, id, field, opts)
  end

  def odata_deletable_field(ctx, entity, id, field, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_delete_field(entity, id, field, opts)
  end

  def odata_paginated_collection(ctx, entity, records) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_stream(entity, records)
  end

  # ---------------------------------------------------------------------------
  # @given steps (OData 3)
  # ---------------------------------------------------------------------------

  def odata3_collection(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_list(entity, opts)
  end

  def odata3_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_get(entity, id, opts)
  end

  def odata3_navigation(ctx, entity, id, nav, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_navigation(entity, id, nav, opts)
  end

  def odata3_field(ctx, entity, id, field, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_field(entity, id, field, opts)
  end

  def odata3_count_endpoint(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_count(entity, opts)
  end

  def odata3_creatable_entity(ctx, entity, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_create(entity, opts)
  end

  def odata3_updatable_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_update(entity, id, opts)
  end

  def odata3_deletable_entity(ctx, entity, id, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_delete(entity, id, opts)
  end

  def odata3_paginated_collection(ctx, entity, records) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_stream(entity, records)
  end

  # ---------------------------------------------------------------------------
  # @upon steps (OData 4)
  # ---------------------------------------------------------------------------

  def listing_entities(ctx, entity_or_query, opts \\ []) do
    CRMClientDriver.odata_list(ctx, entity_or_query, opts)
  end

  def executing_query(ctx, entity_or_query, opts \\ []) do
    CRMClientDriver.odata_execute(ctx, entity_or_query, opts)
  end

  def getting_entity(ctx, entity, id, opts \\ []) do
    CRMClientDriver.odata_get(ctx, entity, id, opts)
  end

  def getting_navigation(ctx, entity, id, nav, opts \\ []) do
    CRMClientDriver.odata_get_navigation(ctx, entity, id, nav, opts)
  end

  def getting_field(ctx, entity, id, field, opts \\ []) do
    CRMClientDriver.odata_get_field(ctx, entity, id, field, opts)
  end

  def getting_raw_field_value(ctx, entity, id, field, opts \\ []) do
    CRMClientDriver.odata_get_field_value(ctx, entity, id, field, opts)
  end

  def counting_entities(ctx, entity, opts \\ []) do
    CRMClientDriver.odata_count(ctx, entity, opts)
  end

  def creating_entity(ctx, entity, attrs, opts \\ []) do
    CRMClientDriver.odata_create(ctx, entity, attrs, opts)
  end

  def updating_entity(ctx, entity, id, attrs, opts \\ []) do
    CRMClientDriver.odata_update(ctx, entity, id, attrs, opts)
  end

  def deleting_entity(ctx, entity, id, opts \\ []) do
    CRMClientDriver.odata_delete(ctx, entity, id, opts)
  end

  def updating_entity_field(ctx, entity, id, field, value, opts \\ []) do
    CRMClientDriver.odata_update_field(ctx, entity, id, field, value, opts)
  end

  def deleting_entity_field(ctx, entity, id, field, opts \\ []) do
    CRMClientDriver.odata_delete_field(ctx, entity, id, field, opts)
  end

  def streaming_entities(ctx, entity_or_query, opts \\ []) do
    CRMClientDriver.odata_stream(ctx, entity_or_query, opts)
  end

  # ---------------------------------------------------------------------------
  # @upon steps (OData 3)
  # ---------------------------------------------------------------------------

  def listing_odata3_entities(ctx, entity_or_query, opts \\ []) do
    CRMClientDriver.odata3_list(ctx, entity_or_query, opts)
  end

  def getting_odata3_entity(ctx, entity, id, opts \\ []) do
    CRMClientDriver.odata3_get(ctx, entity, id, opts)
  end

  def getting_odata3_navigation(ctx, entity, id, nav, opts \\ []) do
    CRMClientDriver.odata3_get_navigation(ctx, entity, id, nav, opts)
  end

  def getting_odata3_field(ctx, entity, id, field, opts \\ []) do
    CRMClientDriver.odata3_get_field(ctx, entity, id, field, opts)
  end

  def getting_odata3_raw_field_value(ctx, entity, id, field, opts \\ []) do
    CRMClientDriver.odata3_get_field_value(ctx, entity, id, field, opts)
  end

  def counting_odata3_entities(ctx, entity, opts \\ []) do
    CRMClientDriver.odata3_count(ctx, entity, opts)
  end

  def creating_odata3_entity(ctx, entity, attrs, opts \\ []) do
    CRMClientDriver.odata3_create(ctx, entity, attrs, opts)
  end

  def updating_odata3_entity(ctx, entity, id, attrs, opts \\ []) do
    CRMClientDriver.odata3_update(ctx, entity, id, attrs, opts)
  end

  def deleting_odata3_entity(ctx, entity, id, opts \\ []) do
    CRMClientDriver.odata3_delete(ctx, entity, id, opts)
  end

  def streaming_odata3_entities(ctx, entity_or_query, opts \\ []) do
    CRMClientDriver.odata3_stream(ctx, entity_or_query, opts)
  end

  # ---------------------------------------------------------------------------
  # @then assertions (caller-line attributed)
  # ---------------------------------------------------------------------------

  defmacro entities_returned(ctx, expected_records) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_records)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro counted_entities_returned(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:ok, result} = Map.fetch!(ctx, :result)
      assert result.count == Keyword.fetch!(expected, :count)
      assert result.records == Keyword.fetch!(expected, :records)
      ctx
    end
  end

  defmacro query_parameters_mapped(ctx, expected_opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(expected_opts)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.method == "GET"

      Enum.each(expected, fn
        {:select, val} -> assert last_req.query_params["$select"] == val
        {:filter, val} -> assert last_req.query_params["$filter"] == val
        {:orderby, val} -> assert last_req.query_params["$orderby"] == val
        {:top, val} -> assert last_req.query_params["$top"] == to_string(val)
        {:skip, val} -> assert last_req.query_params["$skip"] == to_string(val)
        {:expand, val} -> assert last_req.query_params["$expand"] == val
        {:count, val} -> assert last_req.query_params["$count"] == to_string(val)
        {:inlinecount, val} -> assert last_req.query_params["$inlinecount"] == val
        {key, val} -> assert last_req.query_params[to_string(key)] == to_string(val)
      end)

      ctx
    end
  end

  defmacro entity_returned(ctx, expected_record) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_record)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro requested_odata_entity_id(ctx, entity, clean_id) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.request_path == "/0/odata/#{unquote(entity)}(#{unquote(clean_id)})"
      ctx
    end
  end

  defmacro operation_failed_with(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:error, %Error{} = err} = Map.fetch!(ctx, :result)

      if Keyword.has_key?(expected, :status) do
        assert err.status == Keyword.fetch!(expected, :status)
      end

      if Keyword.has_key?(expected, :code) do
        assert err.code == Keyword.fetch!(expected, :code)
      end

      if Keyword.has_key?(expected, :message) do
        assert err.message == Keyword.fetch!(expected, :message)
      end

      ctx
    end
  end

  defmacro field_value_returned(ctx, expected_value) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_value)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro count_returned(ctx, expected_count) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_count)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro entity_created_with(ctx, expected_record) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_record)} == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "POST"
      assert last_req.headers["forceusesession"] == ["true"]
      ctx
    end
  end

  defmacro mutation_succeeded(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert :ok == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.headers["forceusesession"] == ["true"]
      ctx
    end
  end

  defmacro bang_mutation_succeeded(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, :ok} == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.headers["forceusesession"] == ["true"]
      ctx
    end
  end

  defmacro binary_field_upload_verified(ctx, entity, id, field, expected_bytes) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert :ok == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "PUT"

      assert last_req.request_path ==
               "/0/odata/#{unquote(entity)}(#{unquote(id)})/#{unquote(field)}"

      assert last_req.headers["content-type"] == [
               "application/octet-stream; IEEE754Compatible=true"
             ]

      assert last_req.raw_body == unquote(expected_bytes)
      ctx
    end
  end

  defmacro scalar_field_update_verified(ctx, entity, id, field, expected_value) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert :ok == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "PUT"

      assert last_req.request_path ==
               "/0/odata/#{unquote(entity)}(#{unquote(id)})/#{unquote(field)}"

      assert last_req.raw_body == Jason.encode!(%{"value" => unquote(expected_value)})
      ctx
    end
  end

  defmacro field_delete_verified(ctx, entity, id, field) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert :ok == Map.fetch!(ctx, :result)

      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.method == "DELETE"

      assert last_req.request_path ==
               "/0/odata/#{unquote(entity)}(#{unquote(id)})/#{unquote(field)}"

      assert last_req.headers["accept"] == ["application/json; text/plain; */*"]

      assert last_req.headers["content-type"] == [
               "application/octet-stream; IEEE754Compatible=true"
             ]

      ctx
    end
  end

  defmacro streamed_entities_match(ctx, expected_records) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_records)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro odata3_verbose_headers_sent(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.headers["accept"] == ["application/json; odata=verbose"]
      assert last_req.headers["forceusesession"] == ["true"]
      ctx
    end
  end

  defmacro requested_odata3_entity_guid(ctx, entity, clean_id) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.request_path ==
               "/0/ServiceModel/EntityDataService.svc/#{unquote(entity)}Collection(guid'#{unquote(clean_id)}')"

      ctx
    end
  end

  defmacro odata3_query_count_strategy_used(ctx, entity) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.request_path ==
               "/0/ServiceModel/EntityDataService.svc/#{unquote(entity)}Collection"

      assert last_req.query_string == "/$count"
      ctx
    end
  end
end
