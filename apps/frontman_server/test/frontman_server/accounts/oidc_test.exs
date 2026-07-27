defmodule FrontmanServer.Accounts.OIDCTest do
  use FrontmanServer.DataCase, async: false

  alias FrontmanServer.Accounts
  alias FrontmanServer.Accounts.OIDC

  import FrontmanServer.Test.Fixtures.Accounts

  setup do
    previous_config = Application.get_env(:frontman_server, OIDC)

    on_exit(fn ->
      Application.put_env(:frontman_server, OIDC, previous_config)
    end)

    :ok
  end

  test "is disabled until issuer, client ID, and client secret are configured" do
    configure_oidc([])

    refute OIDC.configured?()
    assert OIDC.children() == []
  end

  test "uses the default provider name" do
    configure_oidc()

    assert OIDC.configured?()
    assert OIDC.provider_name() == "Single Sign-On"
  end

  test "starts one configured provider worker with retry backoff" do
    configure_oidc()
    provider_configuration_name = OIDC.provider_configuration_name()

    assert [
             {Oidcc.ProviderConfiguration.Worker,
              %{
                issuer: "https://issuer.example",
                name: ^provider_configuration_name,
                backoff_type: :random_exponential,
                provider_configuration_opts: %{request_opts: %{timeout: 10_000}}
              }}
           ] = OIDC.children()
  end

  test "uses the configured provider name" do
    configure_oidc(provider_name: "Authentik")

    assert OIDC.provider_name() == "Authentik"
  end

  test "generates distinct authorization security values and forwards them to the configured client" do
    configure_oidc()

    assert {:ok, %{url: "https://issuer.example/authorize", session: first_session}} =
             OIDC.authorization_url("https://frontman.example/auth/oidc/callback")

    assert_receive {:oidc_authorization_url, first_state, first_nonce, first_verifier,
                    "https://frontman.example/auth/oidc/callback"}

    assert first_session == %{
             state: first_state,
             nonce: first_nonce,
             pkce_verifier: first_verifier
           }

    assert byte_size(first_state) == 43
    assert byte_size(first_nonce) == 43
    assert byte_size(first_verifier) == 43

    assert {:ok, %{session: second_session}} =
             OIDC.authorization_url("https://frontman.example/auth/oidc/callback")

    refute first_session == second_session
  end

  describe "authenticate/4" do
    test "rejects claims without an issuer" do
      configure_oidc(claims: valid_claims() |> Map.delete("iss"))

      assert {:error, {:invalid_claim, :issuer}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "rejects claims without a subject" do
      configure_oidc(claims: valid_claims() |> Map.delete("sub"))

      assert {:error, {:invalid_claim, :subject}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "rejects claims without an email" do
      configure_oidc(claims: valid_claims() |> Map.delete("email"))

      assert {:error, {:invalid_claim, :email}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "rejects claims unless email_verified is exactly true" do
      configure_oidc(claims: Map.put(valid_claims(), "email_verified", "true"))

      assert {:error, {:invalid_claim, :email_verified}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "logs in an existing OIDC identity and extracts unique groups" do
      user = user_fixture()
      identity_fixture(user, provider: "oidc", provider_id: "https://issuer.example|subject")

      configure_oidc(
        group_claim: "roles",
        claims:
          valid_claims()
          |> Map.delete("groups")
          |> Map.put("roles", ["engineering", "engineering", "product"])
      )

      assert {:ok, returned_user, ["engineering", "product"]} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")

      assert returned_user.id == user.id
    end

    test "treats a missing configured group claim as no memberships" do
      configure_oidc(group_claim: "roles", claims: Map.delete(valid_claims(), "groups"))

      assert {:ok, _user, []} = OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "rejects a configured group claim with the wrong type" do
      configure_oidc(
        group_claim: "roles",
        claims: valid_claims() |> Map.delete("groups") |> Map.put("roles", "engineering")
      )

      assert {:error, {:invalid_claim, :groups}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "rejects a configured group claim containing non-strings" do
      configure_oidc(
        group_claim: "roles",
        claims: valid_claims() |> Map.delete("groups") |> Map.put("roles", ["engineering", 1])
      )

      assert {:error, {:invalid_claim, :groups}} =
               OIDC.authenticate("code", "verifier", "nonce", "uri")
    end

    test "links a verified email account" do
      user = user_fixture(email: "person@example.com")
      configure_oidc(claims: Map.put(valid_claims(), "email", user.email))

      assert {:ok, returned_user, []} = OIDC.authenticate("code", "verifier", "nonce", "uri")
      assert returned_user.id == user.id

      assert [%{provider: "oidc", provider_id: "https://issuer.example|subject"}] =
               Accounts.list_user_identities(user)
    end

    test "creates a user for a new verified identity" do
      configure_oidc(
        claims:
          valid_claims()
          |> Map.put("email", "new-person@example.com")
          |> Map.put("name", "New Person")
      )

      assert {:ok, user, []} = OIDC.authenticate("code", "verifier", "nonce", "uri")
      assert user.email == "new-person@example.com"
      assert user.name == "New Person"
    end
  end

  describe "link/4 and unlink/1" do
    test "reports whether a user already linked OIDC" do
      user = user_fixture()

      refute OIDC.linked?(user)

      identity_fixture(user, provider: "oidc")

      assert OIDC.linked?(user)
    end

    test "links and unlinks an OIDC identity for a user" do
      user = user_fixture()
      configure_oidc(claims: valid_claims())

      assert {:ok, identity} =
               OIDC.link(user, "code", %{pkce_verifier: "verifier", nonce: "nonce"}, "uri")

      assert identity.provider == "oidc"

      assert {:ok, deleted_identity} = OIDC.unlink(user)
      assert deleted_identity.id == identity.id
      assert [] = Accounts.list_user_identities(user)
    end
  end

  defp configure_oidc(
         overrides \\ [
           issuer: "https://issuer.example",
           client_id: "client-id",
           client_secret: "client-secret"
         ]
       ) do
    Application.put_env(
      :frontman_server,
      OIDC,
      Keyword.merge(
        [client: FrontmanServer.Test.OIDCClient, claims: valid_claims()],
        overrides
      )
    )
  end

  defp valid_claims do
    %{
      "iss" => "https://issuer.example",
      "sub" => "subject",
      "email" => "person@example.com",
      "email_verified" => true,
      "name" => "Person",
      "picture" => "https://issuer.example/person.png",
      "groups" => []
    }
  end
end
