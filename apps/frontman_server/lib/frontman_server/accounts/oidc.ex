defmodule FrontmanServer.Accounts.OIDC do
  @moduledoc """
  Coordinates OIDC provider configuration and authorization sessions.
  """

  alias FrontmanServer.Accounts.OIDC.Client
  alias FrontmanServer.Accounts.{User, UserIdentity, WorkOS}
  alias FrontmanServer.Repo

  @provider_configuration_name __MODULE__.ProviderConfiguration
  @request_timeout_ms 10_000

  @spec configured?() :: boolean()
  def configured? do
    [:issuer, :client_id, :client_secret]
    |> Enum.all?(&present?(&1))
  end

  @spec provider_name() :: String.t()
  def provider_name do
    case config(:provider_name) do
      value when is_binary(value) and value != "" -> value
      _value -> "Single Sign-On"
    end
  end

  @spec children() :: [Supervisor.child_spec()]
  def children do
    case configured?() do
      true ->
        [
          {Oidcc.ProviderConfiguration.Worker,
           %{
             issuer: config!(:issuer),
             name: @provider_configuration_name,
             backoff_type: :random_exponential,
             provider_configuration_opts: %{request_opts: request_opts()}
           }}
        ]

      false ->
        []
    end
  end

  @spec authorization_url(String.t()) ::
          {:ok,
           %{
             url: String.t(),
             session: %{state: binary(), nonce: binary(), pkce_verifier: binary()}
           }}
          | {:error, term()}
  def authorization_url(redirect_uri) when is_binary(redirect_uri) do
    session = authorization_session()

    with {:ok, url} <-
           client().authorization_url(
             session.state,
             session.nonce,
             session.pkce_verifier,
             redirect_uri
           ) do
      {:ok, %{url: url, session: session}}
    end
  end

  @spec provider_configuration_name() :: atom()
  def provider_configuration_name, do: @provider_configuration_name

  @spec request_opts() :: %{timeout: pos_integer()}
  def request_opts, do: %{timeout: @request_timeout_ms}

  @spec authenticate(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, User.t(), [String.t()]} | {:error, term()}
  def authenticate(code, pkce_verifier, nonce, redirect_uri)
      when is_binary(code) and is_binary(pkce_verifier) and is_binary(nonce) and
             is_binary(redirect_uri) do
    with {:ok, multi, groups} <- authenticate_multi(code, pkce_verifier, nonce, redirect_uri) do
      case Repo.transaction(multi) do
        {:ok, %{user: user}} -> {:ok, user, groups}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @spec authenticate_multi(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Ecto.Multi.t(), [String.t()]} | {:error, term()}
  def authenticate_multi(code, pkce_verifier, nonce, redirect_uri)
      when is_binary(code) and is_binary(pkce_verifier) and is_binary(nonce) and
             is_binary(redirect_uri) do
    with {:ok, claims} <- client().retrieve_claims(code, pkce_verifier, nonce, redirect_uri),
         {:ok, profile, groups} <- profile_from_claims(claims) do
      {:ok, WorkOS.upsert_oauth_profile_multi(profile, nil), groups}
    end
  end

  @spec link(User.t(), String.t(), %{pkce_verifier: String.t(), nonce: String.t()}, String.t()) ::
          {:ok, UserIdentity.t()} | {:error, term()}
  def link(%User{} = user, code, %{pkce_verifier: pkce_verifier, nonce: nonce}, redirect_uri)
      when is_binary(code) and is_binary(pkce_verifier) and is_binary(nonce) and
             is_binary(redirect_uri) do
    with {:ok, claims} <- client().retrieve_claims(code, pkce_verifier, nonce, redirect_uri),
         {:ok, profile, _groups} <- profile_from_claims(claims) do
      WorkOS.link_oauth_profile(user, profile)
    end
  end

  @spec linked?(User.t()) :: boolean()
  def linked?(%User{} = user) do
    UserIdentity
    |> UserIdentity.for_user_and_provider(user.id, "oidc")
    |> Repo.exists?()
  end

  @spec unlink(User.t()) :: {:ok, UserIdentity.t()} | {:error, :not_found}
  def unlink(%User{} = user) do
    case UserIdentity |> UserIdentity.for_user_and_provider(user.id, "oidc") |> Repo.one() do
      nil -> {:error, :not_found}
      identity -> Repo.delete(identity)
    end
  end

  defp authorization_session do
    %{
      state: secure_value(),
      nonce: secure_value(),
      pkce_verifier: secure_value()
    }
  end

  defp secure_value do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp profile_from_claims(claims) when is_map(claims) do
    with {:ok, issuer} <- required_claim(claims, "iss", :issuer),
         {:ok, subject} <- required_claim(claims, "sub", :subject),
         {:ok, email} <- required_claim(claims, "email", :email),
         :ok <- verified_email(claims),
         {:ok, groups} <- groups(claims) do
      {:ok,
       %{
         provider: "oidc",
         provider_id: issuer <> "|" <> subject,
         provider_email: email,
         provider_name: profile_name(claims, email),
         provider_avatar_url: optional_binary_claim(claims, "picture")
       }, groups}
    end
  end

  defp profile_from_claims(claims), do: {:error, {:invalid_claims, claims}}

  defp required_claim(claims, claim, field) do
    case Map.get(claims, claim) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_claim, field}}
          _value -> {:ok, value}
        end

      _value ->
        {:error, {:invalid_claim, field}}
    end
  end

  defp verified_email(%{"email_verified" => true}), do: :ok
  defp verified_email(_claims), do: {:error, {:invalid_claim, :email_verified}}

  defp profile_name(claims, email) do
    case Map.get(claims, "name") do
      value when is_binary(value) and value != "" -> value
      _value -> email
    end
  end

  defp optional_binary_claim(claims, claim) do
    case Map.get(claims, claim) do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp groups(claims) do
    case Map.fetch(claims, group_claim()) do
      :error ->
        {:ok, []}

      {:ok, values} when is_list(values) ->
        case Enum.all?(values, &is_binary/1) do
          true -> {:ok, Enum.uniq(values)}
          false -> {:error, {:invalid_claim, :groups}}
        end

      {:ok, _value} ->
        {:error, {:invalid_claim, :groups}}
    end
  end

  defp group_claim do
    case config(:group_claim) do
      value when is_binary(value) and value != "" -> value
      _value -> "groups"
    end
  end

  defp client, do: config(:client, Client)

  defp config(key, default \\ nil),
    do: Application.get_env(:frontman_server, __MODULE__, []) |> Keyword.get(key, default)

  defp config!(key), do: config(key) || raise("OIDC #{key} is not configured")

  defp present?(key) do
    case config(key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end
end
