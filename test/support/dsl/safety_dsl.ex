defmodule Creatio.TestDSL.SafetyDSL do
  @moduledoc """
  Layer 2 DSL for read-only safety guards, SDK facade delegation, bang error handling,
  and transport resilience scenarios.
  """

  alias Creatio.Batch.Response, as: BatchResponse
  alias Creatio.Client
  alias Creatio.Error
  alias Creatio.TestDrivers.{CreatioServerDriver, CRMClientDriver, FacadeDriver}

  # ---------------------------------------------------------------------------
  # @given steps
  # ---------------------------------------------------------------------------

  def read_only_crm_client(ctx) do
    ctx = CreatioServerDriver.ensure_server(ctx)
    client = CreatioServerDriver.client(ctx, read_only: true)
    Map.put(ctx, :client, client)
  end

  def read_only_crm_client_with_server(ctx, opts \\ []) do
    ctx =
      ctx
      |> CreatioServerDriver.ensure_server()
      |> CreatioServerDriver.stub_generic_json_ok(%{})

    ctx =
      case Keyword.get(opts, :batch_responses) do
        nil -> ctx
        responses -> CreatioServerDriver.stub_batch(ctx, responses: responses)
      end

    client = CreatioServerDriver.client(ctx, read_only: true)
    Map.put(ctx, :client, client)
  end

  def crm_server_accepting_requests(ctx, opts \\ []) do
    ctx =
      ctx
      |> CreatioServerDriver.ensure_server()
      |> CreatioServerDriver.stub_generic_json_ok(Keyword.get(opts, :body, %{"success" => true}))

    case Keyword.get(opts, :batch_responses) do
      nil -> ctx
      responses -> CreatioServerDriver.stub_batch(ctx, responses: responses)
    end
  end

  def crm_server_failing_with_status(ctx, status, body \\ %{}) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.stub_all_error(status, body)
  end

  def crm_server_timing_out(ctx) do
    ctx
    |> CreatioServerDriver.ensure_server()
    |> CreatioServerDriver.use_transport_timeout()
  end

  def crm_facade_server(ctx) do
    FacadeDriver.stub_full_crm_server(ctx)
  end

  # ---------------------------------------------------------------------------
  # @upon / @whenever steps
  # ---------------------------------------------------------------------------

  def attempting_operation(ctx, op) do
    CRMClientDriver.invoke_operation(ctx, op)
  end

  def sending_transport_request(ctx, method, endpoint_kind) do
    path = resolve_transport_endpoint(endpoint_kind)
    CRMClientDriver.invoke_operation(ctx, {:raw_req, method, path})
  end

  def invoking_facade(ctx, spec) do
    FacadeDriver.invoke_facade(ctx, spec)
  end

  # ---------------------------------------------------------------------------
  # @then assertions (line-attributed to Layer 1 caller)
  # ---------------------------------------------------------------------------

  defmacro client_is_in_read_only_mode(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      client = Map.fetch!(ctx, :client)
      assert %Client{read_only: true} = client
      assert Client.to_req(client) == client.req
      ctx
    end
  end

  defmacro blocked_locally_by_read_only_mode(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} = Map.fetch!(ctx, :result)
      assert CreatioServerDriver.recorded_requests(ctx) == []

      ctx
    end
  end

  defmacro blocked_at_transport_by_read_only_mode(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} = Map.fetch!(ctx, :result)
      assert CreatioServerDriver.recorded_requests(ctx) == []

      ctx
    end
  end

  defmacro raw_request_succeeded(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)

      assert {:ok, %Req.Response{status: 200}} = Map.fetch!(ctx, :result)
      assert CreatioServerDriver.recorded_requests(ctx) != []

      ctx
    end
  end

  defmacro batch_succeeded_with_responses(ctx, expected_count) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)

      assert {:ok, [%BatchResponse{} | _] = responses} = Map.fetch!(ctx, :result)
      assert length(responses) == unquote(expected_count)

      ctx
    end
  end

  defmacro bang_raised_error(ctx, opts \\ []) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      expected = unquote(opts)

      assert {:raised, %Error{} = err} = Map.fetch!(ctx, :result)

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

  defmacro operation_returned_error(ctx, opts \\ []) do
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

  defmacro timeout_error_returned(ctx) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      assert {:error, %Error{message: "timeout"}} = Map.fetch!(ctx, :result)
      ctx
    end
  end

  defmacro facade_result_matches(ctx, expected) do
    quote line: __CALLER__.line do
      ctx = unquote(ctx)
      actual = Map.fetch!(ctx, :result)

      case unquote(expected) do
        {:batch_response_count, expected_count} ->
          assert {:ok, [%BatchResponse{} | _] = responses} = actual
          assert length(responses) == expected_count

        expected_value ->
          assert actual == expected_value
      end

      ctx
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp resolve_transport_endpoint(:odata_entity_query), do: "/0/odata/Contact"
  defp resolve_transport_endpoint(:odata_collection), do: "/0/odata/Contact"
  defp resolve_transport_endpoint(:select_query), do: "/0/DataService/json/SyncReply/SelectQuery"
  defp resolve_transport_endpoint(:insert_query), do: "/0/DataService/json/SyncReply/InsertQuery"
  defp resolve_transport_endpoint(:forms_login), do: "/ServiceModel/AuthService.svc/Login"
  defp resolve_transport_endpoint(:legacy_auth_login), do: "/AuthService.svc/Login"
  defp resolve_transport_endpoint(:oauth_token), do: "/connect/token"
  defp resolve_transport_endpoint(:batch_endpoint), do: "/0/odata/$batch"
  defp resolve_transport_endpoint(:custom_rest), do: "/0/rest/SomeService/Method"
end
