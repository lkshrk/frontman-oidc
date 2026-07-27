defmodule FrontmanServer.Accounts.OIDC.Client do
  @moduledoc false

  alias FrontmanServer.Accounts.OIDC
  alias Oidcc.Token
  alias Oidcc.Token.Id

  @spec authorization_url(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def authorization_url(state, nonce, pkce_verifier, redirect_uri)
      when is_binary(state) and is_binary(nonce) and is_binary(pkce_verifier) and
             is_binary(redirect_uri) do
    with {:ok, url} <-
           Oidcc.create_redirect_url(
             OIDC.provider_configuration_name(),
             client_id(),
             client_secret(),
             %{
               redirect_uri: redirect_uri,
               state: state,
               nonce: nonce,
               pkce_verifier: pkce_verifier,
               require_pkce: true,
               scopes: ["openid", "email", "profile"]
             }
           ) do
      {:ok, IO.iodata_to_binary(url)}
    end
  end

  @spec retrieve_claims(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def retrieve_claims(code, pkce_verifier, nonce, redirect_uri)
      when is_binary(code) and is_binary(pkce_verifier) and is_binary(nonce) and
             is_binary(redirect_uri) do
    case Oidcc.retrieve_token(
           code,
           OIDC.provider_configuration_name(),
           client_id(),
           client_secret(),
           %{
             redirect_uri: redirect_uri,
             pkce_verifier: pkce_verifier,
             require_pkce: true,
             nonce: nonce,
             scope: ["openid", "email", "profile"],
             request_opts: OIDC.request_opts()
           }
         ) do
      {:ok, %Token{id: %Id{claims: claims}}} -> {:ok, claims}
      {:ok, %Token{}} -> {:error, :missing_id_token}
      {:error, _reason} = error -> error
    end
  end

  defp client_id, do: config!(:client_id)

  defp client_secret, do: config!(:client_secret)

  defp config!(key) do
    :frontman_server
    |> Application.fetch_env!(OIDC)
    |> Keyword.fetch!(key)
  end
end
