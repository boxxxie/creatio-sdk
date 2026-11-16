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

  def temp_file_path(ctx, key, ext \\ "bin") do
    path =
      Path.join(
        System.tmp_dir!(),
        "creatio_sdk_#{key}_#{System.unique_integer([:positive])}.#{ext}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    paths = Map.get(ctx, :temp_paths, %{})
    Map.put(ctx, :temp_paths, Map.put(paths, key, path))
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

  def odata_pages(ctx, entity, pages_or_fun) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata_pages(entity, pages_or_fun)
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

  def odata3_pages(ctx, entity, pages_or_fun) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_odata3_pages(entity, pages_or_fun)
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

  def counting_entities_matrix(ctx, entity, cases) when is_list(cases) do
    {final_ctx, results} =
      Enum.reduce(cases, {ctx, []}, fn {desc, stub_opts, call_opts, expected}, {acc_ctx, acc} ->
        stubbed = CreatioServerDriver.stub_odata_count(acc_ctx, entity, stub_opts)
        called = CRMClientDriver.odata_count(stubbed, entity, call_opts)
        {called, acc ++ [{desc, expected, Map.fetch!(called, :result)}]}
      end)

    Map.put(final_ctx, :matrix_results, results)
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

  def updating_entity_field_with_stream(ctx, entity, id, field, chunks, opts \\ []) do
    stream = Stream.map(chunks, & &1)
    CRMClientDriver.odata_update_field(ctx, entity, id, field, stream, opts)
  end

  def updating_entity_field_with_io_stream(
        ctx,
        entity,
        id,
        field,
        content,
        chunk_size \\ 6,
        opts \\ []
      ) do
    {:ok, io_dev} = StringIO.open(content)

    try do
      io_stream = IO.binstream(io_dev, chunk_size)
      CRMClientDriver.odata_update_field(ctx, entity, id, field, io_stream, opts)
    after
      if Process.alive?(io_dev), do: StringIO.close(io_dev)
    end
  end

  def getting_raw_field_value_to_temp_file(ctx, key, entity, id, field, opts \\ []) do
    path = ctx |> Map.fetch!(:temp_paths) |> Map.fetch!(key)
    CRMClientDriver.odata_get_field_value(ctx, entity, id, field, put_into_opt(opts, path))
  end

  def getting_odata3_raw_field_value_to_temp_file(ctx, key, entity, id, field, opts \\ []) do
    path = ctx |> Map.fetch!(:temp_paths) |> Map.fetch!(key)
    CRMClientDriver.odata3_get_field_value(ctx, entity, id, field, put_into_opt(opts, path))
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

  def counting_odata3_entities_matrix(ctx, entity, cases) when is_list(cases) do
    {final_ctx, results} =
      Enum.reduce(cases, {ctx, []}, fn {desc, stub_opts, call_opts, expected}, {acc_ctx, acc} ->
        stubbed = CreatioServerDriver.stub_odata3_count(acc_ctx, entity, stub_opts)
        called = CRMClientDriver.odata3_count(stubbed, entity, call_opts)
        {called, acc ++ [{desc, expected, Map.fetch!(called, :result)}]}
      end)

    Map.put(final_ctx, :matrix_results, results)
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

      if Keyword.has_key?(expected, :message_contains) do
        assert String.contains?(err.message, Keyword.fetch!(expected, :message_contains))
      end

      if Keyword.has_key?(expected, :response_status) do
        assert %Req.Response{status: actual_status} = err.response
        assert actual_status == Keyword.fetch!(expected, :response_status)
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

  defmacro all_count_cases_matched(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      results = Map.fetch!(ctx, :matrix_results)
      assert results != []

      Enum.each(results, fn {desc, expected, actual} ->
        assert {:ok, expected} == actual,
               "Count mismatch for #{desc}: expected {:ok, #{inspect(expected)}}, got #{inspect(actual)}"
      end)

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

      assert last_req.headers["content-type"] == [
               "application/json; IEEE754Compatible=true"
             ]

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

      assert last_req.headers["accept"] == ["application/json, text/plain, */*"]

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

  defmacro temp_file_written(ctx, key, expected_bytes) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      path = ctx |> Map.fetch!(:temp_paths) |> Map.fetch!(unquote(key))
      assert {:ok, %File.Stream{}} = Map.fetch!(ctx, :result)
      assert File.read!(path) == unquote(expected_bytes)
      ctx
    end
  end

  defmacro temp_file_not_created(ctx, key) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      path = ctx |> Map.fetch!(:temp_paths) |> Map.fetch!(unquote(key))
      refute File.exists?(path)
      ctx
    end
  end

  defmacro entity_created_missing_key(ctx, key) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, created} = Map.fetch!(ctx, :result)
      refute Map.has_key?(created, unquote(key))
      ctx
    end
  end

  defmacro server_request_count_was(ctx, expected_count) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert length(CreatioServerDriver.recorded_requests(ctx)) == unquote(expected_count)
      ctx
    end
  end

  defmacro last_request_header_was(ctx, header_name, expected_value) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      key = String.downcase(to_string(unquote(header_name)))
      assert last_req.headers[key] == [unquote(expected_value)]
      ctx
    end
  end

  defmacro last_request_omitted_query_param(ctx, param_name) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      refute Map.has_key?(last_req.query_params, unquote(param_name))
      ctx
    end
  end

  defmacro last_request_query_param_contains(ctx, param_name, snippet) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      assert String.contains?(last_req.query_params[unquote(param_name)] || "", unquote(snippet))
      ctx
    end
  end

  defmacro last_request_query_param_omits(ctx, param_name, snippet) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      refute String.contains?(last_req.query_params[unquote(param_name)] || "", unquote(snippet))
      ctx
    end
  end

  defmacro last_request_query_string_was(ctx, expected_qs) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.query_string == unquote(expected_qs)
      ctx
    end
  end

  defmacro stream_error_returned(ctx, expected_prefix, opts \\ []) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      prefix = Enum.map(unquote(expected_prefix), &{:ok, &1})
      expected = unquote(opts)

      assert {:ok, items} = Map.fetch!(ctx, :result)
      assert {actual_prefix, [{:error, %Error{} = err}]} = Enum.split(items, length(prefix))
      assert actual_prefix == prefix

      if Keyword.has_key?(expected, :status) do
        assert err.status == Keyword.fetch!(expected, :status)
      end

      if Keyword.has_key?(expected, :message_contains) do
        assert String.contains?(err.message, Keyword.fetch!(expected, :message_contains))
      end

      ctx
    end
  end

  defp put_into_opt(opts, path) when is_map(opts), do: Map.put(opts, :into, File.stream!(path))

  defp put_into_opt(opts, path) when is_list(opts),
    do: Keyword.put(opts, :into, File.stream!(path))
end
