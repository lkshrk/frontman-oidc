# OIDC and Authentik Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add secure Authentik-compatible OIDC login, managed organization
memberships, browser coverage, and low-maintenance upstream synchronization.

**Architecture:** Keep WorkOS intact and add dedicated OIDC routes, controller,
and account internals. Direct `oidcc` performs OIDC discovery and validation;
Frontman coordinates its existing account lifecycle with organization
membership synchronization.

**Tech Stack:** Elixir 1.20, Phoenix 1.8, Ecto/PostgreSQL, `oidcc` 3.7.x,
ExUnit, Vitest/Playwright, GitHub Actions.

## Global Constraints

- Keep existing WorkOS code, routes, and behavior available as fallback.
- Enable OIDC only when issuer, client ID, and client secret are configured.
- Require state, nonce, PKCE, and verified OIDC ID-token claims.
- Require non-empty issuer, subject, and email plus `email_verified == true`.
- Store the identity as provider `oidc` and provider ID
  `issuer <> "|" <> subject`.
- Match OIDC group values exactly to existing organization slugs.
- Never create organizations or grant `owner` from OIDC claims.
- Never change or remove manual memberships.
- Remove only stale OIDC-provisioned memberships whose role is `member`.
- Use no provider registry, group mapping parser, behavior module, or mocking
  dependency.
- Add `@spec` to every public Elixir function and obey
  `agent_docs/elixir-style.md`.
- Follow RED-GREEN-REFACTOR and observe each new test fail before implementation.
- Run Elixir commands in `frontman-oidc-elixir` with working directory
  `/workspace/apps/frontman_server`; local `mix` is unavailable.
- Do not commit `.agent-progress.md` or `.claude/`.

---

### Task 1: OIDC configuration and protocol client

**Files:**

- Modify: `apps/frontman_server/mix.exs`
- Modify: `apps/frontman_server/mix.lock`
- Modify: `apps/frontman_server/config/runtime.exs`
- Modify: `apps/frontman_server/config/test.exs`
- Modify: `apps/frontman_server/lib/frontman_server/application.ex`
- Create: `apps/frontman_server/lib/frontman_server/accounts/oidc.ex`
- Create: `apps/frontman_server/lib/frontman_server/accounts/oidc/client.ex`
- Create: `apps/frontman_server/test/support/oidc_client.ex`
- Create: `apps/frontman_server/test/frontman_server/accounts/oidc_test.exs`

**Interfaces:**

- `Accounts.OIDC.configured?/0 :: boolean()`
- `Accounts.OIDC.provider_name/0 :: String.t()`
- `Accounts.OIDC.children/0 :: [Supervisor.child_spec()]`
- `Accounts.OIDC.authorization_url/1 ::
  {:ok, %{url: String.t(), session: map()}} | {:error, term()}`
- `Accounts.OIDC.Client.authorization_url/4 ::
  {:ok, String.t()} | {:error, term()}`
- `Accounts.OIDC.Client.retrieve_claims/4 ::
  {:ok, map()} | {:error, term()}`
- The authorization session contains binary `state`, `nonce`, and
  `pkce_verifier` values.

- [ ] **Step 1: Write failing configuration and authorization-session tests**

  Test disabled configuration, enabled configuration, provider-name fallback,
  generation of distinct state/nonce/verifier values, and forwarding all
  security values to the configured test client.

- [ ] **Step 2: Run the focused test and verify RED**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix test test/frontman_server/accounts/oidc_test.exs`

  Expected: compilation failure because `FrontmanServer.Accounts.OIDC` does not
  exist.

- [ ] **Step 3: Add `oidcc` and runtime configuration**

  Add `{:oidcc, "~> 3.7"}`. Configure
  `FrontmanServer.Accounts.OIDC` from `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
  `OIDC_CLIENT_SECRET`, `OIDC_PROVIDER_NAME`, and `OIDC_GROUP_CLAIM`.

