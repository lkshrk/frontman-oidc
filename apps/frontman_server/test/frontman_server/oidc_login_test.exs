defmodule FrontmanServer.OIDCLoginTest do
  use FrontmanServer.DataCase, async: false

  alias FrontmanServer.Accounts.{OIDC, User, UserIdentity}
  alias FrontmanServer.OIDCLogin
  alias FrontmanServer.Organizations

  import FrontmanServer.Test.Fixtures.Accounts

  setup do
    previous_config = Application.get_env(:frontman_server, OIDC)
    previous_login_config = Application.fetch_env(:frontman_server, OIDCLogin)

    Application.put_env(:frontman_server, OIDC,
      issuer: "https://issuer.example",
      client_id: "client-id",
      client_secret: "client-secret",
      client: FrontmanServer.Test.OIDCClient,
      claims: %{
        "iss" => "https://issuer.example",
        "sub" => "subject",
        "email" => "person@example.com",
        "email_verified" => true,
        "name" => "Person",
        "groups" => ["engineering"]
      }
    )

    on_exit(fn ->
      Application.put_env(:frontman_server, OIDC, previous_config)

      case previous_login_config do
        {:ok, config} -> Application.put_env(:frontman_server, OIDCLogin, config)
        :error -> Application.delete_env(:frontman_server, OIDCLogin)
      end
    end)

    :ok
  end

  test "authenticates then synchronizes OIDC group memberships" do
    owner_scope = user_scope_fixture()
    {:ok, organization} = Organizations.create_organization(owner_scope, %{name: "Engineering"})

    assert {:ok, user} = OIDCLogin.authenticate("code", "verifier", "nonce", "uri")

    user_scope = user_scope_fixture(user, organization)
    assert Organizations.member?(user_scope)
  end

  test "rolls back the OIDC account when organization synchronization fails" do
    Application.put_env(:frontman_server, OIDCLogin,
      organizations: FrontmanServer.Test.OIDCOrganizationsError
    )

    assert {:error, :synchronization_failed} =
             OIDCLogin.authenticate("code", "verifier", "nonce", "uri")

    refute Repo.get_by(User, email: "person@example.com")
    refute Repo.get_by(UserIdentity, provider: "oidc")
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end

defmodule FrontmanServer.Test.OIDCOrganizationsError do
  @moduledoc false

  alias Ecto.Multi

  @spec sync_oidc_memberships_multi(term(), [String.t()]) :: Multi.t()
  def sync_oidc_memberships_multi(_scope, _organization_slugs) do
    Multi.run(Multi.new(), :oidc_memberships, fn _repo, _changes ->
      {:error, :synchronization_failed}
    end)
  end
end
