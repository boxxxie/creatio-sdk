defmodule Creatio.TestDSL.BatchDSL do
  @moduledoc """
  Layer 2 DSL for OData `$batch` execution scenarios (JSON and multipart/mixed).
  """

  alias Creatio.Batch
  alias Creatio.Batch.Response
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

  # ---------------------------------------------------------------------------
  # @given steps
  # ---------------------------------------------------------------------------

  def batch_endpoint_returning_responses(ctx, responses) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_batch(responses: responses)
  end

  def batch_endpoint_returning_multipart(ctx, boundary, body) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_batch(boundary: boundary, multipart_body: body)
  end

  def batch_endpoint_returning_multipart_items(ctx, boundary, items) when is_list(items) do
    parts =
      Enum.map_join(items, "\r\n", fn item ->
        id_header = if Map.get(item, :id), do: "Content-ID: #{item.id}", else: nil
        status = Map.fetch!(item, :status)
        reason = Map.get(item, :reason, "OK")
        body_json = Jason.encode!(Map.get(item, :body, %{}))

        [
          "--#{boundary}",
          "Content-Type: application/http",
          "Content-Transfer-Encoding: binary",
          id_header,
          "",
          "HTTP/1.1 #{status} #{reason}",
          "Content-Type: application/json; odata=verbose",
          "",
          body_json,
          ""
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\r\n")
      end)

    full_body = parts <> "--#{boundary}--\r\n"

    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_batch(boundary: boundary, multipart_body: full_body)
  end

  def batch_endpoint_returning_single_entity(ctx, entity_payload) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_batch(single_entity: entity_payload)
  end

  def batch_endpoint_failing(ctx, status, error_body \\ %{}) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_batch(status: status, single_entity: error_body)
  end

  def raw_batch_requests(ctx, payload) when is_list(payload) or is_map(payload) do
    Map.put(ctx, :batch_payload, payload)
  end

  def new_batch(ctx, opts \\ []) do
    Map.put(ctx, :batch_payload, Batch.new(opts))
  end

  def batch_create_operation(ctx, entity, attrs, opts \\ []) do
    batch = Map.get_lazy(ctx, :batch_payload, fn -> Batch.new() end)
    Map.put(ctx, :batch_payload, Batch.add_create(batch, entity, attrs, opts))
  end

  def batch_get_operation(ctx, entity_or_path, id_or_opts \\ []) do
    batch = Map.get_lazy(ctx, :batch_payload, fn -> Batch.new() end)
    Map.put(ctx, :batch_payload, Batch.add_get(batch, entity_or_path, id_or_opts))
  end

  def batch_delete_operation(ctx, entity, id, opts \\ []) do
    batch = Map.get_lazy(ctx, :batch_payload, fn -> Batch.new() end)
    Map.put(ctx, :batch_payload, Batch.add_delete(batch, entity, id, opts))
  end

  def raw_multipart_batch_payload(ctx, raw_body) when is_binary(raw_body) do
    Map.put(ctx, :batch_payload, raw_body)
  end

  def pre_encoded_multipart_batch(ctx, entity, attrs) do
    {boundary, body} =
      Batch.new()
      |> Batch.add_create(entity, attrs)
      |> Batch.to_multipart()

    ctx
    |> Map.put(:batch_payload, body)
    |> Map.put(:batch_boundary, boundary)
  end

  # ---------------------------------------------------------------------------
  # @upon steps
  # ---------------------------------------------------------------------------

  def executing_batch(ctx, opts \\ []) do
    payload = Map.fetch!(ctx, :batch_payload)

    opts =
      case Map.get(ctx, :batch_boundary) do
        nil -> opts
        boundary -> Keyword.put_new(opts, :boundary, boundary)
      end

    CRMClientDriver.execute_batch(ctx, payload, opts)
  end

  # ---------------------------------------------------------------------------
  # @then assertions (caller-line attributed)
  # ---------------------------------------------------------------------------

  defmacro batch_responses_returned(ctx, expected_items) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(expected_items)

      assert {:ok, responses} = Map.fetch!(ctx, :result)
      assert length(responses) == length(expected)

      Enum.zip(responses, expected)
      |> Enum.each(fn {%Response{} = actual, spec} ->
        if Map.has_key?(spec, :id), do: assert(actual.id == spec.id)
        if Map.has_key?(spec, :status), do: assert(actual.status == spec.status)
        if Map.has_key?(spec, :body), do: assert(actual.body == spec.body)

        if Map.has_key?(spec, :success) do
          assert Response.success?(actual) == spec.success
          assert Response.error?(actual) == not spec.success
        end
      end)

      ctx
    end
  end

  defmacro batch_response_error_converts_to(ctx, index, expected_opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(expected_opts)

      assert {:ok, responses} = Map.fetch!(ctx, :result)
      item = Enum.at(responses, unquote(index))
      assert Response.error?(item) == true

      err = Response.to_error(item)
      assert err.status == Keyword.fetch!(expected, :status)
      assert err.message == Keyword.fetch!(expected, :message)
      ctx
    end
  end

  defmacro batch_prefer_header_sent(ctx, expected_prefer) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)
      assert last_req.headers["prefer"] == [unquote(expected_prefer)]
      ctx
    end
  end

  defmacro batch_json_request_sent(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.method == "POST"
      assert last_req.request_path == "/0/odata/$batch"
      assert last_req.headers["forceusesession"] == ["true"]

      content_type = List.first(last_req.headers["content-type"] || [])
      assert String.contains?(content_type, "application/json")
      assert String.contains?(content_type, "IEEE754Compatible=true")

      if Keyword.has_key?(expected, :request_count) do
        assert length(last_req.decoded_body["requests"]) ==
                 Keyword.fetch!(expected, :request_count)
      end

      ctx
    end
  end

  defmacro batch_multipart_request_sent(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.method == "POST"
      assert last_req.request_path == "/0/odata/$batch"

      content_type = List.first(last_req.headers["content-type"] || [])
      assert String.starts_with?(content_type, "multipart/mixed; boundary=")

      if Keyword.has_key?(expected, :boundary) do
        assert String.contains?(content_type, "boundary=#{Keyword.fetch!(expected, :boundary)}")
      end

      if Keyword.has_key?(expected, :body_includes) do
        assert String.contains?(last_req.raw_body, Keyword.fetch!(expected, :body_includes))
      end

      ctx
    end
  end

  defmacro batch_failed_with(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:error, %Creatio.Error{} = err} = Map.fetch!(ctx, :result)

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
end