- [ ] **Step 4: Implement the minimal client boundary**

  Generate 32 random bytes for state, nonce, and PKCE verifier and encode them
  with URL-safe Base64 without padding. Start one
  `Oidcc.ProviderConfiguration.Worker` only when configured. The client wrapper
  uses the registered worker to create the authorization URL and retrieve
  validated claims with required PKCE, nonce, redirect URI, and
  `openid email profile` scopes.

- [ ] **Step 5: Run tests and verify GREEN**

  Run the focused test command from Step 2, then:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix compile --warnings-as-errors`

- [ ] **Step 6: Commit**

  Commit message: `feat(auth): add OIDC protocol client`

### Task 2: OIDC-managed organization memberships

**Files:**

- Create:
  `apps/frontman_server/priv/repo/migrations/20260727000000_add_membership_provisioner.exs`
- Modify:
  `apps/frontman_server/lib/frontman_server/organizations/membership.ex`
- Modify:
  `apps/frontman_server/lib/frontman_server/organizations/organization.ex`
- Modify: `apps/frontman_server/lib/frontman_server/organizations.ex`
- Modify: `apps/frontman_server/test/frontman_server/organizations_test.exs`

**Interfaces:**

- `Membership.provisioner` is `:manual | :oidc`, default `:manual`, stored as
  a non-null string.
- `Organizations.sync_oidc_memberships/2 ::
  {:ok, %{created: non_neg_integer(), removed: non_neg_integer()}} |
  {:error, term()}`
- The first argument is `%Accounts.Scope{user: %User{}}`; the second is a list
  of organization slug strings.

- [ ] **Step 1: Write failing membership synchronization tests**

  Cover exact-slug insertion as `member`/`oidc`, unknown slugs ignored, stale
  OIDC members removed, manual members preserved, owners preserved, duplicate
  group strings ignored, and repeated synchronization idempotent.

- [ ] **Step 2: Run the focused test and verify RED**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix test test/frontman_server/organizations_test.exs`

  Expected: failure because `sync_oidc_memberships/2` and `provisioner` do not
  exist.

- [ ] **Step 3: Add membership provenance**

  Add the migration and Ecto enum field. Existing rows and normal
  `add_member/3` calls remain manual.

- [ ] **Step 4: Implement synchronization in one transaction**

  Query matching organizations and the user's memberships in batches. Insert
  only missing exact matches. Delete only rows where provisioner is `oidc`,
  role is `member`, and the organization is no longer desired. Never update an
  existing membership.

- [ ] **Step 5: Run migration and tests; verify GREEN**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir bash -lc 'MIX_ENV=test mix ecto.migrate && mix test test/frontman_server/organizations_test.exs'`

- [ ] **Step 6: Commit**

  Commit message: `feat(auth): sync OIDC organization memberships`

### Task 3: OIDC account lifecycle and login coordinator

**Files:**

- Modify:
  `apps/frontman_server/lib/frontman_server/accounts/workos.ex`
- Modify: `apps/frontman_server/lib/frontman_server/accounts/oidc.ex`
- Modify: `apps/frontman_server/lib/frontman_server/accounts.ex`
- Create: `apps/frontman_server/lib/frontman_server/oidc_login.ex`
- Modify: `apps/frontman_server/test/frontman_server/accounts/oidc_test.exs`
- Create: `apps/frontman_server/test/frontman_server/oidc_login_test.exs`

**Interfaces:**

- `Accounts.OIDC.authenticate/4 ::
  {:ok, User.t(), [String.t()]} | {:error, term()}`
- `Accounts.OIDC.link/4 ::
  {:ok, UserIdentity.t()} | {:error, term()}`
- `Accounts.OIDC.unlink/1 ::
  {:ok, UserIdentity.t()} | {:error, term()}`
- `FrontmanServer.OIDCLogin.authenticate/4 ::
  {:ok, User.t()} | {:error, term()}`
- `WorkOS.upsert_oauth_profile/2` exposes the current generic profile-to-user
  transaction inside the Accounts boundary without changing its behavior.

- [ ] **Step 1: Write failing claim/account tests**

  Cover rejection of missing issuer, subject, email, and unverified email;
  existing OIDC identity login; verified-email account linking; new-user
  creation; normalized unique group extraction; account linking; and unlinking.

- [ ] **Step 2: Write failing coordinator tests**

  Cover successful account login followed by organization synchronization and
  propagation of a synchronization error without creating a Frontman session.

- [ ] **Step 3: Run focused tests and verify RED**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix test test/frontman_server/accounts/oidc_test.exs test/frontman_server/oidc_login_test.exs`

