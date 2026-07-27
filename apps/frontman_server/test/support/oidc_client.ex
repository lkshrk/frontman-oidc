defmodule FrontmanServer.Test.OIDCClient do
  @moduledoc false

  @spec authorization_url(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
  def authorization_url(state, nonce, pkce_verifier, redirect_uri) do
    send(self(), {:oidc_authorization_url, state, nonce, pkce_verifier, redirect_uri})
    {:ok, "https://issuer.example/authorize"}
  end

  @spec retrieve_claims(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()}
  def retrieve_claims(code, pkce_verifier, nonce, redirect_uri) do
    send(self(), {:oidc_retrieve_claims, code, pkce_verifier, nonce, redirect_uri})

    claims =
      :frontman_server
      |> Application.fetch_env!(FrontmanServer.Accounts.OIDC)
      |> Keyword.fetch!(:claims)

    {:ok, claims}
  end
end
