defmodule Creatio.TestDSL.DataServiceDSL do
  @moduledoc """
  Layer 2 DSL for Creatio DataService SyncReply queries and custom REST service calls.
  """

  alias Creatio.Error
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver}

  # ---------------------------------------------------------------------------
  # @given steps
  # ---------------------------------------------------------------------------

  def data_service_endpoint(ctx, action, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_data_service(action, opts)
  end

  def custom_rest_endpoint(ctx, service_name, endpoint, opts \\ []) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_custom_service(service_name, endpoint, opts)
  end

  def custom_rest_service_failing(ctx, status \\ 500) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_all_error(status, %{})
  end

  # ---------------------------------------------------------------------------
  # @upon steps
  # ---------------------------------------------------------------------------

  def running_select_query(ctx, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, :select, payload, opts)
  end

  def running_insert_query(ctx, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, :insert, payload, opts)
  end

  def running_update_query(ctx, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, :update, payload, opts)
  end

  def running_delete_query(ctx, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, :delete, payload, opts)
  end

  def running_batch_query(ctx, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, :batch, payload, opts)
  end

  def executing_data_service_action(ctx, action, payload, opts \\ []) do
    CRMClientDriver.data_service_call(ctx, {:execute, action}, payload, opts)
  end

  def calling_custom_service(ctx, service_name, endpoint, payload_or_opts \\ %{}, opts \\ []) do
    CRMClientDriver.custom_service(ctx, service_name, endpoint, payload_or_opts, opts)
  end

  # ---------------------------------------------------------------------------
  # @then assertions (caller-line attributed)
  # ---------------------------------------------------------------------------

  defmacro data_service_returned(ctx, expected_body) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_body)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro data_service_sent_payload(ctx, action, expected_fields) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      last_req = CreatioServerDriver.last_request(ctx)

      assert last_req.method == "POST"
      assert last_req.request_path == "/0/DataService/json/SyncReply/#{unquote(action)}"

      Enum.each(unquote(expected_fields), fn {key, val} ->
        assert last_req.decoded_body[to_string(key)] == val
      end)

      ctx
    end
  end

  defmacro data_service_failed_with(ctx, opts) do
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

      ctx
    end
  end

  defmacro custom_service_failed_with(ctx, opts) do
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

      if Keyword.has_key?(expected, :message_contains) do
        assert String.contains?(err.message, Keyword.fetch!(expected, :message_contains))
      end

      ctx
    end
  end

  defmacro custom_service_sent_request(ctx, opts) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)
      last_req = CreatioServerDriver.last_request(ctx)

      if Keyword.has_key?(expected, :method) do
        assert last_req.method == Keyword.fetch!(expected, :method)
      end

      if Keyword.has_key?(expected, :request_path) do
        assert last_req.request_path == Keyword.fetch!(expected, :request_path)
      end

      if Keyword.has_key?(expected, :query_params) do
        assert last_req.query_params == Keyword.fetch!(expected, :query_params)
      end

      if Keyword.has_key?(expected, :decoded_body) do
        assert last_req.decoded_body == Keyword.fetch!(expected, :decoded_body)
      end

      ctx
    end
  end

  defmacro bang_raised_creatio_error(ctx, expected_message) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:raised, %Error{message: msg}} = Map.fetch!(ctx, :result)
      assert msg == unquote(expected_message)
      ctx
    end
  end

  defmacro custom_service_returned(ctx, expected_body) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:ok, unquote(expected_body)} == Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro custom_service_failed_with_status(ctx, expected_status) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:error, %Error{status: unquote(expected_status)}} = Map.fetch!(ctx, :result)
      ctx
    end
  end
end
