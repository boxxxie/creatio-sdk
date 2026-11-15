defmodule Creatio.LiveHelper do
  @moduledoc false

  alias Creatio.{Auth, Client, Error, OData}

  @spec base_url() :: String.t() | nil
  def base_url do
    case System.get_env("CREATIO_BASE_URL") do
      val when is_binary(val) ->
        trimmed = val |> String.trim() |> String.trim_trailing("/")
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  @spec identity_url() :: String.t() | nil
  def identity_url do
    val =
      System.get_env("CREATIO_IDENTITY_URL") ||
        System.get_env("CREATIO_IDENTITY_SERVICE_URL")

    case val do
      url when is_binary(url) ->
        trimmed = url |> String.trim() |> String.trim_trailing("/")
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  @spec live_entity() :: String.t()
  def live_entity do
    case System.get_env("CREATIO_LIVE_ENTITY") do
      val when is_binary(val) and val != "" -> String.trim(val)
      _ -> "Contact"
    end
  end

  @spec mutations_allowed?() :: boolean()
  def mutations_allowed? do
    System.get_env("CREATIO_LIVE_ALLOW_MUTATIONS") in ["true", "TRUE", "1"]
  end

  @spec strict_live?() :: boolean()
  def strict_live? do
    System.get_env("CREATIO_LIVE_STRICT") in ["true", "TRUE", "1"]
  end

  @spec oauth_configured?() :: boolean()
  def oauth_configured? do
    non_empty?(base_url()) and
      non_empty?(System.get_env("CREATIO_CLIENT_ID")) and
      non_empty?(System.get_env("CREATIO_CLIENT_SECRET"))
  end

  @spec forms_configured?() :: boolean()
  def forms_configured? do
    non_empty?(base_url()) and
      non_empty?(System.get_env("CREATIO_USERNAME")) and
      non_empty?(System.get_env("CREATIO_PASSWORD"))
  end

  @spec bearer_configured?() :: boolean()
  def bearer_configured? do
    token = System.get_env("CREATIO_BEARER_TOKEN") || System.get_env("CREATIO_AUTH_TOKEN")
    non_empty?(base_url()) and non_empty?(token)
  end

  @doc """
  Connects (or reuses a cached session) for live verification tests.

  By default, enforces `read_only: true` unless `mutable: true` is passed AND
  `CREATIO_LIVE_ALLOW_MUTATIONS=true`. When credentials are absent or the endpoint
  is gated by a transport error or Imperva Incapsula WAF HTML challenge, skips
  gracefully (unless `CREATIO_LIVE_STRICT=true`, which fails the test).
  """
  @spec connect_live_client(keyword()) :: {:ok, Client.t()} | {:skip, String.t()}
  def connect_live_client(opts \\ []) do
    requested_auth = Keyword.get(opts, :auth, :auto)
    mutable? = Keyword.get(opts, :mutable, false) and mutations_allowed?()

    case resolve_auth_mode(requested_auth) do
      {:error, reason} ->
        handle_skip(reason)

      {:ok, mode} ->
        connect_cached_session(mode, not mutable?)
    end
  end

  @doc """
  Runs `fun` with an authenticated live client, skipping cleanly when unavailable.
  """
  @spec with_live_client(keyword(), (Client.t() -> any())) :: any()
  def with_live_client(opts \\ [], fun) when is_function(fun, 1) do
    case connect_live_client(opts) do
      {:ok, client} ->
        try do
          fun.(client)
        catch
          :throw, {:creatio_live_skip, _reason} -> :ok
        end

      {:skip, _reason} ->
        :ok
    end
  end

  @doc """
  Registers deterministic `on_exit/1` record cleanup for opt-in mutation tests.
  """
  @spec register_cleanup(Client.t(), String.t(), String.t() | nil) :: :ok
  def register_cleanup(_client, _entity, nil), do: :ok

  def register_cleanup(%Client{} = client, entity, record_id) when is_binary(record_id) do
    cleanup_client = build_mutable_cleanup_client(client)

    ExUnit.Callbacks.on_exit(fn ->
      case OData.delete(cleanup_client, entity, record_id) do
        :ok ->
          :ok

        {:error, %Error{status: 404}} ->
          :ok

        {:error, %Error{} = err} ->
          IO.puts(
            :stderr,
            "\n[live cleanup warning] Failed to delete #{entity}(#{record_id}): #{Exception.message(err)}"
          )
      end
    end)

    :ok
  end

  @doc """
  Returns `true` when an error represents a WAF HTML interstitial (such as Imperva Incapsula)
  or a transport-level connection failure rather than a protocol bug.
  """
  @spec waf_or_network_error?(Error.t()) :: boolean()
  def waf_or_network_error?(%Error{
        status: status,
        message: msg,
        details: details,
        response: resp
      }) do
    raw =
      [msg, safe_details_text(details), safe_response_body(resp)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    html_waf? =
      status in [200, 403, 503] and
        (String.contains?(raw, "<!doctype html") or
           String.contains?(raw, "<html") or
           String.contains?(raw, "<iframe"))

    waf_or_html? = String.contains?(raw, "_incapsula_resource") or html_waf?

    transport? = is_nil(status) and is_exception(details)
    waf_or_html? or transport?
  end

  @doc """
  Handles an unexpected WAF/network skip on secondary live endpoints during a test.
  """
  @spec skip_or_fail!(Error.t(), String.t()) :: no_return()
  def skip_or_fail!(%Error{} = error, context) do
    if waf_or_network_error?(error) do
      {:skip, reason} = handle_skip("#{context}: #{format_skip_error(error)}")
      throw({:creatio_live_skip, reason})
    else
      ExUnit.Assertions.flunk("#{context} failed: #{Exception.message(error)}")
    end
  end

  defp resolve_auth_mode(:auto) do
    cond do
      oauth_configured?() ->
        {:ok, :oauth}

      bearer_configured?() ->
        {:ok, :bearer}

      forms_configured?() ->
        {:ok, :forms}

      true ->
        {:error,
         "No live Creatio credentials configured in env (set CREATIO_BASE_URL + OAuth or Forms credentials)"}
    end
  end

  defp resolve_auth_mode(:oauth) do
    if oauth_configured?() do
      {:ok, :oauth}
    else
      {:error, "OAuth credentials (CREATIO_CLIENT_ID / CREATIO_CLIENT_SECRET) not configured"}
    end
  end

  defp resolve_auth_mode(:forms) do
    if forms_configured?() do
      {:ok, :forms}
    else
      {:error, "Forms credentials (CREATIO_USERNAME / CREATIO_PASSWORD) not configured"}
    end
  end

  defp resolve_auth_mode(:bearer) do
    if bearer_configured?() do
      {:ok, :bearer}
    else
      {:error, "Bearer token (CREATIO_BEARER_TOKEN / CREATIO_AUTH_TOKEN) not configured"}
    end
  end

  defp connect_cached_session(mode, read_only?) do
    cache_key = {__MODULE__, {:session, mode}}

    case :persistent_term.get(cache_key, nil) do
      {:ok, cached_client} ->
        {:ok, with_read_only(cached_client, read_only?)}

      {:skip, reason} ->
        handle_skip(reason)

      nil ->
        result = authenticate_fresh(mode)
        :persistent_term.put(cache_key, result)

        case result do
          {:ok, client} -> {:ok, with_read_only(client, read_only?)}
          {:skip, reason} -> handle_skip(reason)
        end
    end
  end

  defp authenticate_fresh(:oauth) do
    base = base_url()
    id_url = identity_url() || "#{base}/identity"

    client =
      Client.new(
        base_url: base,
        identity_service_url: id_url,
        client_id: System.get_env("CREATIO_CLIENT_ID"),
        client_secret: System.get_env("CREATIO_CLIENT_SECRET"),
        read_only: true
      )

    case Auth.login_oauth(client) do
      {:ok, authed_client, _token} ->
        {:ok, authed_client}

      {:error, %Error{} = error} ->
        {:skip, "OAuth2 live authentication unavailable: #{format_skip_error(error)}"}
    end
  end

  defp authenticate_fresh(:forms) do
    client = Client.new(base_url: base_url(), read_only: true)
    username = System.get_env("CREATIO_USERNAME")
    password = System.get_env("CREATIO_PASSWORD")

    case Auth.login_forms(client, username, password) do
      {:ok, authed_client} ->
        {:ok, authed_client}

      {:error, %Error{} = error} ->
        {:skip, "Forms live authentication unavailable: #{format_skip_error(error)}"}
    end
  end

  defp authenticate_fresh(:bearer) do
    token = System.get_env("CREATIO_BEARER_TOKEN") || System.get_env("CREATIO_AUTH_TOKEN")
    client = Client.new(base_url: base_url(), auth_token: token, read_only: true)
    {:ok, client}
  end

  defp with_read_only(%Client{} = client, read_only?) do
    auth_opts =
      case client.auth_mode do
        :bearer -> [auth_token: client.auth_token]
        :forms -> [cookie: client.cookie, bpmcsrf: client.bpmcsrf]
        _ -> []
      end

    opts =
      client.options
      |> Keyword.merge(
        base_url: client.base_url,
        identity_service_url: client.identity_service_url,
        client_id: client.client_id,
        client_secret: client.client_secret,
        auth_mode: client.auth_mode,
        read_only: read_only?
      )
      |> Keyword.merge(auth_opts)

    Client.from_req(client.req, opts)
  end

  defp build_mutable_cleanup_client(%Client{} = client), do: with_read_only(client, false)

  @doc """
  Logs a live-suite skip diagnostic once per unique reason.
  """
  @spec log_skip_once(String.t()) :: :ok
  def log_skip_once(reason) when is_binary(reason) do
    key = {__MODULE__, :logged_skips}
    seen = :persistent_term.get(key, MapSet.new())

    if not MapSet.member?(seen, reason) do
      :persistent_term.put(key, MapSet.put(seen, reason))
      IO.puts(:stderr, "\n[live skipped] #{reason}")
    end

    :ok
  end

  defp handle_skip(reason) do
    if strict_live?() do
      ExUnit.Assertions.flunk(reason)
    else
      log_skip_once(reason)
      {:skip, reason}
    end
  end

  defp format_skip_error(%Error{status: status, message: msg, details: details, response: resp}) do
    body_text = safe_response_body(resp) || ""

    cond do
      String.contains?(String.downcase(body_text <> (msg || "")), "_incapsula_resource") ->
        "blocked by Imperva Incapsula WAF challenge (HTTP #{status || "unknown"})"

      waf_or_network_error?(%Error{
        status: status,
        message: msg,
        details: details,
        response: resp
      }) ->
        "blocked by HTML interstitial or network error (HTTP #{status || "none"})"

      true ->
        "HTTP #{status || "unknown"} - #{String.slice(msg || "error", 0, 140)}"
    end
  end

  defp safe_details_text(ex) when is_exception(ex), do: Exception.message(ex)
  defp safe_details_text(_), do: nil

  defp safe_response_body(%Req.Response{body: body}) when is_binary(body), do: body
  defp safe_response_body(_), do: nil

  defp non_empty?(val) when is_binary(val), do: String.trim(val) != ""
  defp non_empty?(_), do: false
end
