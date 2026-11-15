defmodule Creatio.Client do
  @moduledoc """
  Client struct and configuration for communicating with Creatio CRM APIs.

  Wraps a `Req.Request` pre-configured with the base URL, authentication headers,
  read-only safety guards, and content negotiation required by Creatio.
  """

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
  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    base_url =
      (Keyword.get(opts, :base_url) ||
         Application.get_env(:creatio, :base_url) ||
         System.get_env("CREATIO_BASE_URL") ||
         "")
      |> String.trim_trailing("/")

    auth_token =
      Keyword.get(opts, :auth_token) ||
        Application.get_env(:creatio, :auth_token) ||
        System.get_env("CREATIO_AUTH_TOKEN") ||
        System.get_env("CREATIO_BEARER_TOKEN")

    cookie = Keyword.get(opts, :cookie)
    bpmcsrf = Keyword.get(opts, :bpmcsrf)

    identity_service_url =
      Keyword.get(opts, :identity_service_url) ||
        Application.get_env(:creatio, :identity_service_url) ||
        System.get_env("CREATIO_IDENTITY_URL") ||
        System.get_env("CREATIO_IDENTITY_SERVICE_URL")

    client_id =
      Keyword.get(opts, :client_id) ||
        Application.get_env(:creatio, :client_id) ||
        System.get_env("CREATIO_CLIENT_ID")

    client_secret =
      Keyword.get(opts, :client_secret) ||
        Application.get_env(:creatio, :client_secret) ||
        System.get_env("CREATIO_CLIENT_SECRET")

    req_options = Keyword.get(opts, :req_options, [])
    read_only = resolve_read_only(opts)

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
      |> Req.Request.put_header("accept", "application/json; odata.metadata=minimal")
      |> Req.Request.put_header("forceusesession", "true")

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
      options: opts,
      req: req
    }

    apply_auth_headers(client)
  end

  @doc """
  Builds a `Creatio.Client` from an existing `Req.Request`.
  """
  @spec from_req(Req.Request.t(), keyword() | map()) :: t()
  def from_req(%Req.Request{} = req, opts \\ []) do
    opts_list = if is_map(opts), do: Map.to_list(opts), else: opts

    base_url =
      Keyword.get(opts_list, :base_url) || req.options[:base_url] ||
        System.get_env("CREATIO_BASE_URL") || ""

    auth_token = Keyword.get(opts_list, :auth_token)
    cookie = Keyword.get(opts_list, :cookie)
    bpmcsrf = Keyword.get(opts_list, :bpmcsrf)
    read_only = resolve_read_only(opts_list)

    auth_mode =
      Keyword.get_lazy(opts_list, :auth_mode, fn ->
        cond do
          auth_token || Req.Request.get_header(req, "authorization") != [] -> :bearer
          cookie || bpmcsrf || Req.Request.get_header(req, "cookie") != [] -> :forms
          true -> :none
        end
      end)

    configured_req =
      req
      |> put_header_if_absent("accept", "application/json; odata.metadata=minimal")
      |> put_header_if_absent("forceusesession", "true")

    client = %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      auth_token: auth_token,
      auth_mode: auth_mode,
      cookie: cookie,
      bpmcsrf: bpmcsrf,
      identity_service_url: Keyword.get(opts_list, :identity_service_url),
      client_id: Keyword.get(opts_list, :client_id),
      client_secret: Keyword.get(opts_list, :client_secret),
      read_only: read_only,
      req: configured_req,
      options: opts_list
    }

    apply_auth_headers(client)
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
    client = %{client | auth_token: token, auth_mode: :bearer, cookie: nil, bpmcsrf: nil}
    apply_auth_headers(client)
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

    req =
      if client.read_only and not Keyword.has_key?(req.request_steps, :read_only_guard) do
        Req.Request.append_request_steps(req, read_only_guard: &read_only_guard/1)
      else
        req
      end

    %{client | req: req}
  end

  defp read_only_guard(req) do
    if req.method in [:get, :head, :options] do
      req
    else
      path =
        case req.url do
          %URI{path: p} -> p || ""
          other -> URI.parse(to_string(other)).path || ""
        end

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
end
