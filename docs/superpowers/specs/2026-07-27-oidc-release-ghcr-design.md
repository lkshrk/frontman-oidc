# OIDC Fork Release and GHCR Design

## Goal

Match the proven `rybbit-oidc` release flow for Frontman:

1. Detect the latest stable upstream `vX.Y.Z` release.
2. Merge it into the OIDC fork and run the existing verification suite.
3. Tag the verified OIDC merge with the same `vX.Y.Z`.
4. Create or repair the same-version GitHub Release.
5. Explicitly dispatch a multi-architecture GHCR build for
   `ghcr.io/lkshrk/frontman-oidc`.

This publishes a container image, not a production deployment.

## Chosen Approach

Use the Rybbit pattern with a smaller Frontman-specific publishing workflow:

- The sync workflow remains the release coordinator.
- A successful sync creates the fork tag and GitHub Release.
- The sync workflow explicitly dispatches `docker-publish.yml`.
- The Docker workflow builds the existing
  `apps/frontman_server/Dockerfile` for `linux/amd64` and `linux/arm64`.
- Every release publishes `vX.Y.Z`; only the highest stable fork tag updates
  `latest`.
- Pull requests build `linux/amd64` without pushing, proving the image remains
  buildable.

An explicit `workflow_dispatch` is required because GitHub suppresses most
workflow recursion caused by `GITHUB_TOKEN`. It also makes release recovery
idempotent: explicitly rerunning sync can create a missing release or retry a
missing image without moving an already-correct tag. Scheduled no-op syncs do
not rebuild immutable images or close unresolved publication reports.

## Alternatives Rejected

### Build inside the sync workflow

Fewer workflow files, but a slow image build becomes coupled to merge and
failure-report logic. Retrying image publication would repeat upstream
verification.

### Trigger only from `release: published`

Smaller wiring, but release events created with `GITHUB_TOKEN` do not reliably
start downstream workflows. It would require `SYNC_TOKEN`, which is optional
today.

## Tag and Trust Model

The fork's `vX.Y.Z` tag points to the verified OIDC merge commit, matching the
Rybbit behavior. The sync workflow separately verifies the exact upstream tag
object and requires its commit to be an ancestor of the fork release commit.
An existing fork tag is accepted only when:

- its name is a stable semantic version;
- the exact upstream tag commit is an ancestor;
- its commit differs from the raw upstream tag commit;
- the fork tag commit is reachable from fork `main`.

The tag is never moved. A conflicting tag fails and opens the existing sync
failure PR.

## Release and Image Contract

- GitHub Release tag and title: `vX.Y.Z`
- Release notes: Frontman `vX.Y.Z` with OIDC login and group mapping
- Container repository: `ghcr.io/lkshrk/frontman-oidc`
- Container tags: every `vX.Y.Z`; `latest` only for the highest stable fork tag
- Architectures: `linux/amd64`, `linux/arm64`
- Authentication: built-in `GITHUB_TOKEN` with `packages: write`
- Extra secrets: none

## Verification

- A static workflow contract test first fails without release/dispatch/image
  wiring, then passes after implementation.
- Actionlint validates both workflows.
- A local Docker build validates the existing production Dockerfile.
- Pull-request CI performs an unpushed image build.
- The existing OIDC, OpenAI API, server, formatting, and static checks remain
  unchanged.

## Delivery

All OIDC work is squashed into one commit before the next push, then the PR is
updated with `--force-with-lease`.
