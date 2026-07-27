defmodule FrontmanServerWeb.OIDCController do
  use FrontmanServerWeb, :controller

  require Logger

  alias FrontmanServer.Accounts.OIDC
  alias FrontmanServer.OIDCLogin
  alias FrontmanServerWeb.UserAuth

  import FrontmanServerWeb.UserAuth, only: [require_sudo_mode: 2]

  plug(:require_sudo_mode when action in [:link_request, :unlink])

  def request(conn, _params) do
    with true <- OIDC.configured?(),
         {:ok, %{url: authorization_url, session: authorization}} <-
           OIDC.authorization_url(callback_url(conn)) do
      conn
      |> put_session(:oidc_authorization, authorization)
      |> redirect(external: authorization_url)
    else
      false -> authentication_failed(conn, ~p"/users/log-in")
      {:error, _reason} -> authentication_failed(conn, ~p"/users/log-in")
    end
  end

  def callback(conn, %{"error" => "access_denied", "state" => state}) do
    case pop_authorization(conn, state) do
      {:ok, conn, _authorization} ->
        conn
        |> put_flash(:error, "Sign in was cancelled.")
        |> redirect(to: ~p"/users/log-in")

      {:error, conn} ->
        authentication_failed(conn, ~p"/users/log-in")
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    case pop_authorization(conn, state) do
      {:ok, conn, %{pkce_verifier: pkce_verifier, nonce: nonce}} ->
        case OIDCLogin.authenticate(code, pkce_verifier, nonce, callback_url(conn)) do
          {:ok, user} ->
            conn
            |> put_flash(:info, "Welcome!")
            |> UserAuth.log_in_user(user, %{"remember_me" => "true"})

          {:error, _reason} ->
            authentication_failed(conn, ~p"/users/log-in")
        end

      {:error, conn} ->
        authentication_failed(conn, ~p"/users/log-in")
    end
  end

  def callback(conn, _params) do
    authentication_failed(delete_session(conn, :oidc_authorization), ~p"/users/log-in")
  end

  def link_request(%{assigns: %{current_scope: %{user: user}}} = conn, _params) do
    case OIDC.linked?(user) do
      true ->
        conn
        |> put_flash(:info, "#{OIDC.provider_name()} is already connected.")
        |> redirect(to: ~p"/users/settings")

      false ->
        start_oidc_link(conn)
    end
  end

  defp start_oidc_link(conn) do
    with true <- OIDC.configured?(),
         {:ok, %{url: authorization_url, session: authorization}} <-
           OIDC.authorization_url(link_callback_url(conn)) do
      conn
      |> put_session(:oidc_authorization, authorization)
      |> redirect(external: authorization_url)
    else
      false -> connection_failed(conn)
      {:error, _reason} -> connection_failed(conn)
    end
  end

  def link_callback(conn, %{"error" => "access_denied", "state" => state}) do
    case pop_authorization(conn, state) do
      {:ok, conn, _authorization} ->
        conn
        |> put_flash(:error, "Connection was cancelled.")
        |> redirect(to: ~p"/users/settings")

      {:error, conn} ->
        connection_failed(conn)
    end
  end

  def link_callback(%{assigns: %{current_scope: %{user: user}}} = conn, %{
        "code" => code,
        "state" => state
      }) do
    case pop_authorization(conn, state) do
      {:ok, conn, authorization} ->
        case OIDC.link(user, code, authorization, link_callback_url(conn)) do
          {:ok, _identity} ->
            conn
            |> put_flash(:info, "#{OIDC.provider_name()} connected successfully.")
            |> redirect(to: ~p"/users/settings")

          {:error, _reason} ->
            connection_failed(conn)
        end

      {:error, conn} ->
        connection_failed(conn)
    end
  end

  def link_callback(conn, _params) do
    conn
    |> delete_session(:oidc_authorization)
    |> connection_failed()
  end

  def unlink(%{assigns: %{current_scope: %{user: user}}} = conn, _params) do
    case OIDC.unlink(user) do
      {:error, :not_found} ->
        conn
        |> put_flash(:error, "No OIDC account is connected.")
        |> redirect(to: ~p"/users/settings")

      {:ok, _identity} ->
        conn
        |> put_flash(:info, "#{OIDC.provider_name()} disconnected.")
        |> redirect(to: ~p"/users/settings")

      {:error, _reason} ->
        authentication_failed(
          conn,
          ~p"/users/settings",
          "Disconnection failed. Please try again."
        )
    end
  end

  defp pop_authorization(conn, state) do
    authorization = get_session(conn, :oidc_authorization)
    conn = delete_session(conn, :oidc_authorization)

    case authorization do
      %{state: ^state, nonce: nonce, pkce_verifier: pkce_verifier}
      when is_binary(nonce) and is_binary(pkce_verifier) ->
        {:ok, conn, authorization}

      _authorization ->
        {:error, conn}
    end
  end

  defp callback_url(_conn), do: url(~p"/auth/oidc/callback")
  defp link_callback_url(_conn), do: url(~p"/auth/oidc/link/callback")

  defp connection_failed(conn) do
    authentication_failed(conn, ~p"/users/settings", "Connection failed. Please try again.")
  end

  defp authentication_failed(
         conn,
         path,
         message \\ "Authentication failed. Please try again."
       ) do
    Logger.debug("OIDC operation failed")

    conn
    |> put_flash(:error, message)
    |> redirect(to: path)
  end
end