- [ ] **Step 4: Reuse the existing account transaction**

  Promote the current WorkOS profile upsert helper to an internal public
  function with an explicit map type/spec. Do not copy the user creation,
  welcome email, contact sync, Discord notification, or identity-update logic.

- [ ] **Step 5: Implement validated claim conversion and coordination**

  Convert claims to the existing OAuth profile shape only after validation.
  Extract the configured group claim as unique binary strings. Coordinate
  successful authentication with `Organizations.sync_oidc_memberships/2`.

- [ ] **Step 6: Run focused tests and verify GREEN**

  Run the command from Step 3.

- [ ] **Step 7: Commit**

  Commit message: `feat(auth): connect OIDC accounts`

### Task 4: OIDC routes, controller, and login UI

**Files:**

- Modify: `apps/frontman_server/lib/frontman_server_web/router.ex`
- Create:
  `apps/frontman_server/lib/frontman_server_web/controllers/oidc_controller.ex`
- Modify:
  `apps/frontman_server/lib/frontman_server_web/controllers/user_session_controller.ex`
- Modify:
  `apps/frontman_server/lib/frontman_server_web/controllers/user_session_html/new.html.heex`
- Modify:
  `apps/frontman_server/lib/frontman_server_web/controllers/user_settings_html/edit.html.heex`
- Create:
  `apps/frontman_server/test/frontman_server_web/controllers/oidc_controller_test.exs`
- Modify:
  `apps/frontman_server/test/frontman_server_web/controllers/user_session_controller_test.exs`

**Interfaces:**

- Dedicated routes:
  `/auth/oidc`, `/auth/oidc/callback`, `/auth/oidc/link`,
  `/auth/oidc/link/callback`, and `/auth/oidc/unlink`.
- Session key `:oidc_authorization` stores the authorization session map.
- The configured provider name is assigned by `UserSessionController.new/2`.

- [ ] **Step 1: Write failing controller and UI tests**

  Cover OIDC request redirect/session storage, exact state validation,
  one-time session deletion, access-denied handling, successful login, failed
  authentication, sudo-protected link/unlink, OIDC button visibility when
  configured, and WorkOS button fallback when not configured.

- [ ] **Step 2: Run focused tests and verify RED**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix test test/frontman_server_web/controllers/oidc_controller_test.exs test/frontman_server_web/controllers/user_session_controller_test.exs`

- [ ] **Step 3: Add static routes before WorkOS dynamic routes**

  Keep the existing `OAuthController` and its routes unchanged.

- [ ] **Step 4: Implement the controller**

  Remove the authorization session before validating callback state. Return
  expected provider cancellation and validation failures to the appropriate
  login/settings page. Log technical failures without claims, codes, tokens,
  or secrets.

- [ ] **Step 5: Update login and settings UI**

  Show one provider-named OIDC button when configured. Otherwise render the
  existing GitHub and Google buttons unchanged. Expose OIDC link/unlink beside
  the existing identity controls.

- [ ] **Step 6: Run focused and existing OAuth tests; verify GREEN**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix test test/frontman_server_web/controllers/oidc_controller_test.exs test/frontman_server_web/controllers/oauth_controller_test.exs test/frontman_server_web/controllers/user_session_controller_test.exs`

- [ ] **Step 7: Commit**

  Commit message: `feat(auth): add Authentik login flow`

### Task 5: Local OIDC browser test

**Files:**

- Create: `test/e2e/oidc/provider.mjs`
- Create: `test/e2e/oidc/run.mjs`
- Create: `test/e2e/oidc/oidc.test.ts`
- Modify: `test/e2e/package.json`
- Modify: `Makefile`

**Interfaces:**

