# OIDC and Authentik Integration Design

## Goal

Add standards-based OIDC login for Authentik while keeping this fork easy to
synchronize with `frontman-ai/frontman`.

The integration is additive. Existing WorkOS code, routes, and behavior remain
available as an upstream-compatible fallback.

## Chosen approach

Use direct `oidcc` 3.7.x integration in a new OIDC module and controller.

`oidcc` owns discovery, authorization URL construction, code exchange, and ID
token validation, including issuer, audience, expiry, `azp`, nonce, and PKCE
checks. Frontman owns session persistence, user/identity updates, and
organization membership synchronization.

Alternatives rejected:

- Replacing WorkOS: cleaner standalone fork, but it modifies more upstream-owned
  code and creates recurring merge conflicts.
- Reverse-proxy authentication: fewer application changes, but it bypasses
  Frontman's identity linking and session lifecycle.
- Ueberauth or Assent: both work, but add framework machinery or more
  security-sensitive session plumbing than direct `oidcc`.

## Configuration

OIDC is enabled only when all required values exist:

- `OIDC_ISSUER`
- `OIDC_CLIENT_ID`
- `OIDC_CLIENT_SECRET`

Optional values:

- `OIDC_PROVIDER_NAME`, default `Single Sign-On`
- `OIDC_GROUP_CLAIM`, default `groups`

For Authentik, `OIDC_ISSUER` is the application-specific issuer:

`https://auth.example.com/application/o/frontman/`

Frontman derives the callback URL as `/auth/oidc/callback`.

No generic provider registry or mapping configuration is added. Authentik group
claim values must exactly match existing Frontman organization slugs.

## Runtime architecture

When OIDC is configured, the application supervision tree starts one
`Oidcc.ProviderConfiguration.Worker` registered under a Frontman-owned name.
When it is not configured, no worker starts and upstream WorkOS behavior is
unchanged.

New dedicated routes are declared before the existing dynamic WorkOS routes:

- `GET /auth/oidc`
- `GET /auth/oidc/callback`
- `GET /auth/oidc/link`
- `GET /auth/oidc/link/callback`
- `DELETE /auth/oidc/unlink`

A new `OIDCController` handles only those routes. The existing
`OAuthController` remains responsible for WorkOS.

The login page shows the configured OIDC provider button when OIDC is enabled.
WorkOS buttons remain visible only when OIDC is not enabled. This keeps the
production login surface unambiguous without deleting upstream UI.

## Login flow

1. Generate cryptographically random state, nonce, and PKCE verifier.
2. Store them in the encrypted Phoenix session.
3. Redirect through `oidcc` with `openid email profile` scopes and required PKCE.
4. On callback, atomically remove the stored authorization session values.
5. Require an exact state match.
6. Exchange the code through `oidcc`, requiring the stored nonce, verifier, and
   callback URL.
7. Require non-empty `iss`, `sub`, and `email` claims plus
   `email_verified == true`.
8. Use provider `oidc` and provider identity `issuer <> "|" <> subject`.
9. Reuse Frontman's current create/link/login behavior and signup side effects.
10. Synchronize OIDC-managed organization memberships.
11. Establish the normal Frontman user session.

Authorization failures return to the login page with the existing generic
authentication failure message. Detailed causes are logged without tokens or
secrets.

## Identity linking

The authenticated link flow uses a separate OIDC authorization session and the
same token validation rules. It creates an `oidc` identity for the current user.

Email matching is allowed only after `oidcc` validation and explicit
`email_verified == true`.

Unlinking removes only the `oidc` identity and preserves Frontman's existing
identity/session rules.

## Organization group synchronization

Frontman already models groups as organizations and supports `owner` and
`member` membership roles.

An additive membership provenance column distinguishes `manual` and `oidc`
memberships. Existing and newly manual memberships default to `manual`.

After each successful OIDC login:

- each verified group claim is matched exactly to an existing organization slug;
- missing matches are ignored;
- missing memberships are inserted as `member` with OIDC provenance;
- manual memberships are never modified or removed;
- OIDC-provisioned `member` memberships absent from the latest claims are removed;
- `owner` is never granted by OIDC;
- an OIDC membership promoted to `owner` is retained even when its group is removed.

Organizations are never created from claims.

## Tests

Test-driven implementation covers:

- OIDC configuration enablement;
- authorization session creation with state, nonce, and PKCE;
- callback rejection for missing/mismatched state;
- callback rejection for unverified email or incomplete identity claims;
- successful new-user, existing-identity, and verified-email-link login paths;
- OIDC account linking and unlinking;
- exact-slug group membership creation;
- removal of stale OIDC-managed member memberships;
- preservation of manual memberships and owners;
- login-page provider selection.

The OIDC library boundary is replaceable through application configuration in
tests; no behavior module or mocking dependency is introduced.

A small local mock OIDC provider supplies discovery, JWKS, authorization, token,
and userinfo endpoints for one browser-level login test. It reuses the
standards-shaped provider pattern proven in `lkshrk/rybbit-oidc` without its
analytics infrastructure.

## Upstream synchronization

A single workflow runs daily and manually:

1. Fetch the newest upstream Frontman release tag.
2. Skip tags already present in the fork.
3. Merge the upstream tag into a temporary sync branch.
4. Run Frontman's existing checks plus the OIDC login tests.
5. On success, update the fork target branch and create the matching tag.
6. On conflict or failed checks, retain the candidate bundle as an immutable
   artifact and open or update a report-only pull request based on trusted fork
   `main`.

The workflow hardcodes this fork's upstream and checks. It does not copy
Rybbit's generic JSON sync configuration.

## Scope exclusions

- No Authentik-driven organization creation.
- No Authentik-driven owner grants.
- No arbitrary group-to-organization mapping parser.
- No replacement or deletion of WorkOS code.
- No multi-OIDC-provider registry.
- No refresh-token storage; login uses the ID token only to establish Frontman's
  existing application session.
