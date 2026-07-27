defmodule FrontmanServerWeb.OIDCControllerTest do
  use FrontmanServerWeb.ConnCase, async: false

  alias FrontmanServer.Accounts
  alias FrontmanServer.Accounts.OIDC

  import FrontmanServer.Test.Fixtures.Accounts

  setup do
    previous_config = Application.get_env(:frontman_server, OIDC)

    on_exit(fn ->
      Application.put_env(:frontman_server, OIDC, previous_config)
    end)

    configure_oidc()
    %{user: user_fixture()}
  end

  describe "GET /auth/oidc" do
    test "stores one authorization session and redirects to the provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc")

      assert redirected_to(conn) == "https://issuer.example/authorize"

      assert %{state: state, nonce: nonce, pkce_verifier: verifier} =
               get_session(conn, :oidc_authorization)

      assert is_binary(state)
      assert is_binary(nonce)
      assert is_binary(verifier)

      assert %{value: "XCP." <> _encrypted_session} =
               conn.resp_cookies["_frontman_server_key"]
    end
  end

  describe "GET /auth/oidc/callback" do
    test "requires the exact state and deletes the authorization session", %{conn: conn} do
      authorization = %{state: "expected", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{code: "code", state: "unexpected"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Authentication failed. Please try again."
    end

    test "handles access denied only with the exact state", %{conn: conn} do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{error: "access_denied", state: "state"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oidc_authorization) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign in was cancelled."
    end

    test "rejects access denied without state and deletes the authorization session", %{
      conn: conn
    } do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{error: "access_denied"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Authentication failed. Please try again."
    end

    test "rejects access denied with a mismatched state and deletes the authorization session", %{
      conn: conn
    } do
      authorization = %{state: "expected", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{error: "access_denied", state: "unexpected"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Authentication failed. Please try again."
    end

    test "logs in after a successful OIDC authentication", %{conn: conn} do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{code: "code", state: "state"})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Welcome!"
    end

    test "preserves the login return-to path", %{conn: conn} do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization, user_return_to: "/frontman"})
        |> get(~p"/auth/oidc/callback", %{code: "code", state: "state"})

      assert redirected_to(conn) == "/frontman"
    end

    test "handles authentication failures without retaining the authorization session", %{
      conn: conn
    } do
      configure_oidc(claims: %{})
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> init_test_session(%{oidc_authorization: authorization})
        |> get(~p"/auth/oidc/callback", %{code: "code", state: "state"})

      assert redirected_to(conn) == ~p"/users/log-in"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Authentication failed. Please try again."
    end
  end

  describe "OIDC identity linking" do
    test "renders OIDC identity controls in settings", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/users/settings")

      response = html_response(conn, 200)

      assert response =~ "Authentik"
      assert response =~ ~s(href="/auth/oidc/link")
    end

    test "requires sudo mode to start linking", %{conn: conn, user: user} do
      old_auth_time = DateTime.add(DateTime.utc_now(), -30, :minute)

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: old_auth_time)
        |> get(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/users/log-in?return_to=%2Fauth%2Foidc%2Flink"
    end

    test "treats an existing OIDC identity as already linked", %{conn: conn, user: user} do
      identity_fixture(user, provider: "oidc")

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/auth/oidc/link")

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Authentik is already connected."
    end

    test "reports a connection failure when OIDC becomes unavailable", %{conn: conn, user: user} do
      configure_oidc(issuer: nil)

      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/auth/oidc/link")

      assert redirected_to(conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Connection failed. Please try again."
    end

    test "logs a stale-sudo user out, then returns a completed login to the OIDC link route", %{
      conn: conn,
      user: user
    } do
      old_auth_time = DateTime.add(DateTime.utc_now(), -30, :minute)
      user = set_password(user)

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: old_auth_time)
        |> get(~p"/auth/oidc/link")

      assert redirected_to(conn) == "/users/log-in?return_to=%2Fauth%2Foidc%2Flink"
      refute get_session(conn, :user_token)

      conn =
        conn
        |> recycle()
        |> get("/users/log-in?return_to=%2Fauth%2Foidc%2Flink")

      assert html_response(conn, 200) =~ "Sign in to Frontman"
      assert get_session(conn, :user_return_to) == "/auth/oidc/link"

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/auth/oidc/link"
      refute get_session(conn, :user_return_to)
    end

    test "links an identity and deletes the authorization session", %{conn: conn, user: user} do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_authorization, authorization)

      conn =
        conn
        |> get(~p"/auth/oidc/link/callback", %{code: "code", state: "state"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Authentik connected successfully."
      assert [%{provider: "oidc"}] = Accounts.list_user_identities(user)
    end

    test "completes a state-validated callback after sudo mode expires", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> get(~p"/auth/oidc/link")

      authorization = get_session(conn, :oidc_authorization)
      token = get_session(conn, :user_token)
      old_auth_time = DateTime.add(DateTime.utc_now(), -30, :minute)
      override_token_authenticated_at(token, old_auth_time)

      conn =
        get(conn, ~p"/auth/oidc/link/callback", %{code: "code", state: authorization.state})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Authentik connected successfully."
    end

    test "handles a link authentication failure and deletes the authorization session", %{
      conn: conn,
      user: user
    } do
      configure_oidc(claims: %{})
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_authorization, authorization)
        |> get(~p"/auth/oidc/link/callback", %{code: "code", state: "state"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Connection failed. Please try again."
    end

    test "handles link access denied only with the exact state", %{conn: conn, user: user} do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_authorization, authorization)
        |> get(~p"/auth/oidc/link/callback", %{error: "access_denied", state: "state"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Connection was cancelled."
    end

    test "rejects link access denied without state and deletes the authorization session", %{
      conn: conn,
      user: user
    } do
      authorization = %{state: "state", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_authorization, authorization)
        |> get(~p"/auth/oidc/link/callback", %{error: "access_denied"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Connection failed. Please try again."
    end

    test "rejects link access denied with a mismatched state and deletes the authorization session",
         %{
           conn: conn,
           user: user
         } do
      authorization = %{state: "expected", nonce: "nonce", pkce_verifier: "verifier"}

      conn =
        conn
        |> log_in_user(user)
        |> put_session(:oidc_authorization, authorization)
        |> get(~p"/auth/oidc/link/callback", %{error: "access_denied", state: "unexpected"})

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :oidc_authorization) == nil

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Connection failed. Please try again."
    end

    test "requires sudo mode to unlink", %{conn: conn, user: user} do
      _identity = identity_fixture(user, provider: "oidc")
      old_auth_time = DateTime.add(DateTime.utc_now(), -30, :minute)

      conn =
        conn
        |> log_in_user(user, token_authenticated_at: old_auth_time)
        |> delete(~p"/auth/oidc/unlink")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "unlinks the OIDC identity", %{conn: conn, user: user} do
      _identity = identity_fixture(user, provider: "oidc")

      conn =
        conn
        |> log_in_user(user)
        |> delete(~p"/auth/oidc/unlink")

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Authentik disconnected."
      assert [] = Accounts.list_user_identities(user)
    end
  end

  defp configure_oidc(overrides \\ []) do
    Application.put_env(
      :frontman_server,
      OIDC,
      Keyword.merge(
        [
          issuer: "https://issuer.example",
          client_id: "client-id",
          client_secret: "client-secret",
          provider_name: "Authentik",
          client: FrontmanServer.Test.OIDCClient,
          claims: valid_claims()
        ],
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
      "groups" => []
    }
  end
end