- `make e2e-oidc` starts a local OIDC provider and a Phoenix E2E server, runs
  only the OIDC Playwright/Vitest test, and always terminates child processes.
- The provider serves discovery, JWKS, authorization, token, and userinfo
  endpoints and signs an RS256 ID token containing verified email and groups.

- [ ] **Step 1: Write the browser test**

  Specify the configured provider button, provider approval page, callback,
  authenticated Frontman page, user email, and matching organization
  membership.

- [ ] **Step 2: Run the test and verify RED**

  Run: `make e2e-oidc`

  Expected: failure because the target and local provider runner do not exist.

- [ ] **Step 3: Adapt the Rybbit mock provider**

  Copy only the protocol behavior from
  `/private/tmp/rybbit-oidc-compare.w4LQk0/rybbit-oidc/e2e/oidc/provider.mjs`.
  Remove Rybbit-specific databases, services, and runner assumptions.

- [ ] **Step 4: Implement the runner and verify GREEN**

  Run: `make e2e-oidc`

- [ ] **Step 5: Commit**

  Commit message: `test(auth): cover OIDC login end to end`

### Task 6: Upstream release synchronization

**Files:**

- Create: `.github/workflows/oidc-upstream-sync.yml`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `apps/frontman_server/envs/.dev.secrets.env`

**Interfaces:**

- Workflow inputs: optional `tag` and boolean `dry_run`.
- Schedule: daily at `04:00 UTC`.
- Upstream: `https://github.com/frontman-ai/frontman.git`.
- Target branch: `main`.
- Failure report branch prefix: `sync-report/`.

- [ ] **Step 1: Write workflow contract assertions**

  Add a small shell validation step in the workflow that fails when required
  files or commands are absent after the upstream merge. Validate the workflow
  syntax locally with the repository's existing YAML tooling.

- [ ] **Step 2: Implement release detection and merge**

  Fetch the requested or newest upstream release tag. Skip an already-tagged
  fork release. Merge into a temporary local branch with a concurrency guard.

- [ ] **Step 3: Implement validation and publication**

  Run server format, strict Credo, compile with warnings as errors, full ExUnit,
  and `make e2e-oidc`. On success update `main` and create the matching tag. In
  dry-run mode perform all checks without pushing.

- [ ] **Step 4: Implement conflict/failure pull requests**

  Abort a conflicted merge, retain candidate bundles as immutable artifacts,
  and create or update one report-only PR based on trusted fork `main`. Apply
  the same PR path for failed checks. Never push failed candidate code or
  force-push `main`.

- [ ] **Step 5: Document Authentik configuration**

  Document the exact issuer shape, callback URL, required claims, group-to-slug
  behavior, and required environment variables. Add OIDC secret references to
  the development secrets file.

- [ ] **Step 6: Add the changelog entry**

  Add an Unreleased entry describing generic OIDC login and managed
  organization membership synchronization. The Elixir application has no
  Changesets package, so use the repository's allowed direct `CHANGELOG.md`
  path.

- [ ] **Step 7: Verify and commit**

  Run YAML parsing, `git diff --check`, and the focused workflow validation.
  Commit message: `ci: sync OIDC fork with upstream releases`

### Task 7: Full verification

**Files:**

- Modify only files required to fix verification failures.

- [ ] **Step 1: Run formatting**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix format --check-formatted`

- [ ] **Step 2: Run strict static checks**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix compile --warnings-as-errors --all-warnings`

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir mix credo --strict`

- [ ] **Step 3: Run the complete server suite**

  Run:
  `docker exec -w /workspace/apps/frontman_server frontman-oidc-elixir make test`

- [ ] **Step 4: Run browser coverage**

  Run: `make e2e-oidc`

- [ ] **Step 5: Verify repository state**

  Run `git diff --check`, inspect the complete branch diff against
  `6237f9c6`, and confirm no secrets, generated build output,
  `.agent-progress.md`, or `.claude/` files are tracked.

- [ ] **Step 6: Commit verification fixes**

  If verification required changes, commit them as
  `fix(auth): address OIDC verification findings`.
