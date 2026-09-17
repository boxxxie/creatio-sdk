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

    read_only =
      Keyword.get(opts, :read_only)
      |> case do
        nil ->
          Application.get_env(:creatio, :read_only)
          |> case do
            nil -> System.get_env("CREATIO_READ_ONLY") in ["true", "1"]
            val -> val
          end
        val -> val
      end

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

    read_only =
      Keyword.get(opts_list, :read_only)
      |> case do
        nil ->
          Application.get_env(:creatio, :read_only)
          |> case do
            nil -> System.get_env("CREATIO_READ_ONLY") in ["true", "1"]
            val -> val
          end
        val -> val
      end

    configured_req =
      req
      |> Req.Request.put_header("accept", "application/json; odata.metadata=minimal")
      |> Req.Request.put_header("forceusesession", "true")

    client = %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      auth_token: Keyword.get(opts_list, :auth_token),
      auth_mode: Keyword.get(opts_list, :auth_mode, :bearer),
      cookie: Keyword.get(opts_list, :cookie),
      bpmcsrf: Keyword.get(opts_list, :bpmcsrf),
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
  Sets an OAuth 2.0 Bearer token on the client.
  """
  @spec put_bearer_token(t(), String.t()) :: t()
  def put_bearer_token(%__MODULE__{} = client, token) when is_binary(token) do
    client = %{client | auth_token: token, auth_mode: :bearer}
    apply_auth_headers(client)
  end

  @doc """
  Sets Forms authentication cookies and BPMCSRF token on the client.
  """
  @spec put_forms_auth(t(), String.t(), String.t() | nil) :: t()
  def put_forms_auth(%__MODULE__{} = client, cookie, bpmcsrf \\ nil) when is_binary(cookie) do
    client = %{client | cookie: cookie, bpmcsrf: bpmcsrf, auth_mode: :forms}
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

  defp apply_auth_headers(%__MODULE__{} = client) do
    req =
      client.req
      |> maybe_put_header("authorization", client.auth_token && "Bearer #{client.auth_token}")
      |> maybe_put_header("cookie", client.cookie)
      |> maybe_put_header("bpmcsrf", client.bpmcsrf)

    req =
      if client.read_only do
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
        case URI.parse(req.url |> to_string()) do
          %URI{path: nil} -> ""
          %URI{path: p} -> p
        end

      allowed_paths = ["/SelectQuery", "/Login", "/token", "/$batch", "/AuthService.svc/Login"]

      if Enum.any?(allowed_paths, &String.ends_with?(path, &1)) do
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

  defp maybe_put_header(req, name, value) do
    Req.Request.put_header(req, name, value)
  end
end
