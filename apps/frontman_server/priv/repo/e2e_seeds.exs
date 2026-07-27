# E2E test seed script.
#
# Creates a confirmed test user and inserts Anthropic-compatible or OpenAI OAuth credentials.
# Reads credential values from environment variables (set them in CI or locally).
#
# Usage:
#   MIX_ENV=e2e mix run priv/repo/e2e_seeds.exs

alias FrontmanServer.Accounts
alias FrontmanServer.Accounts.Scope
alias FrontmanServer.Providers
alias FrontmanServer.Providers.OAuthToken
alias FrontmanServer.Repo

# ── 1. Create (or find) the e2e test user ──────────────────────────────────────

e2e_email = "e2e@frontman.local"
e2e_password = "e2epassword123!"

user =
  case Accounts.get_user_by_email(e2e_email) do
    nil ->
      {:ok, user} =
        Accounts.register_user(%{
          email: e2e_email,
          name: "E2E Test User",
          password: e2e_password
        })

      # Auto-confirm the user so they can log in immediately
      user
      |> Accounts.User.confirm_changeset()
      |> Repo.update!()

    existing ->
      existing
  end

IO.puts("E2E user: #{user.email} (id: #{user.id})")

# ── 2. Insert provider credentials (from env vars) ────────────────────────────

anthropic_auth_token = System.get_env("ANTHROPIC_AUTH_TOKEN")
access_token = System.get_env("E2E_OPENAI_ACCESS_TOKEN")
refresh_token = System.get_env("E2E_OPENAI_REFRESH_TOKEN")
account_id = System.get_env("E2E_OPENAI_ACCOUNT_ID")
token_present? = fn value -> is_binary(value) and value != "" end

cond do
  token_present?.(anthropic_auth_token) ->
    {:ok, _oauth_token} =
      Providers.upsert_oauth_token(
        Scope.for_user(user),
        "anthropic",
        anthropic_auth_token,
        "e2e-unused-refresh-token",
        DateTime.add(DateTime.utc_now(), 86_400, :second)
      )

    IO.puts("Anthropic-compatible auth token seeded for #{user.email}")

  token_present?.(access_token) and token_present?.(refresh_token) ->
    # Delete any existing token for this user+provider to allow re-seeding
    OAuthToken.for_user_and_provider(user.id, "openai_codex")
    |> Repo.delete_all()

    # Cloak encrypts the tokens transparently via the Ecto type
    %OAuthToken{user_id: user.id}
    |> OAuthToken.changeset(%{
      provider: "openai_codex",
      access_token: access_token,
      refresh_token: refresh_token,
      # Set expires_at far in the future so the server uses the access_token
      # directly without attempting a refresh_token exchange (which burns the
      # single-use refresh token and causes "refresh_token_reused" errors on
      # subsequent CI runs).
      expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second),
      metadata: %{"account_id" => account_id || "e2e-account"}
    })
    |> Repo.insert!()

    IO.puts("OpenAI OAuth token seeded for #{user.email}")

  true ->
    IO.puts("Skipping provider credential seed — set Anthropic or OpenAI OAuth credentials")
end
