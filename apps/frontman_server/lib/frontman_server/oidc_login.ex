defmodule FrontmanServer.OIDCLogin do
  @moduledoc """
  Coordinates OIDC authentication with organization membership synchronization.
  """

  alias Ecto.Multi
  alias FrontmanServer.Accounts.{OIDC, Scope, User}
  alias FrontmanServer.Organizations
  alias FrontmanServer.Repo

  @spec authenticate(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, User.t()} | {:error, term()}
  def authenticate(code, pkce_verifier, nonce, redirect_uri)
      when is_binary(code) and is_binary(pkce_verifier) and is_binary(nonce) and
             is_binary(redirect_uri) do
    with {:ok, account_multi, organization_slugs} <-
           OIDC.authenticate_multi(code, pkce_verifier, nonce, redirect_uri) do
      account_multi
      |> Multi.merge(fn %{user: user} ->
        organizations().sync_oidc_memberships_multi(Scope.for_user(user), organization_slugs)
      end)
      |> Repo.transaction()
      |> authentication_result()
    end
  end

  defp authentication_result({:ok, %{user: user}}), do: {:ok, user}

  defp authentication_result({:error, _step, reason, _changes}), do: {:error, reason}

  defp organizations do
    :frontman_server
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:organizations, Organizations)
  end
end
