defmodule Creatio.TestDrivers.CreatioServerDriver do
  @moduledoc """
  Layer 3 Protocol Driver simulating Creatio CRM HTTP endpoints and transport layers.

  Manages an isolated per-test `Agent` for stubbing OData 4, OData 3, Auth, Batch,
  DataService, and custom REST responses while recording every wire request for
  protocol assertions. Safe for `async: true` concurrent execution.
  """

  import Plug.Conn

  alias Creatio.Client

  @default_base_url "https://mycreatio.com"
  @odata3_base_path "/0/ServiceModel/EntityDataService.svc"

  @doc """
  Ensures an isolated server state `Agent` is started and stored in `ctx`.
  """
  def ensure_server(%{server_agent: agent} = ctx) when is_pid(agent), do: ctx

  def ensure_server(ctx) when is_map(ctx) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          requests: [],
          routes: [],
          transport_error: nil
        }
      end)

    ctx
    |> Map.put(:server_agent, agent)
    |> Map.put_new(:base_url, @default_base_url)
  end

  @doc """
  Returns a Plug callback bound to the test's isolated server `Agent`.
  """
  def plug(%{server_agent: agent}), do: plug(agent)

  def plug(agent) when is_pid(agent) do
    fn conn ->
      {raw_body, conn} = read_full_body(conn, "")
      decoded_body = decode_request_body(raw_body, conn.req_headers)

      request_record = %{
        method: conn.method,
        request_path: conn.request_path,
        query_string: conn.query_string,
        query_params: URI.decode_query(conn.query_string),
        headers: normalize_req_headers(conn.req_headers),
        raw_body: raw_body,
        decoded_body: decoded_body
      }

      handler =
        Agent.get_and_update(agent, fn state ->
          matched =
            Enum.find_value(state.routes, fn {matcher, handler} ->
              if matcher.(request_record), do: handler, else: nil
            end)

          {matched, %{state | requests: state.requests ++ [request_record]}}
        end)

      case handler do
        nil ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            404,
            Jason.encode!(%{
              "error" => %{
                "code" => "UnstubbedEndpoint",
                "message" =>
                  "No CreatioServerDriver route matched #{conn.method} #{conn.request_path}?#{conn.query_string}"
              }
            })
          )

        fun when is_function(fun, 2) ->
          fun.(conn, request_record)
      end
    end
  end

  @doc """
  Builds a `%Creatio.Client{}` configured to talk to the test's isolated server driver.
  """
  def client(ctx, opts \\ []) do
    ctx = ensure_server(ctx)
    base_url = Keyword.get(opts, :base_url, Map.get(ctx, :base_url, @default_base_url))
    req_options = req_options_for_server(ctx)

    opts
    |> Keyword.put_new(:base_url, base_url)
    |> Keyword.update(:req_options, req_options, &Keyword.merge(req_options, &1))
    |> Client.new()
  end

  @doc """
  Builds a raw `%Req.Request{}` configured to talk to the test's isolated server driver.
  """
  def req(ctx, opts \\ []) do
    ctx = ensure_server(ctx)
    base_url = Keyword.get(opts, :base_url, Map.get(ctx, :base_url, @default_base_url))
    req_options = req_options_for_server(ctx)

    opts
    |> Keyword.put_new(:base_url, base_url)
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  @doc """
  Returns the `req_options` needed to attach `Req` calls to the test's server driver.
  """
  def req_options_for_server(ctx) do
    ctx = ensure_server(ctx)
    transport_error = Agent.get(ctx.server_agent, & &1.transport_error)

    if transport_error do
      adapter = fn req -> {req, transport_error} end
      [adapter: adapter, retry: false]
    else
      [plug: plug(ctx.server_agent), retry: false]
    end
  end

  @doc """
  Configures the server driver to simulate a transport-level timeout error.
  """
  def use_transport_timeout(ctx) do
    ctx = ensure_server(ctx)

    Agent.update(
      ctx.server_agent,
      &%{&1 | transport_error: %Req.TransportError{reason: :timeout}}
    )

    ctx
  end

  @doc """
  Registers a catch-all HTTP error response for any endpoint on the simulated server.
  """
  def stub_all_error(ctx, status, body \\ %{}) do
    add_route(ctx, fn _req -> true end, fn conn, _req ->
      send_json_or_raw(conn, status, body)
    end)
  end

  @doc """
  Registers a route `{matcher, handler}` on the simulated server.
  """
  def add_route(ctx, matcher, handler) when is_function(matcher, 1) and is_function(handler, 2) do
    ctx = ensure_server(ctx)

    Agent.update(ctx.server_agent, fn state ->
      %{state | routes: [{matcher, handler} | state.routes]}
    end)

    ctx
  end

  @doc """
  Returns all recorded HTTP requests received by the simulated server in order.
  """
  def recorded_requests(%{server_agent: agent}) do
    Agent.get(agent, & &1.requests)
  end

  @doc """
  Returns the most recent recorded HTTP request, or `nil`.
  """
  def last_request(ctx) do
    ctx |> recorded_requests() |> List.last()
  end

  # ---------------------------------------------------------------------------
  # Auth Protocol Stubs
  # ---------------------------------------------------------------------------

  @doc """
  Stubs `/ServiceModel/AuthService.svc/Login` for Forms authentication.
  """
  def stub_forms_login(ctx, opts \\ []) do
    path = Keyword.get(opts, :path, "/ServiceModel/AuthService.svc/Login")
    status = Keyword.get(opts, :status, 200)
    cookies = Keyword.get(opts, :cookies, [])
    bpmcsrf_header = Keyword.get(opts, :bpmcsrf_header)
    content_type = Keyword.get(opts, :content_type, "application/json")

    body =
      cond do
        Keyword.has_key?(opts, :raw_body) ->
          Keyword.fetch!(opts, :raw_body)

        Keyword.has_key?(opts, :error_body) ->
          Keyword.fetch!(opts, :error_body)

        true ->
          %{
            "Code" => Keyword.get(opts, :code, 0),
            "Message" => Keyword.get(opts, :message, "")
          }
      end

    add_route(
      ctx,
      fn req -> req.method == "POST" and req.request_path == path end,
      fn conn, _req ->
        conn =
          Enum.reduce(Enum.reverse(cookies), conn, fn cookie_val, acc ->
            %{acc | resp_headers: [{"set-cookie", cookie_val} | acc.resp_headers]}
          end)

        conn =
          if bpmcsrf_header do
            put_resp_header(conn, "bpmcsrf", bpmcsrf_header)
          else
            conn
          end

        encoded = if is_binary(body), do: body, else: Jason.encode!(body)

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(status, encoded)
      end
    )
  end

  @doc """
  Stubs `{identity_service_url}/connect/token` for OAuth 2.0 client credentials.
  """
  def stub_oauth_token(ctx, opts \\ []) do
    path = Keyword.get(opts, :path, "/connect/token")
    status = Keyword.get(opts, :status, 200)

    body =
      Keyword.get_lazy(opts, :body, fn ->
        %{
          "access_token" => Keyword.get(opts, :access_token, "oauth_access_token_12345"),
          "expires_in" => Keyword.get(opts, :expires_in, 3600),
          "token_type" => Keyword.get(opts, :token_type, "Bearer"),
          "scope" => Keyword.get(opts, :scope, "ApplicationAccess_xyz")
        }
      end)

    add_route(
      ctx,
      fn req -> req.method == "POST" and req.request_path == path end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs `/0/api/OAuthHealthCheck`.
  """
  def stub_oauth_health(ctx, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get(opts, :body, %{"status" => "Healthy"})

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == "/0/api/OAuthHealthCheck" end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs OpenID Connect discovery (`/.well-known/openid-configuration`).
  """
  def stub_openid_configuration(ctx, opts \\ []) do
    path = Keyword.get(opts, :path, "/.well-known/openid-configuration")
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get(opts, :body, %{"token_endpoint" => "https://identity/connect/token"})

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and
          req.request_path in [path, "/identity/.well-known/openid-configuration"]
      end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  # ---------------------------------------------------------------------------
  # OData 4 Protocol Stubs
  # ---------------------------------------------------------------------------

  @doc """
  Stubs an OData 4 collection listing endpoint (`GET /0/odata/{entity}`).
  """
  def stub_odata_list(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    records = Keyword.get(opts, :records, [])
    count = Keyword.get(opts, :count)
    bare_array? = Keyword.get(opts, :bare_array, false)

    payload =
      cond do
        Keyword.has_key?(opts, :error) ->
          Keyword.fetch!(opts, :error)

        bare_array? ->
          records

        is_nil(count) ->
          %{"value" => records}

        true ->
          %{"@odata.count" => count, "value" => records}
      end

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == "/0/odata/#{entity}" end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(payload))
      end
    )
  end

  @doc """
  Stubs paginated OData 4 collection responses sliced by `$skip` and `$top`.
  """
  def stub_odata_stream(ctx, entity, records) when is_list(records) do
    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == "/0/odata/#{entity}" end,
      fn conn, req ->
        skip = parse_int_param(req.query_params["$skip"], 0)
        top = parse_int_param(req.query_params["$top"], length(records))
        slice = Enum.slice(records, skip, top)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"value" => slice}))
      end
    )
  end

  @doc """
  Stubs an OData 4 single-entity endpoint (`GET /0/odata/{entity}({id})`).
  """
  def stub_odata_get(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    body = Keyword.get(opts, :body) || Keyword.get(opts, :record, %{"Id" => id})

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == "/0/odata/#{entity}(#{id})" end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs an OData 4 navigation property endpoint (`GET /0/odata/{entity}({id})/{nav}`).
  """
  def stub_odata_navigation(ctx, entity, id, nav, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    body =
      cond do
        Keyword.has_key?(opts, :body) -> Keyword.fetch!(opts, :body)
        Keyword.has_key?(opts, :records) -> %{"value" => Keyword.fetch!(opts, :records)}
        Keyword.has_key?(opts, :record) -> Keyword.fetch!(opts, :record)
        true -> %{"value" => []}
      end

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and req.request_path == "/0/odata/#{entity}(#{id})/#{nav}"
      end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs an OData 4 field retrieval endpoint (`GET /0/odata/{entity}({id})/{field}`).
  """
  def stub_odata_field(ctx, entity, id, field, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    raw? = Keyword.get(opts, :raw, false)
    suffix = if raw?, do: "/$value", else: ""
    path = "/0/odata/#{entity}(#{id})/#{field}#{suffix}"

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == path end,
      fn conn, _req ->
        if raw? do
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(status, to_string(Keyword.fetch!(opts, :value)))
        else
          body = Keyword.get(opts, :body, %{"value" => Keyword.get(opts, :value)})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))
        end
      end
    )
  end

  @doc """
  Stubs an OData 4 entity count endpoint (`/$count` or `?$count=true&$top=0`).
  """
  def stub_odata_count(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    strategy = Keyword.get(opts, :strategy, :path)
    format = Keyword.get(opts, :format, :plain_text)
    count_value = Keyword.fetch!(opts, :count)

    path =
      case strategy do
        :top_zero -> "/0/odata/#{entity}"
        _ -> "/0/odata/#{entity}/$count"
      end

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == path end,
      fn conn, _req ->
        send_odata_count_response(conn, status, format, count_value)
      end
    )
  end

  @doc """
  Stubs OData 4 entity creation (`POST /0/odata/{entity}`).
  """
  def stub_odata_create(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 201)
    assigned_id = Keyword.get(opts, :assigned_id, "new-uuid-1")

    add_route(
      ctx,
      fn req -> req.method == "POST" and req.request_path == "/0/odata/#{entity}" end,
      fn conn, req ->
        created =
          case Keyword.get(opts, :body) do
            nil -> Map.put(req.decoded_body || %{}, "Id", assigned_id)
            explicit -> explicit
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(created))
      end
    )
  end

  @doc """
  Stubs OData 4 entity update (`PATCH /0/odata/{entity}({id})`).
  """
  def stub_odata_update(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 204)

    add_route(
      ctx,
      fn req -> req.method == "PATCH" and req.request_path == "/0/odata/#{entity}(#{id})" end,
      fn conn, _req ->
        if Keyword.has_key?(opts, :body) do
          send_json_or_raw(conn, status, Keyword.fetch!(opts, :body))
        else
          send_resp(conn, status, "")
        end
      end
    )
  end

  @doc """
  Stubs OData 4 entity deletion (`DELETE /0/odata/{entity}({id})`).
  """
  def stub_odata_delete(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 204)

    add_route(
      ctx,
      fn req -> req.method == "DELETE" and req.request_path == "/0/odata/#{entity}(#{id})" end,
      fn conn, _req ->
        send_resp(conn, status, "")
      end
    )
  end

  @doc """
  Stubs OData 4 field update (`PUT /0/odata/{entity}({id})/{field}`).
  """
  def stub_odata_update_field(ctx, entity, id, field, opts \\ []) do
    status = Keyword.get(opts, :status, 204)

    add_route(
      ctx,
      fn req ->
        req.method == "PUT" and req.request_path == "/0/odata/#{entity}(#{id})/#{field}"
      end,
      fn conn, _req ->
        send_resp(conn, status, "")
      end
    )
  end

  @doc """
  Stubs OData 4 field deletion (`DELETE /0/odata/{entity}({id})/{field}`).
  """
  def stub_odata_delete_field(ctx, entity, id, field, opts \\ []) do
    status = Keyword.get(opts, :status, 204)

    add_route(
      ctx,
      fn req ->
        req.method == "DELETE" and req.request_path == "/0/odata/#{entity}(#{id})/#{field}"
      end,
      fn conn, _req ->
        send_resp(conn, status, "")
      end
    )
  end

  # ---------------------------------------------------------------------------
  # OData 3 Legacy Protocol Stubs
  # ---------------------------------------------------------------------------

  @doc """
  Stubs an OData 3 collection listing endpoint.
  """
  def stub_odata3_list(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    records = Keyword.get(opts, :records, [])
    count = Keyword.get(opts, :count)
    count_key = Keyword.get(opts, :count_key, "__count")
    envelope = Keyword.get(opts, :envelope, :results)
    collection = collection_name(entity)

    d_payload =
      case {envelope, count} do
        {:d_list, _} -> records
        {_, nil} -> %{"results" => records}
        {_, _} -> %{"results" => records, count_key => count}
      end

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and req.request_path == "#{@odata3_base_path}/#{collection}"
      end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(%{"d" => d_payload}))
      end
    )
  end

  @doc """
  Stubs paginated OData 3 collection responses sliced by `$skip` and `$top`.
  """
  def stub_odata3_stream(ctx, entity, records) when is_list(records) do
    collection = collection_name(entity)

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and req.request_path == "#{@odata3_base_path}/#{collection}"
      end,
      fn conn, req ->
        skip = parse_int_param(req.query_params["$skip"], 0)
        top = parse_int_param(req.query_params["$top"], length(records))
        slice = Enum.slice(records, skip, top)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"d" => %{"results" => slice}}))
      end
    )
  end

  @doc """
  Stubs an OData 3 single-entity endpoint (`...Collection(guid'{id}')`).
  """
  def stub_odata3_get(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    collection = collection_name(entity)
    body = Keyword.get(opts, :body) || %{"d" => Keyword.get(opts, :record, %{"Id" => id})}

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and
          req.request_path == "#{@odata3_base_path}/#{collection}(guid'#{id}')"
      end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs an OData 3 navigation property endpoint.
  """
  def stub_odata3_navigation(ctx, entity, id, nav, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    collection = collection_name(entity)

    body =
      cond do
        Keyword.has_key?(opts, :body) ->
          Keyword.fetch!(opts, :body)

        Keyword.has_key?(opts, :records) ->
          %{"d" => %{"results" => Keyword.fetch!(opts, :records)}}

        Keyword.has_key?(opts, :record) ->
          %{"d" => Keyword.fetch!(opts, :record)}

        true ->
          %{"d" => %{}}
      end

    add_route(
      ctx,
      fn req ->
        req.method == "GET" and
          req.request_path == "#{@odata3_base_path}/#{collection}(guid'#{id}')/#{nav}"
      end,
      fn conn, _req ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs an OData 3 field retrieval endpoint (`/Field` or `/Field/$value`).
  """
  def stub_odata3_field(ctx, entity, id, field, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    raw? = Keyword.get(opts, :raw, false)
    collection = collection_name(entity)
    suffix = if raw?, do: "/$value", else: ""
    path = "#{@odata3_base_path}/#{collection}(guid'#{id}')/#{field}#{suffix}"

    add_route(
      ctx,
      fn req -> req.method == "GET" and req.request_path == path end,
      fn conn, _req ->
        if raw? do
          send_resp(conn, status, to_string(Keyword.fetch!(opts, :value)))
        else
          body = Keyword.get(opts, :body, %{"d" => %{field => Keyword.get(opts, :value)}})

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(body))
        end
      end
    )
  end

  @doc """
  Stubs an OData 3 count endpoint (`/$count` or `?/$count`).
  """
  def stub_odata3_count(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    strategy = Keyword.get(opts, :strategy, :path)
    format = Keyword.get(opts, :format, :plain_text)
    collection = collection_name(entity)
    count_value = Keyword.get(opts, :count)

    matcher =
      case strategy do
        :query ->
          fn req ->
            req.method == "GET" and req.request_path == "#{@odata3_base_path}/#{collection}" and
              req.query_string == "/$count"
          end

        _ ->
          fn req ->
            req.method == "GET" and
              req.request_path == "#{@odata3_base_path}/#{collection}/$count"
          end
      end

    add_route(ctx, matcher, fn conn, _req ->
      case format do
        :d_count_int ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(%{"d" => count_value}))

        :d_nested_count ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            status,
            Jason.encode!(%{"d" => %{"results" => [], "count" => count_value}})
          )

        :bom_plain_text ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(status, "\uFEFF#{count_value}")

        :json_integer ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(count_value))

        _ ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(status, to_string(count_value))
      end
    end)
  end

  @doc """
  Stubs OData 3 entity creation (`POST ...Collection`).
  """
  def stub_odata3_create(ctx, entity, opts \\ []) do
    status = Keyword.get(opts, :status, 201)
    collection = collection_name(entity)
    assigned_id = Keyword.get(opts, :assigned_id, "guid-new")

    add_route(
      ctx,
      fn req ->
        req.method == "POST" and req.request_path == "#{@odata3_base_path}/#{collection}"
      end,
      fn conn, req ->
        body =
          Keyword.get_lazy(opts, :body, fn ->
            Map.put(req.decoded_body || %{}, "Id", assigned_id)
          end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Jason.encode!(body))
      end
    )
  end

  @doc """
  Stubs OData 3 entity update (`PATCH ...Collection(guid'{id}')`).
  """
  def stub_odata3_update(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 204)
    collection = collection_name(entity)

    add_route(
      ctx,
      fn req ->
        req.method == "PATCH" and
          req.request_path == "#{@odata3_base_path}/#{collection}(guid'#{id}')"
      end,
      fn conn, _req ->
        if Keyword.has_key?(opts, :body) do
          send_json_or_raw(conn, status, Keyword.fetch!(opts, :body))
        else
          send_resp(conn, status, "")
        end
      end
    )
  end

  @doc """
  Stubs OData 3 entity deletion (`DELETE ...Collection(guid'{id}')`).
  """
  def stub_odata3_delete(ctx, entity, id, opts \\ []) do
    status = Keyword.get(opts, :status, 204)
    collection = collection_name(entity)

    add_route(
      ctx,
      fn req ->
        req.method == "DELETE" and
          req.request_path == "#{@odata3_base_path}/#{collection}(guid'#{id}')"
      end,
      fn conn, _req ->
        send_resp(conn, status, "")
      end
    )
  end

  # ---------------------------------------------------------------------------
  # Batch, DataService & Custom REST Stubs
  # ---------------------------------------------------------------------------

  @doc """
  Stubs `/0/odata/$batch` for JSON, single-entity, or multipart responses.
  """
  def stub_batch(ctx, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    add_route(
      ctx,
      fn req -> req.method == "POST" and req.request_path == "/0/odata/$batch" end,
      fn conn, _req ->
        cond do
          Keyword.has_key?(opts, :multipart_body) ->
            boundary = Keyword.fetch!(opts, :boundary)
            body = Keyword.fetch!(opts, :multipart_body)

            conn
            |> put_resp_header("content-type", "multipart/mixed; boundary=#{boundary}")
            |> send_resp(status, body)

          Keyword.has_key?(opts, :single_entity) ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(status, Jason.encode!(Keyword.fetch!(opts, :single_entity)))

          true ->
            responses = Keyword.get(opts, :responses, [])

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(status, Jason.encode!(%{"responses" => responses}))
        end
      end
    )
  end

  @doc """
  Stubs `/0/DataService/json/SyncReply/{action}`.
  """
  def stub_data_service(ctx, action, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    content_type = Keyword.get(opts, :content_type, "application/json")
    body = Keyword.get(opts, :body, %{"success" => true})

    add_route(
      ctx,
      fn req ->
        req.method == "POST" and req.request_path == "/0/DataService/json/SyncReply/#{action}"
      end,
      fn conn, _req ->
        encoded = if is_binary(body), do: body, else: Jason.encode!(body)

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(status, encoded)
      end
    )
  end

  @doc """
  Stubs `/0/rest/{service_name}/{endpoint}` for custom REST web services.
  """
  def stub_custom_service(ctx, service_name, endpoint, opts \\ []) do
    method = opts |> Keyword.get(:method, :post) |> to_string() |> String.upcase()
    status = Keyword.get(opts, :status, 200)
    echo? = Keyword.get(opts, :echo, false)
    body = Keyword.get(opts, :body, %{})

    add_route(
      ctx,
      fn req ->
        req.method == method and req.request_path == "/0/rest/#{service_name}/#{endpoint}"
      end,
      fn conn, req ->
        cond do
          status == 204 ->
            send_resp(conn, 204, "")

          echo? ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(status, req.raw_body)

          true ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(status, Jason.encode!(body))
        end
      end
    )
  end

  @doc """
  Stubs a pass-through JSON responder for read-only Req guard testing.
  """
  def stub_generic_json_ok(ctx, body \\ %{}) do
    add_route(ctx, fn _req -> true end, fn conn, _req ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, body, conn} -> {acc <> body, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
    end
  end

  defp decode_request_body("", _headers), do: nil

  defp decode_request_body(raw_body, headers) do
    content_type =
      Enum.find_value(headers, "", fn {k, v} ->
        if String.downcase(k) == "content-type", do: v, else: nil
      end)

    cond do
      String.contains?(content_type, "application/json") ->
        case Jason.decode(raw_body) do
          {:ok, decoded} -> decoded
          _ -> raw_body
        end

      String.contains?(content_type, "application/x-www-form-urlencoded") ->
        URI.decode_query(raw_body)

      true ->
        raw_body
    end
  end

  defp normalize_req_headers(headers) do
    Enum.reduce(headers, %{}, fn {k, v}, acc ->
      key = String.downcase(k)
      Map.update(acc, key, [v], fn existing -> existing ++ [v] end)
    end)
  end

  defp send_json_or_raw(conn, status, body) when is_binary(body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end

  defp send_json_or_raw(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp send_odata_count_response(conn, status, :plain_text, count_value) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, to_string(count_value))
  end

  defp send_odata_count_response(conn, status, :bom_plain_text, count_value) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, "\uFEFF#{count_value}")
  end

  defp send_odata_count_response(conn, status, :json_integer, count_value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(count_value))
  end

  defp send_odata_count_response(conn, status, :odata_count, count_value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"@odata.count" => count_value}))
  end

  defp send_odata_count_response(conn, status, :odata_count_string, count_value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"@odata.count" => to_string(count_value)}))
  end

  defp send_odata_count_response(conn, status, :value_string, count_value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"value" => to_string(count_value)}))
  end

  defp send_odata_count_response(conn, status, :value_and_count, {val, count_value}) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"value" => val, "@odata.count" => count_value}))
  end

  defp parse_int_param(nil, default), do: default

  defp parse_int_param(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp collection_name(entity) do
    if String.ends_with?(entity, "Collection"), do: entity, else: "#{entity}Collection"
  end
end
