defmodule Creatio.TelemetryTest do
  use ExUnit.Case, async: true

  alias Creatio.{Auth, Batch, Client, DataService, Error, OData, OData3, Telemetry}

  @expected_events [
    [:creatio, :request, :start],
    [:creatio, :request, :stop],
    [:creatio, :request, :exception],
    [:creatio, :odata, :start],
    [:creatio, :odata, :stop],
    [:creatio, :odata, :exception],
    [:creatio, :odata3, :start],
    [:creatio, :odata3, :stop],
    [:creatio, :odata3, :exception],
    [:creatio, :data_service, :start],
    [:creatio, :data_service, :stop],
    [:creatio, :data_service, :exception],
    [:creatio, :auth, :start],
    [:creatio, :auth, :stop],
    [:creatio, :auth, :exception],
    [:creatio, :batch, :start],
    [:creatio, :batch, :stop],
    [:creatio, :batch, :exception]
  ]

  setup do
    test_pid = self()
    handler_id = "creatio-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        @expected_events,
        &__MODULE__.handle_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  def handle_event(event, measurements, metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        drain_events([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "Telemetry.events/0 and credential redaction helpers" do
    test "events/0 returns all 18 request and domain telemetry events" do
      assert Telemetry.events() == @expected_events
    end

    test "sanitize_headers/1 and sanitize_metadata/1 redact secrets case-insensitively" do
      headers = %{
        "authorization" => ["Bearer super-secret-jwt"],
        "Cookie" => [".ASPXAUTH=secret-cookie; BPMCSRF=csrf-secret"],
        "bpmcsrf" => ["csrf-secret"],
        "set-cookie" => ["BPMCSRF=next-secret; Path=/"],
        "x-api-key" => ["api-secret"],
        "proxy-authorization" => ["Basic secret"],
        "accept" => ["application/json; odata.metadata=minimal"]
      }

      sanitized_headers = Telemetry.sanitize_headers(headers)
      assert sanitized_headers["authorization"] == ["[REDACTED]"]
      assert sanitized_headers["Cookie"] == ["[REDACTED]"]
      assert sanitized_headers["bpmcsrf"] == ["[REDACTED]"]
      assert sanitized_headers["set-cookie"] == ["[REDACTED]"]
      assert sanitized_headers["x-api-key"] == ["[REDACTED]"]
      assert sanitized_headers["proxy-authorization"] == ["[REDACTED]"]
      assert sanitized_headers["accept"] == ["application/json; odata.metadata=minimal"]

      raw_meta = %{
        "UserPassword" => "secret-UserPassword-str",
        auth_token: "secret-auth-token",
        client_secret: "secret-client-secret",
        cookie: ".ASPXAUTH=secret",
        bpmcsrf: "csrf-secret",
        password: "secret-password",
        user_password: "secret-user-password",
        UserPassword: "secret-UserPassword",
        access_token: "secret-access",
        refresh_token: "secret-refresh",
        bearer_token: "secret-bearer",
        headers: headers,
        entity: "Contact"
      }

      sanitized_meta = Telemetry.sanitize_metadata(raw_meta)
      assert sanitized_meta.auth_token == "[REDACTED]"
      assert sanitized_meta.client_secret == "[REDACTED]"
      assert sanitized_meta.cookie == "[REDACTED]"
      assert sanitized_meta.bpmcsrf == "[REDACTED]"
      assert sanitized_meta.password == "[REDACTED]"
      assert sanitized_meta.user_password == "[REDACTED]"
      assert Map.fetch!(sanitized_meta, :UserPassword) == "[REDACTED]"
      assert sanitized_meta["UserPassword"] == "[REDACTED]"
      assert sanitized_meta.access_token == "[REDACTED]"
      assert sanitized_meta.refresh_token == "[REDACTED]"
      assert sanitized_meta.bearer_token == "[REDACTED]"
      assert sanitized_meta.headers["authorization"] == ["[REDACTED]"]
      assert sanitized_meta.entity == "Contact"
    end
  end

  describe "HTTP request events ([:creatio, :request, *]) and redaction" do
    test "emits :start and :stop with duration and sanitized metadata on HTTP responses" do
      plug = fn conn ->
        case conn.request_path do
          "/0/odata/Contact" ->
            Req.Test.json(conn, %{"value" => [%{"Id" => "1"}]})

          "/0/odata/Missing" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => %{"message" => "Not found"}}))
        end
      end

      client =
        Client.new(
          base_url: "https://telemetry.creatio.com",
          auth_token: "top-secret-bearer-123",
          req_options: [plug: plug]
        )

      assert {:ok, [%{"Id" => "1"}]} = OData.list(client, "Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :start], start_meas, start_meta}
      assert is_integer(start_meas.system_time)
      assert start_meta.method == :get
      assert start_meta.path == "/0/odata/Contact"
      assert start_meta.base_url == "https://telemetry.creatio.com"
      assert start_meta.auth_mode == :bearer
      assert start_meta.headers["authorization"] == ["[REDACTED]"]
      refute inspect(start_meta) =~ "top-secret-bearer-123"

      assert_receive {:telemetry_event, [:creatio, :request, :stop], stop_meas, stop_meta}
      assert is_integer(stop_meas.duration) and stop_meas.duration >= 0
      assert stop_meta.method == :get
      assert stop_meta.path == "/0/odata/Contact"
      assert stop_meta.status == 200
      assert stop_meta.result == :ok
      assert stop_meta.error == nil
      refute inspect(stop_meta) =~ "top-secret-bearer-123"

      _ = drain_events()

      assert {:error, %Error{status: 404}} = OData.list(client, "Missing")
      assert_receive {:telemetry_event, [:creatio, :request, :stop], _, err_stop_meta}
      assert err_stop_meta.status == 404
      assert err_stop_meta.result == :error
    end

    test "emits :exception without leaking secrets on transport error or read_only_guard block" do
      adapter = fn req ->
        {req, %Req.TransportError{reason: :timeout}}
      end

      client =
        Client.new(
          base_url: "https://telemetry.creatio.com",
          cookie: ".ASPXAUTH=cookie-secret",
          bpmcsrf: "bpmcsrf-secret",
          req_options: [adapter: adapter, retry: false]
        )

      assert {:error, %Error{}} = OData.list(client, "Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :start], _, start_meta}
      assert start_meta.headers["cookie"] == ["[REDACTED]"]
      assert start_meta.headers["bpmcsrf"] == ["[REDACTED]"]
      refute inspect(start_meta) =~ "cookie-secret"
      refute inspect(start_meta) =~ "bpmcsrf-secret"

      assert_receive {:telemetry_event, [:creatio, :request, :exception], exc_meas, exc_meta}
      assert is_integer(exc_meas.duration) and exc_meas.duration >= 0
      assert exc_meta.kind == :error
      assert %Req.TransportError{reason: :timeout} = exc_meta.reason
      assert exc_meta.result == :error
      refute inspect(exc_meta) =~ "cookie-secret"
      refute inspect(exc_meta) =~ "bpmcsrf-secret"

      _ = drain_events()

      ro_client =
        Client.new(
          base_url: "https://telemetry.creatio.com",
          auth_token: "ro-bearer-secret",
          read_only: true,
          req_options: [plug: fn conn -> Req.Test.json(conn, %{}) end]
        )

      assert {:error, %Error{status: 403, code: "ReadOnlyMode"}} =
               Req.post(ro_client.req, url: "/0/odata/Contact", json: %{})

      assert_receive {:telemetry_event, [:creatio, :request, :exception], _, ro_exc_meta}
      assert ro_exc_meta.status == 403
      assert %Error{code: "ReadOnlyMode"} = ro_exc_meta.reason
      assert ro_exc_meta.result == :error
      refute inspect(ro_exc_meta) =~ "ro-bearer-secret"
    end
  end

  describe "domain spans for OData 4 and OData 3 (Option 4)" do
    test "emits [:creatio, :odata, *] across all OData 4 operations" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/0/odata/Contact"} ->
            Req.Test.json(conn, %{"value" => [%{"Id" => "1"}]})

          {"GET", "/0/odata/Contact('1')"} ->
            Req.Test.json(conn, %{"Id" => "1"})

          {"GET", "/0/odata/Contact('1')/Account"} ->
            Req.Test.json(conn, %{"Id" => "a-1"})

          {"GET", "/0/odata/Contact('1')/Name"} ->
            Req.Test.json(conn, %{"value" => "Alice"})

          {"GET", "/0/odata/Contact('1')/Name/$value"} ->
            Plug.Conn.send_resp(conn, 200, "Alice")

          {"GET", "/0/odata/Contact/$count"} ->
            Plug.Conn.send_resp(conn, 200, "5")

          {"POST", "/0/odata/Contact"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(201, ~s({"Id":"2"}))

          {"PATCH", "/0/odata/Contact('2')"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"PUT", "/0/odata/Contact('2')/Name"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"DELETE", "/0/odata/Contact('2')/Name"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"DELETE", "/0/odata/Contact('2')"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      client = Client.new(base_url: "https://telemetry.creatio.com", req_options: [plug: plug])

      assert {:ok, _} = OData.list(client, "Contact")
      assert {:ok, _} = OData.get(client, "Contact", "1")
      assert {:ok, _} = OData.get_navigation(client, "Contact", "1", "Account")
      assert {:ok, _} = OData.get_field(client, "Contact", "1", "Name")
      assert {:ok, _} = OData.get_field_value(client, "Contact", "1", "Name")
      assert {:ok, 5} = OData.count(client, "Contact")
      assert {:ok, _} = OData.create(client, "Contact", %{"Name" => "Bob"})
      assert :ok = OData.update(client, "Contact", "2", %{"Name" => "Bobby"})
      assert :ok = OData.update_field(client, "Contact", "2", "Name", "Bobby")
      assert :ok = OData.delete_field(client, "Contact", "2", "Name")
      assert :ok = OData.delete(client, "Contact", "2")

      events = drain_events()

      stop_actions =
        for {[:creatio, :odata, :stop], _meas, meta} <- events do
          assert meta.protocol == :odata4
          assert meta.entity == "Contact"
          assert meta.result == :ok
          meta.action
        end

      assert stop_actions == [
               :list,
               :get,
               :get_navigation,
               :get_field,
               :get_field_value,
               :count,
               :create,
               :update,
               :update_field,
               :delete_field,
               :delete
             ]
    end

    test "emits [:creatio, :odata3, *] across all OData 3 operations and read_only errors" do
      plug = fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection"} ->
            Req.Test.json(conn, %{"d" => %{"results" => [%{"Id" => "1"}]}})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')"} ->
            Req.Test.json(conn, %{"d" => %{"Id" => "1"}})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')/Account"} ->
            Req.Test.json(conn, %{"d" => %{"Id" => "a-1"}})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')/Name"} ->
            Req.Test.json(conn, %{"d" => %{"Name" => "Alice"}})

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection('1')/Name/$value"} ->
            Plug.Conn.send_resp(conn, 200, "Alice")

          {"GET", "/0/ServiceModel/EntityDataService.svc/ContactCollection/$count"} ->
            Plug.Conn.send_resp(conn, 200, "3")

          {"POST", "/0/ServiceModel/EntityDataService.svc/ContactCollection"} ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(201, Jason.encode!(%{"d" => %{"Id" => "2"}}))

          {"PATCH", "/0/ServiceModel/EntityDataService.svc/ContactCollection('2')"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"DELETE", "/0/ServiceModel/EntityDataService.svc/ContactCollection('2')"} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end

      client = Client.new(base_url: "https://telemetry.creatio.com", req_options: [plug: plug])

      assert {:ok, _} = OData3.list(client, "Contact")
      assert {:ok, _} = OData3.get(client, "Contact", "1")
      assert {:ok, _} = OData3.get_navigation(client, "Contact", "1", "Account")
      assert {:ok, _} = OData3.get_field(client, "Contact", "1", "Name")
      assert {:ok, _} = OData3.get_field_value(client, "Contact", "1", "Name")
      assert {:ok, 3} = OData3.count(client, "Contact")
      assert {:ok, _} = OData3.create(client, "Contact", %{"Name" => "Bob"})
      assert :ok = OData3.update(client, "Contact", "2", %{"Name" => "Bobby"})
      assert :ok = OData3.delete(client, "Contact", "2")

      events = drain_events()

      stop_actions =
        for {[:creatio, :odata3, :stop], _meas, meta} <- events do
          assert meta.protocol == :odata3
          assert meta.entity == "Contact"
          assert meta.result == :ok
          meta.action
        end

      assert stop_actions == [
               :list,
               :get,
               :get_navigation,
               :get_field,
               :get_field_value,
               :count,
               :create,
               :update,
               :delete
             ]

      _ = drain_events()

      ro_client = Client.new(base_url: "https://telemetry.creatio.com", read_only: true)
      assert {:error, %Error{code: "ReadOnlyMode"}} = OData.create(ro_client, "Contact", %{})
      assert_receive {:telemetry_event, [:creatio, :odata, :stop], _, o4_ro_meta}
      assert o4_ro_meta.action == :create
      assert o4_ro_meta.result == :error
    end
  end

  describe "domain spans for DataService, Auth, and Batch (Option 4)" do
    test "emits [:creatio, :data_service, *] for DataService queries and custom REST services" do
      plug = fn conn ->
        case conn.request_path do
          "/0/DataService/json/SyncReply/" <> _action ->
            Req.Test.json(conn, %{"success" => true, "rows" => []})

          "/0/rest/MySvc/Ping" ->
            Req.Test.json(conn, %{"pong" => true})
        end
      end

      client = Client.new(base_url: "https://telemetry.creatio.com", req_options: [plug: plug])

      assert {:ok, _} = DataService.select_query(client, %{"RootSchemaName" => "Account"})
      assert {:ok, _} = DataService.insert_query(client, %{"RootSchemaName" => "Contact"})
      assert {:ok, _} = DataService.update_query(client, %{"RootSchemaName" => "Contact"})
      assert {:ok, _} = DataService.delete_query(client, %{"RootSchemaName" => "Contact"})
      assert {:ok, _} = DataService.batch_query(client, %{"items" => []})
      assert {:ok, _} = DataService.custom_service(client, "MySvc", "Ping", method: :get)

      events = drain_events()

      ds_stops =
        for {[:creatio, :data_service, :stop], _meas, meta} <- events do
          {meta.action, meta[:entity], meta[:service], meta[:endpoint], meta.result}
        end

      assert ds_stops == [
               {"SelectQuery", "Account", nil, nil, :ok},
               {"InsertQuery", "Contact", nil, nil, :ok},
               {"UpdateQuery", "Contact", nil, nil, :ok},
               {"DeleteQuery", "Contact", nil, nil, :ok},
               {"BatchQuery", nil, nil, nil, :ok},
               {:custom_service, nil, "MySvc", "Ping", :ok}
             ]
    end

    test "emits [:creatio, :auth, *] without credential leakage for forms, oauth, health check, and openid" do
      plug = fn conn ->
        case conn.request_path do
          "/ServiceModel/AuthService.svc/Login" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            body = Jason.decode!(raw)

            if body["UserPassword"] == "good-pw-secret" do
              conn
              |> Plug.Conn.put_resp_header("set-cookie", "BPMCSRF=forms-csrf-secret; Path=/")
              |> Req.Test.json(%{"Code" => 0})
            else
              Req.Test.json(conn, %{"Code" => 1, "Message" => "Invalid credentials"})
            end

          "/connect/token" ->
            Req.Test.json(conn, %{"access_token" => "oauth-jwt-secret", "expires_in" => 3600})

          "/0/api/OAuthHealthCheck" ->
            Req.Test.json(conn, %{"HasProblem" => false})

          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{"issuer" => "https://id.telemetry.creatio.com"})
        end
      end

      client =
        Client.new(
          base_url: "https://telemetry.creatio.com",
          identity_service_url: "https://id.telemetry.creatio.com",
          client_id: "telemetry-client-id",
          client_secret: "telemetry-client-secret-999",
          req_options: [plug: plug]
        )

      assert {:ok, _} = Auth.login_forms(client, "Supervisor", "good-pw-secret")
      assert {:error, %Error{code: 1}} = Auth.login_forms(client, "Supervisor", "bad-pw-secret")
      assert {:ok, _, _} = Auth.login_oauth(client)
      assert {:ok, _} = Auth.oauth_health_check(client)
      assert {:ok, _} = Auth.openid_configuration(client)

      assert {:ok, _} =
               Auth.openid_configuration(
                 "https://id.telemetry.creatio.com/.well-known/openid-configuration",
                 req_options: [plug: plug]
               )

      assert {:error, %Error{}} =
               Auth.login_oauth(Client.new(base_url: "https://telemetry.creatio.com"))

      events = drain_events()

      for {_ev, _meas, meta} <- events do
        serialized = inspect(meta)
        refute serialized =~ "good-pw-secret"
        refute serialized =~ "bad-pw-secret"
        refute serialized =~ "forms-csrf-secret"
        refute serialized =~ "telemetry-client-secret-999"
        refute serialized =~ "oauth-jwt-secret"
      end

      auth_stops =
        for {[:creatio, :auth, :stop], _meas, meta} <- events do
          {meta.auth_mode, meta.result}
        end

      assert auth_stops == [
               {:forms, :ok},
               {:forms, :error},
               {:oauth, :ok},
               {:health_check, :ok},
               {:openid_configuration, :ok},
               {:openid_configuration, :ok},
               {:oauth, :error}
             ]
    end

    test "emits [:creatio, :batch, *] for JSON, multipart, raw binary, and ReadOnlyMode blocks" do
      plug = fn conn ->
        case conn.request_path do
          "/0/odata/$batch" ->
            Req.Test.json(conn, %{
              "responses" => [%{"id" => "req_1", "status" => 200, "body" => %{}}]
            })
        end
      end

      client = Client.new(base_url: "https://telemetry.creatio.com", req_options: [plug: plug])

      batch = Batch.new() |> Batch.add_get("Contact") |> Batch.add_get("Account")
      assert {:ok, _} = Batch.execute(client, batch)
      assert {:ok, _} = Batch.execute(client, batch, format: :multipart)

      raw_multipart =
        "--b_raw\r\nContent-Type: application/http\r\n\r\nGET Contact HTTP/1.1\r\n\r\n--b_raw--\r\n"

      assert {:ok, _} = Batch.execute(client, raw_multipart, boundary: "b_raw")

      ro_client = Client.new(base_url: "https://telemetry.creatio.com", read_only: true)
      mut_batch = Batch.new() |> Batch.add_create("Contact", %{"Name" => "Blocked"})
      assert {:error, %Error{code: "ReadOnlyMode"}} = Batch.execute(ro_client, mut_batch)

      events = drain_events()

      batch_stops =
        for {[:creatio, :batch, :stop], _meas, meta} <- events do
          {meta.format, meta.operation_count, meta.status, meta.result}
        end

      assert batch_stops == [
               {:json, 2, :ok, :ok},
               {:multipart, 2, :ok, :ok},
               {:multipart, 1, :ok, :ok},
               {:json, 1, :error, :error}
             ]
    end

    test "covers list header redaction, nested error/response sanitization, scalar spans, and origin formatting" do
      assert [
               {"authorization", "[REDACTED]"},
               {"cookie", nil},
               {"x-ok", "1"},
               :malformed
             ] =
               Telemetry.sanitize_headers([
                 {"authorization", "Bearer sec"},
                 {"cookie", nil},
                 {"x-ok", "1"},
                 :malformed
               ])

      assert Telemetry.sanitize_headers(:not_headers) == :not_headers
      assert Telemetry.sanitize_metadata(:not_a_map) == :not_a_map

      meta_with_nested = %{
        auth_token: nil,
        err_details: %Error{details: %{"password" => "sec", "ok" => 1}},
        err_resp: %Error{
          response: %Req.Response{
            status: 401,
            headers: %{"cookie" => ["sec"]},
            body: %{"auth_token" => "sec"}
          }
        },
        raw_resp: %Req.Response{
          status: 200,
          headers: %{"bpmcsrf" => ["sec"]},
          body: %{"client_secret" => "sec", "public" => "ok"}
        }
      }

      sanitized = Telemetry.sanitize_metadata(meta_with_nested)
      assert sanitized.auth_token == nil
      assert sanitized.err_details.details["password"] == "[REDACTED]"
      assert sanitized.err_details.details["ok"] == 1
      assert sanitized.err_resp.response.headers["cookie"] == ["[REDACTED]"]
      assert sanitized.err_resp.response.body["auth_token"] == "[REDACTED]"
      assert sanitized.raw_resp.headers["bpmcsrf"] == ["[REDACTED]"]
      assert sanitized.raw_resp.body["client_secret"] == "[REDACTED]"
      assert sanitized.raw_resp.body["public"] == "ok"

      assert :done = Telemetry.span(:odata, %{action: :custom}, fn -> :done end)
      assert_receive {:telemetry_event, [:creatio, :odata, :stop], _, %{result: :ok, status: :ok}}

      plug = fn conn -> Req.Test.json(conn, %{"value" => []}) end

      # from_req with read_only: true inserts telemetry step before read_only_guard; attach_req_steps is idempotent
      ro_req = Req.new(plug: plug)
      ro_client = Client.from_req(ro_req, read_only: true)
      idempotent_req = Telemetry.attach_req_steps(ro_client.req)

      assert Keyword.keys(idempotent_req.request_steps) |> Enum.count(&(&1 == :creatio_telemetry)) ==
               1

      assert ro_client.req.options |> Map.get(:plug) != nil

      # http://host:8080 and http://host (port 80) exercise origin formatting in request step
      http_client = Client.new(base_url: "http://crm.test:8080", req_options: [plug: plug])
      assert {:ok, []} = OData.list(http_client, "Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :stop], _,
                      %{base_url: "http://crm.test:8080"}}

      plain_req =
        Req.new(url: "http://crm.test/0/odata/Contact", plug: plug)
        |> Telemetry.attach_req_steps()

      assert {:ok, %Req.Response{status: 200}} = Req.get(plain_req)

      assert_receive {:telemetry_event, [:creatio, :request, :stop], _,
                      %{base_url: "http://crm.test"}}
    end
  end

  describe "pre-1.0 security and metadata hardening" do
    test "redacts both response and details on Creatio.Error as well as lists and keyword lists" do
      err_both = %Error{
        status: 401,
        message: "Unauthorized",
        response: %Req.Response{
          status: 401,
          headers: %{"authorization" => ["Bearer secret-hdr"]},
          body: %{
            "refresh_token" => "secret-refresh",
            "errors" => [%{"client_secret" => "nested-sec"}, [bpmcsrf: "kw-csrf"]]
          }
        },
        details: %{
          "access_token" => "secret-detail",
          "items" => [%{"password" => "p1"}, %{"safe" => "ok"}],
          "kw" => [bearer_token: "secret-bt", label: "keep"]
        }
      }

      sanitized = Telemetry.sanitize_metadata(%{error: err_both})

      assert sanitized.error.response.headers["authorization"] == ["[REDACTED]"]
      assert sanitized.error.response.body["refresh_token"] == "[REDACTED]"

      assert [%{"client_secret" => "[REDACTED]"}, [bpmcsrf: "[REDACTED]"]] =
               sanitized.error.response.body["errors"]

      assert sanitized.error.details["access_token"] == "[REDACTED]"

      assert [%{"password" => "[REDACTED]"}, %{"safe" => "ok"}] =
               sanitized.error.details["items"]

      assert sanitized.error.details["kw"] == [bearer_token: "[REDACTED]", label: "keep"]
    end

    test "falls back to request URL origin when Client.from_req leaves base_url empty" do
      plug = fn conn -> Req.Test.json(conn, %{"value" => []}) end

      client = Client.from_req(Req.new(plug: plug))
      assert client.base_url == ""

      assert {:ok, %Req.Response{status: 200}} =
               Req.get(client.req, url: "http://fallback.test:8443/0/odata/Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :stop], _,
                      %{base_url: "http://fallback.test:8443"}}
    end

    test "reports Identity Service origin (with port) and auth_mode for OAuth and OIDC discovery" do
      plug = fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            Req.Test.json(conn, %{"issuer" => "http://ids.example.com:8443"})

          "/connect/token" ->
            Req.Test.json(conn, %{
              "access_token" => "tok-123",
              "token_type" => "Bearer",
              "expires_in" => 3600
            })
        end
      end

      client =
        Client.new(
          base_url: "https://crm.example.com",
          identity_service_url: "http://ids.example.com:8443",
          client_id: "cid",
          client_secret: "csec",
          bearer_token: "old-bearer",
          req_options: [plug: plug]
        )

      assert {:ok, %{"issuer" => _}} = Auth.openid_configuration(client)

      assert_receive {:telemetry_event, [:creatio, :request, :stop], _,
                      %{
                        base_url: "http://ids.example.com:8443",
                        auth_mode: :openid_configuration
                      }}

      drain_events()

      assert {:ok, _updated, _tok} = Auth.login_oauth(client)

      assert_receive {:telemetry_event, [:creatio, :request, :stop], _,
                      %{base_url: "http://ids.example.com:8443", auth_mode: :oauth}}
    end

    test "Batch.execute/3 emits batch telemetry spans for list and map payloads" do
      plug = fn conn ->
        Req.Test.json(conn, %{
          "responses" => [%{"id" => "1", "status" => 200, "body" => %{"value" => []}}]
        })
      end

      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      assert {:ok, [%{id: "1"}]} =
               Batch.execute(client, [%{method: "GET", url: "Contact"}])

      assert_receive {:telemetry_event, [:creatio, :batch, :start], _, _}
      assert_receive {:telemetry_event, [:creatio, :batch, :stop], _, %{result: :ok}}

      drain_events()

      assert {:ok, [%{id: "1"}]} =
               Batch.execute(client, %{
                 "requests" => [%{"id" => "1", "method" => "GET", "url" => "Contact"}]
               })

      assert_receive {:telemetry_event, [:creatio, :batch, :start], _, _}
      assert_receive {:telemetry_event, [:creatio, :batch, :stop], _, %{result: :ok}}
    end

    test "all 5 domain :exception events emit documented metadata and redact secrets" do
      sensitive_client =
        Client.new(
          base_url: "https://crm.example.com",
          client_id: "cid-public",
          client_secret: "super-secret-client-secret",
          auth_token: "super-secret-bearer"
        )

      for domain <- [:odata, :odata3, :data_service, :auth, :batch] do
        drain_events()

        assert_raise Error, fn ->
          Telemetry.span(domain, %{operation: :test_op, auth_token: "tok-leak"}, fn ->
            # Capture sensitive_client inside exception struct to verify recursive redaction
            raise Error,
              status: 500,
              message: "Authorization: Bearer raw-jwt-secret; BPMCSRF=csrf-leak",
              details: %{client: sensitive_client, client_secret: "nested-secret"}
          end)
        end

        assert_receive {:telemetry_event, [:creatio, ^domain, :start], _, start_meta}
        refute Map.has_key?(start_meta, :auth_token) and start_meta.auth_token == "tok-leak"

        assert_receive {:telemetry_event, [:creatio, ^domain, :exception], measurements, meta}
        assert is_integer(measurements.duration) and measurements.duration >= 0
        assert meta.result == :error
        assert meta.status == :error
        assert meta.kind == :error
        assert meta.reason == meta.error
        assert is_struct(meta.error, Error)
        refute meta.error.message =~ "raw-jwt-secret"
        refute meta.error.message =~ "csrf-leak"
        assert meta.error.message =~ "[REDACTED]"
        assert meta.error.details.client.client_secret == "[REDACTED]"
        assert meta.error.details.client.auth_token == "[REDACTED]"
        assert meta.error.details.client_secret == "[REDACTED]"

        for {_m, _f, a, _loc} <- meta.stacktrace do
          refute is_list(a)
        end
      end
    end

    test "Batch.execute/3 emits [:creatio, :batch, :exception] when list normalization fails inside span" do
      client = Client.new(base_url: "https://crm.test")
      drain_events()

      assert_raise FunctionClauseError, fn ->
        Batch.execute(client, [:not_a_map])
      end

      assert_receive {:telemetry_event, [:creatio, :batch, :start], _, _}

      assert_receive {:telemetry_event, [:creatio, :batch, :exception], _,
                      %{
                        result: :error,
                        status: :error,
                        error: :function_clause,
                        kind: :error
                      }}
    end

    test "Req retries close every [:creatio, :request, :start] with a matching :stop event" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      plug = fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(503, ~s({"error":"temporarily unavailable"}))
        else
          Req.Test.json(conn, %{"value" => [%{"Id" => "1"}]})
        end
      end

      client =
        Client.new(
          base_url: "https://crm.test",
          req_options: [plug: plug, retry: :transient, retry_delay: fn _ -> 0 end, max_retries: 2]
        )

      drain_events()
      assert {:ok, [%{"Id" => "1"}]} = OData.list(client, "Contact")

      events = drain_events()
      starts = Enum.filter(events, fn {ev, _, _} -> ev == [:creatio, :request, :start] end)
      stops = Enum.filter(events, fn {ev, _, _} -> ev == [:creatio, :request, :stop] end)

      assert length(starts) == 2
      assert length(stops) == 2
    end

    test "issue 6: emits monotonic_time, avoids unpaired stop/exception on earlier step halt, handles nil URL, and tracks batch error_count" do
      plug = fn conn -> Req.Test.json(conn, %{"value" => []}) end
      client = Client.new(base_url: "https://crm.test", req_options: [plug: plug])

      drain_events()
      assert {:ok, []} = OData.list(client, "Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :start], start_meas, _}
      assert is_integer(start_meas.monotonic_time)
      assert is_integer(start_meas.system_time)

      assert_receive {:telemetry_event, [:creatio, :request, :stop], stop_meas, _}
      assert is_integer(stop_meas.monotonic_time)
      assert is_integer(stop_meas.duration)

      # Pre-step halting before :creatio_telemetry runs must not emit unpaired :stop or :exception
      halting_req =
        Req.new(base_url: "https://crm.test", url: "/0/odata/Contact", plug: plug)
        |> Telemetry.attach_req_steps()
        |> Req.Request.prepend_request_steps(
          early_cache_halt: fn r ->
            Req.Request.halt(r, %Req.Response{status: 200, body: %{"cached" => true}})
          end
        )

      drain_events()
      assert {:ok, %Req.Response{status: 200}} = Req.get(halting_req)
      assert drain_events() == []

      err_halting_req =
        Req.new(base_url: "https://crm.test", url: "/0/odata/Contact", plug: plug)
        |> Telemetry.attach_req_steps()
        |> Req.Request.prepend_request_steps(
          early_fail_halt: fn r ->
            Req.Request.halt(r, RuntimeError.exception("early failure"))
          end
        )

      assert {:error, %RuntimeError{message: "early failure"}} = Req.get(err_halting_req)
      assert drain_events() == []

      # Direct handle_req_stop on nil URL without prior start emits no unpaired telemetry and doesn't crash
      nil_url_req = Req.new()

      assert {^nil_url_req, %Req.Response{status: 200}} =
               Telemetry.handle_req_stop({nil_url_req, %Req.Response{status: 200}})

      assert drain_events() == []

      # extract_path handles nil url during handle_req_start -> handle_req_stop
      started_nil = Telemetry.handle_req_start(nil_url_req)
      assert {rearmed, _} = Telemetry.handle_req_stop({started_nil, %Req.Response{status: 200}})
      refute Map.has_key?(rearmed.private, :creatio_telemetry_start)
      assert_receive {:telemetry_event, [:creatio, :request, :start], _, %{path: "/"}}
      assert_receive {:telemetry_event, [:creatio, :request, :stop], _, %{path: "/"}}

      # Batch sub-request failures set status: :error, result: :error, error_count: N
      batch_err_plug = fn conn ->
        Req.Test.json(conn, %{
          "responses" => [
            %{"id" => "req_1", "status" => 200, "body" => %{}},
            %{
              "id" => "req_2",
              "status" => 500,
              "body" => %{"error" => %{"message" => "sub fail"}}
            }
          ]
        })
      end

      batch_client = Client.new(base_url: "https://crm.test", req_options: [plug: batch_err_plug])
      drain_events()

      assert {:ok, _} = Batch.execute(batch_client, Batch.new() |> Batch.add_get("Contact"))

      assert_receive {:telemetry_event, [:creatio, :batch, :stop], _,
                      %{
                        result: :error,
                        status: :error,
                        error_count: 1,
                        error: %Error{status: 500}
                      }}

      # Redacts Elixir inspect => syntax, escaped quotes inside JSON strings, and caps huge response bodies
      inspect_str =
        ~s(%{"client_secret" => "sec\\"123", "cookie" => "c=1", "password" => "p\\"w"})

      huge_body =
        "Bearer tok-123 " <> String.duplicate("A", 10_000) <> "password=should_be_truncated"

      sanitized_edge =
        Telemetry.sanitize_metadata(%{
          msg: inspect_str,
          err: Error.from_response(%Req.Response{status: 500, body: huge_body})
        })

      assert sanitized_edge.msg =~ ~s("client_secret" => "[REDACTED]")
      assert sanitized_edge.msg =~ ~s("cookie" => "[REDACTED]")
      assert sanitized_edge.msg =~ ~s("password" => "[REDACTED]")
      refute sanitized_edge.msg =~ "123"
      refute sanitized_edge.msg =~ "p\\\"w"
      assert sanitized_edge.err.response.body =~ "Bearer [REDACTED]"
      assert sanitized_edge.err.response.body =~ "[TRUNCATED"
    end

    test "sanitizes URI secrets, Req.Request url/private, and non-exception structs" do
      uri =
        URI.parse(
          "https://user:secret@mycreatio.com/0/odata/Contact?access_token=abc#bpmcsrf=xyz"
        )

      req =
        Req.new(url: uri, headers: %{"authorization" => "Bearer topsecret"})
        |> Req.Request.put_private(:custom_secret, "s3cr3t")

      batch_resp = %Creatio.Batch.Response{
        id: "1",
        status: 200,
        headers: %{"set-cookie" => "S=1"},
        body: %{"ok" => true}
      }

      conn = %Plug.Conn{req_headers: [{"authorization", "Bearer conn-tok"}, {"x-ok", "yes"}]}

      sanitized =
        Telemetry.sanitize_metadata(%{
          uri: uri,
          req: req,
          batch_resp: batch_resp,
          conn: conn
        })

      assert sanitized.uri.userinfo == "[REDACTED]"
      refute to_string(sanitized.uri) =~ "access_token=abc"
      refute to_string(sanitized.uri) =~ "bpmcsrf=xyz"
      assert sanitized.uri.query =~ "REDACTED"
      assert sanitized.uri.fragment =~ "REDACTED"

      assert sanitized.req.private == %{redacted: true}
      refute to_string(sanitized.req.url) =~ "secret"

      assert Enum.any?(
               sanitized.req.headers["authorization"],
               &String.contains?(&1, "[REDACTED]")
             )

      assert sanitized.batch_resp.headers == %{"set-cookie" => "[REDACTED]"}

      assert Enum.find(sanitized.conn.req_headers, &(elem(&1, 0) == "authorization")) ==
               {"authorization", "[REDACTED]"}

      assert Enum.find(sanitized.conn.req_headers, &(elem(&1, 0) == "x-ok")) == {"x-ok", "yes"}
    end

    test "redacts .ASPXAUTH cookies, string-keyed tuple lists, and handles improper lists safely" do
      err = %Error{
        status: 401,
        message: "\".ASPXAUTH=secret-aspx-cookie; BPMLOADER=secret-loader\"",
        details: [
          {"client_secret", "tuple-secret"},
          {"bpmcsrf", "tuple-csrf"},
          [:improper_head | :improper_tail]
        ],
        response: %Req.Response{
          status: 401,
          body: [1 | :improper_resp_tail]
        }
      }

      sanitized = Telemetry.sanitize_metadata(%{error: err})

      refute sanitized.error.message =~ "secret-aspx-cookie"
      refute sanitized.error.message =~ "secret-loader"
      assert sanitized.error.message =~ ".ASPXAUTH=[REDACTED]"
      assert sanitized.error.message =~ "BPMLOADER=[REDACTED]"

      assert [
               {"client_secret", "[REDACTED]"},
               {"bpmcsrf", "[REDACTED]"},
               [:improper_head | :improper_tail]
             ] = sanitized.error.details

      assert sanitized.error.response.body == [1 | :improper_resp_tail]

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span(:odata, %{action: :test}, fn ->
          raise RuntimeError, "boom"
        end)
      end

      assert_receive {:telemetry_event, [:creatio, :odata, :exception], _, _}
    end

    test "request telemetry runs after encode_body and put_base_url (no orphaned :start on EncodeError, virtual dir path matches)" do
      plug = fn conn -> Req.Test.json(conn, %{"value" => []}) end

      client =
        Client.new(
          base_url: "https://crm.test/creatio",
          req_options: [plug: plug]
        )

      drain_events()

      assert {:ok, []} = OData.list(client, "Contact")

      assert_receive {:telemetry_event, [:creatio, :request, :start], _, start_meta}
      assert_receive {:telemetry_event, [:creatio, :request, :stop], _, stop_meta}
      assert start_meta.path == "/creatio/0/odata/Contact"
      assert stop_meta.path == "/creatio/0/odata/Contact"

      drain_events()

      assert_raise Jason.EncodeError, fn ->
        Req.post(client.req, url: "/0/odata/Contact", json: %{bad: <<0xFF>>})
      end

      events = drain_events()
      refute Enum.any?(events, fn {ev, _, _} -> ev == [:creatio, :request, :start] end)
    end
  end
end
