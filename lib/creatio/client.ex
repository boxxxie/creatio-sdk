defmodule Creatio.Client do
  @moduledoc """
  Client struct and configuration for communicating with Creatio CRM APIs.

  Wraps a `Req.Request` pre-configured with the base URL, authentication headers,
  read-only safety guards, and content negotiation required by Creatio.
  """

  alias Creatio.{Telemetry, Util}

  @sensitive_option_keys [
    :auth_token,
    :bearer_token,
    :cookie,
    :bpmcsrf,
    :client_secret,
    :password,
    :user_password
  ]

  @known_string_option_keys %{
    "base_url" => :base_url,
    "auth_token" => :auth_token,
    "bearer_token" => :bearer_token,
    "auth_mode" => :auth_mode,
    "cookie" => :cookie,
    "bpmcsrf" => :bpmcsrf,
    "identity_service_url" => :identity_service_url,
    "client_id" => :client_id,
    "client_secret" => :client_secret,
    "password" => :password,
    "user_password" => :user_password,
    "read_only" => :read_only,
    "req_options" => :req_options,
    "token_url" => :token_url
  }

  @derive {Inspect, only: [:base_url, :auth_mode, :identity_service_url, :client_id, :read_only]}
  @enforce_keys [:base_url]
  defstruct [
    :base_url,
    :auth_token,
    :auth_mode,
    :cookie,
    :bpmcsrf,
    :identity_service_url,
    :client_id,
    :client_secret,
    :req,
    read_only: false,
    options: []
  ]

  @type t :: %__MODULE__{
          base_url: String.t(),
          auth_token: String.t() | nil,
          auth_mode: :none | :bearer | :forms | nil,
          cookie: String.t() | nil,
          bpmcsrf: String.t() | nil,
          identity_service_url: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          req: Req.Request.t(),
          read_only: boolean(),
          options: keyword()
        }

  @doc """
  Creates a new `Creatio.Client`.

  Can accept a keyword list of options, a map of options, or an existing `Req.Request`.

  ## Options

    * `:base_url` - The base URL of your Creatio instance (e.g., `"https://myinstance.creatio.com"`).
    * `:auth_token` - An OAuth 2.0 Bearer access token.
    * `:cookie` - Cookie string for Forms authentication (e.g. `".ASPXAUTH=...; BPMLOADER=..."`).
    * `:bpmcsrf` - The BPMCSRF token for Forms authentication.
    * `:identity_service_url` - Identity service base URL for OAuth 2.0.
    * `:client_id` - OAuth 2.0 client ID.
    * `:client_secret` - OAuth 2.0 client secret.
    * `:read_only` - If `true`, enables defense-in-depth read-only mode to prevent mutation requests (defaults to `false`, or `Application.get_env(:creatio, :read_only)`, or `CREATIO_READ_ONLY` env var).
    * `:req_options` - Extra keyword options forwarded to `Req.new/1` (e.g. `:plug`, `:retry`, etc.).
  """
  @spec new(keyword() | map() | Req.Request.t()) :: t()
  def new(opts \\ [])
  def new(%Req.Request{} = req), do: from_req(req)
  def new(opts) when is_map(opts), do: opts |> normalize_opts_list() |> new()

  def new(opts) when is_list(opts) do
    opts_list = normalize_opts_list(opts)

    base_url =
      (Keyword.get(opts_list, :base_url) ||
         Application.get_env(:creatio, :base_url) ||
         System.get_env("CREATIO_BASE_URL") ||
         "")
      |> String.trim_trailing("/")

    cookie = Keyword.get(opts_list, :cookie)
    bpmcsrf = Keyword.get(opts_list, :bpmcsrf)
    auth_token = resolve_auth_token(opts_list, cookie, bpmcsrf)

    identity_service_url =
      (Keyword.get(opts_list, :identity_service_url) ||
         Application.get_env(:creatio, :identity_service_url) ||
         System.get_env("CREATIO_IDENTITY_URL") ||
         System.get_env("CREATIO_IDENTITY_SERVICE_URL"))
      |> normalize_optional_url()

    client_id =
      Keyword.get(opts_list, :client_id) ||
        Application.get_env(:creatio, :client_id) ||
        System.get_env("CREATIO_CLIENT_ID")

    client_secret =
      Keyword.get(opts_list, :client_secret) ||
        Application.get_env(:creatio, :client_secret) ||
        System.get_env("CREATIO_CLIENT_SECRET")

    req_options =
      case Keyword.get(opts_list, :req_options, []) do
        nil -> []
        val -> Util.to_keyword_opts(val)
      end

    read_only = resolve_read_only(opts_list)

    auth_mode =
      cond do
        auth_token -> :bearer
        cookie || bpmcsrf -> :forms
        true -> :none
      end

    base_opts = if base_url != "", do: [base_url: base_url], else: []

    req =
      base_opts
      |> Keyword.merge(req_options)
      |> Req.new()
      |> put_header_if_absent("accept", "application/json; odata.metadata=minimal")
      |> put_header_if_absent("forceusesession", "true")

    client = %__MODULE__{
      base_url: base_url,
      auth_token: auth_token,
      auth_mode: auth_mode,
      cookie: cookie,
      bpmcsrf: bpmcsrf,
      identity_service_url: identity_service_url,
      client_id: client_id,
      client_secret: client_secret,
      read_only: read_only,
      options: sanitize_stored_options(opts_list),
      req: req
    }

    apply_auth_headers(client)
  end

  @doc """
  Builds a `Creatio.Client` from an existing `Req.Request`.

  Uses `:base_url` from `opts` if provided, falling back to `req.options[:base_url]`
  or `""`. Unlike `new/1`, does not read `CREATIO_BASE_URL` or `CREATIO_READ_ONLY`
  from the environment or application config.
  """
  @spec from_req(Req.Request.t(), keyword() | map()) :: t()
  def from_req(%Req.Request{} = req, opts \\ []) do
    opts_list = normalize_opts_list(opts)

    base_url =
      Keyword.get(opts_list, :base_url) || req.options[:base_url] || ""

    auth_token = Keyword.get(opts_list, :auth_token) || Keyword.get(opts_list, :bearer_token)
    cookie = Keyword.get(opts_list, :cookie)
    bpmcsrf = Keyword.get(opts_list, :bpmcsrf)

    read_only =
      case Keyword.fetch(opts_list, :read_only) do
        {:ok, val} when not is_nil(val) -> normalize_read_only(val)
        _ -> Keyword.has_key?(req.request_steps, :read_only_guard)
      end

    auth_mode =
      Keyword.get_lazy(opts_list, :auth_mode, fn ->
        cond do
          auth_token || Req.Request.get_header(req, "authorization") != [] -> :bearer
          cookie || bpmcsrf || Req.Request.get_header(req, "cookie") != [] -> :forms
          true -> :none
        end
      end)

    trimmed_base = String.trim_trailing(base_url, "/")

    configured_req =
      req
      |> maybe_put_base_url(trimmed_base)
      |> put_header_if_absent("accept", "application/json; odata.metadata=minimal")
      |> put_header_if_absent("forceusesession", "true")

    client = %__MODULE__{
      base_url: trimmed_base,
      auth_token: auth_token,
      auth_mode: auth_mode,
      cookie: cookie,
      bpmcsrf: bpmcsrf,
      identity_service_url:
        opts_list |> Keyword.get(:identity_service_url) |> normalize_optional_url(),
      client_id: Keyword.get(opts_list, :client_id),
      client_secret: Keyword.get(opts_list, :client_secret),
      read_only: read_only,
      req: configured_req,
      options: sanitize_stored_options(opts_list)
    }

    apply_auth_headers(client)
  end

  defp maybe_put_base_url(req, ""), do: req

  defp maybe_put_base_url(req, base_url) do
    if req.options[:base_url] == base_url do
      req
    else
      Req.Request.put_option(req, :base_url, base_url)
    end
  end

  @doc """
  Ensures that the input is a `%Creatio.Client{}`, converting a `%Req.Request{}` if necessary.
  """
  @spec ensure_client(t() | Req.Request.t()) :: t()
  def ensure_client(%__MODULE__{} = client), do: client
  def ensure_client(%Req.Request{} = req), do: from_req(req)

  @doc """
  Sets an OAuth 2.0 Bearer token on the client, clearing any prior Forms auth credentials.
  """
  @spec put_bearer_token(t(), String.t()) :: t()
  def put_bearer_token(%__MODULE__{} = client, token) when is_binary(token) do
    if String.trim(token) == "" do
      raise ArgumentError, "expected non-empty bearer token binary"
    end

    client = %{client | auth_token: token, auth_mode: :bearer, cookie: nil, bpmcsrf: nil}
    apply_auth_headers(client)
  end

  def put_bearer_token(%__MODULE__{}, token) do
    raise ArgumentError, "expected non-empty bearer token binary, got: #{inspect(token)}"
  end

  @doc """
  Sets Forms authentication cookies and BPMCSRF token on the client, clearing any prior Bearer token.
  """
  @spec put_forms_auth(t(), String.t(), String.t() | nil) :: t()
  def put_forms_auth(%__MODULE__{} = client, cookie, bpmcsrf \\ nil) when is_binary(cookie) do
    client = %{client | cookie: cookie, bpmcsrf: bpmcsrf, auth_mode: :forms, auth_token: nil}
    apply_auth_headers(client)
  end

  @doc """
  Sets a custom header on the client's underlying `Req.Request`.
  """
  @spec put_header(t(), String.t(), String.t()) :: t()
  def put_header(%__MODULE__{req: req} = client, name, value) do
    %{client | req: Req.Request.put_header(req, name, value)}
  end

  @doc """
  Returns the underlying configured `Req.Request` from the client.
  """
  @spec to_req(t()) :: Req.Request.t()
  def to_req(%__MODULE__{req: req}), do: req

  defp resolve_auth_token(opts_list, cookie, bpmcsrf) do
    case Keyword.fetch(opts_list, :auth_token) do
      {:ok, val} ->
        val

      :error ->
        case Keyword.fetch(opts_list, :bearer_token) do
          {:ok, val} ->
            val

          :error ->
            if cookie || bpmcsrf do
              nil
            else
              Application.get_env(:creatio, :auth_token) ||
                System.get_env("CREATIO_AUTH_TOKEN") ||
                System.get_env("CREATIO_BEARER_TOKEN")
            end
        end
    end
  end

  defp resolve_read_only(opts) do
    raw =
      case Keyword.fetch(opts, :read_only) do
        {:ok, val} when not is_nil(val) ->
          val

        _ ->
          case Application.get_env(:creatio, :read_only) do
            nil -> System.get_env("CREATIO_READ_ONLY")
            val -> val
          end
      end

    normalize_read_only(raw)
  end

  defp normalize_read_only(val) when val in [true, "true", "TRUE", "1", 1], do: true
  defp normalize_read_only(_), do: false

  defp apply_auth_headers(%__MODULE__{} = client) do
    req =
      case client.auth_mode do
        :bearer ->
          client.req
          |> Req.Request.delete_header("cookie")
          |> Req.Request.delete_header("bpmcsrf")
          |> put_or_delete_header(
            "authorization",
            client.auth_token && "Bearer #{client.auth_token}"
          )

        :forms ->
          client.req
          |> Req.Request.delete_header("authorization")
          |> put_or_delete_header("cookie", client.cookie)
          |> put_or_delete_header("bpmcsrf", client.bpmcsrf)

        _ ->
          client.req
          |> maybe_put_header("authorization", client.auth_token && "Bearer #{client.auth_token}")
          |> maybe_put_header("cookie", client.cookie)
          |> maybe_put_header("bpmcsrf", client.bpmcsrf)
      end

    %Req.Request{} =
      req =
      req
      |> Req.Request.put_private(:creatio_client_meta, %{
        base_url: client.base_url,
        auth_mode: client.auth_mode
      })
      |> Telemetry.attach_req_steps()

    req =
      cond do
        client.read_only and not Keyword.has_key?(req.request_steps, :read_only_guard) ->
          Req.Request.append_request_steps(req, read_only_guard: &read_only_guard/1)

        not client.read_only and Keyword.has_key?(req.request_steps, :read_only_guard) ->
          %{req | request_steps: Keyword.delete(req.request_steps, :read_only_guard)}

        true ->
          req
      end

    %{client | req: req}
  end

  defp read_only_guard(req) do
    raw_path =
      case req.url do
        %URI{path: p} -> p || ""
        other -> URI.parse(to_string(other)).path || ""
      end

    case Util.safe_normalized_path(raw_path) do
      {:error, :invalid_path} ->
        {req,
         Creatio.Error.new(
           status: 403,
           code: "ReadOnlyMode",
           message: "Client is in read-only mode. Path traversal request to #{raw_path} blocked."
         )}

      {:ok, path} ->
        if req.method in [:get, :head, :options] do
          req
        else
          allowed_suffixes = [
            "/DataService/json/SyncReply/SelectQuery",
            "/ServiceModel/AuthService.svc/Login",
            "/AuthService.svc/Login",
            "/connect/token",
            "/odata/$batch"
          ]

          if not String.contains?(path, "/0/rest/") and
               Enum.any?(allowed_suffixes, &String.ends_with?(path, &1)) do
            req
          else
            {req,
             Creatio.Error.new(
               status: 403,
               code: "ReadOnlyMode",
               message: "Client is in read-only mode. Mutation request to #{path} blocked."
             )}
          end
        end
    end
  end

  defp maybe_put_header(req, _name, nil), do: req
  defp maybe_put_header(req, name, value), do: Req.Request.put_header(req, name, value)

  defp put_header_if_absent(req, name, value) do
    case Req.Request.get_header(req, name) do
      [] -> Req.Request.put_header(req, name, value)
      _ -> req
    end
  end

  defp put_or_delete_header(req, name, nil), do: Req.Request.delete_header(req, name)
  defp put_or_delete_header(req, name, value), do: Req.Request.put_header(req, name, value)

  defp normalize_opts_list(opts) when is_map(opts) do
    opts
    |> Map.to_list()
    |> normalize_opts_list()
  end

  defp normalize_opts_list(opts) when is_list(opts) do
    Enum.flat_map(opts, fn
      {k, v} when is_atom(k) ->
        [{k, v}]

      {k, v} when is_binary(k) ->
        case Map.fetch(@known_string_option_keys, k) do
          {:ok, atom_key} -> [{atom_key, v}]
          :error -> []
        end

      _ ->
        []
    end)
  end

  defp sanitize_stored_options(opts_list) when is_list(opts_list) do
    opts_list
    |> Keyword.drop(@sensitive_option_keys)
    |> Enum.map(fn
      {:req_options, req_opts} when is_list(req_opts) ->
        cleaned_req_opts =
          req_opts
          |> Keyword.drop([:auth, :headers])

        {:req_options, cleaned_req_opts}

      {:req_options, req_opts} when is_map(req_opts) ->
        {:req_options, Map.drop(req_opts, [:auth, :headers, "auth", "headers"])}

      other ->
        other
    end)
  end

  defp normalize_optional_url(url) when is_binary(url) do
    case url |> String.trim() |> String.trim_trailing("/") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_url(_), do: nil
end
