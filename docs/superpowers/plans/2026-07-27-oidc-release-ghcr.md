# OIDC Fork Release and GHCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish every successfully synchronized stable Frontman release as the same-version OIDC fork GitHub Release and multi-architecture GHCR image.

**Architecture:** Keep upstream merge verification in `oidc-upstream-sync.yml`. After verification, tag the OIDC merge commit as `vX.Y.Z`, create or repair the GitHub Release, and explicitly dispatch a separate Docker workflow because `GITHUB_TOKEN` suppresses ordinary event recursion. Build the existing server Dockerfile as one `linux/amd64` and `linux/arm64` image.

**Tech Stack:** GitHub Actions, GitHub CLI, Docker Buildx/QEMU, GHCR, GNU Make contract checks.

## Global Constraints

- Fork release tag and title are the exact upstream stable version `vX.Y.Z`.
- Fork tags point to the verified OIDC merge commit and never move.
- The exact upstream tag commit must be an ancestor of the fork tag commit.
- Publish every `ghcr.io/lkshrk/frontman-oidc:vX.Y.Z`; update
  `ghcr.io/lkshrk/frontman-oidc:latest` only for the highest stable fork tag.
- Publish `linux/amd64` and `linux/arm64`.
- Pull requests build `linux/amd64` without publishing.
- Use only `GITHUB_TOKEN`; add no secret or dependency.
- Do not deploy Frontman to production.
- Do not push until all OIDC work is squashed into one commit.

---

### Task 1: Lock the release contract

**Files:**
- Modify: `Makefile:214`
- Test: `Makefile:214`

**Interfaces:**
- Consumes: `.github/workflows/oidc-upstream-sync.yml`
- Produces: `make oidc-fork-contract`, which rejects missing release and image wiring

- [ ] **Step 1: Add failing assertions**

Extend `oidc-fork-contract` with exact checks:

```make
	@test -f .github/workflows/docker-publish.yml
	@rg -q 'ghcr.io/lkshrk/frontman-oidc' .github/workflows/docker-publish.yml
	@rg -q 'linux/amd64,linux/arm64' .github/workflows/docker-publish.yml
	@rg -q 'gh release (create|edit)' .github/workflows/oidc-upstream-sync.yml
	@rg -q 'gh workflow run docker-publish.yml' .github/workflows/oidc-upstream-sync.yml
```

- [ ] **Step 2: Run the contract and prove RED**

Run:

```bash
make oidc-fork-contract
```

Expected: failure because `.github/workflows/docker-publish.yml` does not exist.

- [ ] **Step 3: Keep the assertions for regression coverage**

Do not weaken the assertions after implementation. They are the smallest
runnable check that protects the fork-only release contract during future
upstream merges.

### Task 2: Add isolated Docker build and publication

**Files:**
- Create: `.github/workflows/docker-publish.yml`
- Test: `Makefile:214`

**Interfaces:**
- Consumes: `workflow_dispatch.inputs.tag` with stable `vX.Y.Z`
- Consumes: root build context and `apps/frontman_server/Dockerfile`
- Produces: `ghcr.io/lkshrk/frontman-oidc:vX.Y.Z` and conditional `:latest`

- [ ] **Step 1: Add workflow triggers and least privilege**

Create a workflow with:

```yaml
name: Docker Publish

on:
  workflow_dispatch:
    inputs:
      tag:
        description: "Stable fork release tag, for example v2.0.0"
        required: true
        type: string
  pull_request:
    branches:
      - main
    paths:
      - ".dockerignore"
      - "apps/frontman_server/**"
      - "apps/marketing/package.json"
      - "apps/swarm_ai/**"
      - "libs/**"
      - ".yarnrc.yml"
      - "package.json"
      - "test/**/package.json"
      - "yarn.lock"
      - "rescript.json"
      - ".github/workflows/docker-publish.yml"

permissions:
  contents: read
```

Use separate jobs so pull-request Docker builds never receive
`packages: write`.

- [ ] **Step 2: Add the pull-request build job**

Use pinned `actions/checkout`, `docker/setup-buildx-action`, and
`docker/build-push-action`. Build:

```yaml
context: .
file: apps/frontman_server/Dockerfile
platforms: linux/amd64
push: false
```

- [ ] **Step 3: Add the release publication job**

Give only this job `packages: write`. Put the input into an environment
variable and validate it before checkout:

```bash
if [[ ! "$RELEASE_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "::error::tag must be a stable semantic version"
  exit 1
fi
```

Checkout `refs/tags/${{ inputs.tag }}`, log in to `ghcr.io` with
`GITHUB_TOKEN`, and serialize publication jobs. Determine whether the input is
the highest stable fork tag, then build:

```yaml
context: .
file: apps/frontman_server/Dockerfile
platforms: linux/amd64,linux/arm64
push: true
tags: |
  ghcr.io/lkshrk/frontman-oidc:${{ inputs.tag }}
  ${{ steps.release.outputs.latest == 'true' && 'ghcr.io/lkshrk/frontman-oidc:latest' || '' }}
```

Use QEMU only in the publication job.

- [ ] **Step 4: Prove the Docker half of the contract is GREEN**

Run:

```bash
actionlint .github/workflows/docker-publish.yml
make oidc-fork-contract
```

Expected: Actionlint passes; the Make contract still fails only on missing
sync release/dispatch wiring.

### Task 3: Turn verified syncs into recoverable same-version releases

**Files:**
- Modify: `.github/workflows/oidc-upstream-sync.yml:23-579`
- Test: `Makefile:214`

**Interfaces:**
- Consumes: verified `UPSTREAM_TAG`, `UPSTREAM_TAG_COMMIT`, and candidate merge
- Produces: immutable fork tag, GitHub Release, and
  `workflow_dispatch(tag=vX.Y.Z)`

- [ ] **Step 1: Grant dispatch permission**

Change only the publish job:

```yaml
permissions:
  actions: write
  contents: write
  pull-requests: write
```

- [ ] **Step 2: Validate existing fork release tags by ancestry**

Replace the old equality requirement between fork tag object and upstream tag
object. For an existing `refs/tags/vX.Y.Z`, require:

```bash
git merge-base --is-ancestor "$UPSTREAM_TAG_COMMIT" "$FORK_TAG_COMMIT"
git merge-base --is-ancestor "$FORK_TAG_COMMIT" "origin/main"
```

Also reject a fork tag whose commit equals the raw upstream tag commit. If a
check fails, use the existing failure-report path. Never move the tag.

- [ ] **Step 3: Tag the verified OIDC merge**

Before the initial atomic publication:

```bash
git tag -a "$UPSTREAM_TAG" "$CANDIDATE_COMMIT" \
  -m "Frontman ${UPSTREAM_TAG} with OIDC"
```

Atomically push the candidate to `main` and this annotated fork tag. Continue
validating the exact upstream tag object imported from the verified bundle.

- [ ] **Step 4: Add idempotent release and dispatch**

Add a `publish_release` shell function that:

```bash
if gh release view "$UPSTREAM_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  gh release edit "$UPSTREAM_TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --title "$UPSTREAM_TAG" \
    --notes "Frontman ${UPSTREAM_TAG} with OIDC login and group mapping."
else
  gh release create "$UPSTREAM_TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --title "$UPSTREAM_TAG" \
    --verify-tag \
    --notes "Frontman ${UPSTREAM_TAG} with OIDC login and group mapping."
fi

gh workflow run docker-publish.yml \
  --repo "$GITHUB_REPOSITORY" \
  --ref "$UPSTREAM_TAG" \
  -f "tag=$UPSTREAM_TAG"
```

Call it after a new atomic tag push. In the already-correct-tag recovery path,
call it only for explicit `workflow_dispatch` retries; scheduled no-ops leave
immutable images and unresolved publication reports untouched. Route failures
through the existing publication failure PR.

- [ ] **Step 5: Prove the complete contract is GREEN**

Run:

```bash
make oidc-fork-contract
actionlint .github/workflows/oidc-upstream-sync.yml
actionlint .github/workflows/docker-publish.yml
git diff --check
```

Expected: all pass.

### Task 4: Verify the image and repository

**Files:**
- Verify: `apps/frontman_server/Dockerfile`
- Verify: all changed workflows and existing OIDC implementation

**Interfaces:**
- Consumes: completed release workflow implementation
- Produces: fresh build/test evidence suitable for the PR

- [ ] **Step 1: Build the production image locally**

Run the available local container engine with root context:

```bash
docker buildx build --platform linux/amd64 --load \
  -f apps/frontman_server/Dockerfile -t frontman-oidc:verify .
```

If Docker is unavailable, use the existing Podman environment:

```bash
podman build -f apps/frontman_server/Dockerfile -t frontman-oidc:verify .
```

Expected: image build succeeds.

- [ ] **Step 2: Run targeted and repository checks**

Run:

```bash
make oidc-fork-contract
actionlint .github/workflows/docker-publish.yml
actionlint .github/workflows/oidc-upstream-sync.yml
make -C apps/frontman_server format-check
make -C apps/frontman_server lint
make -C apps/frontman_server test
git diff --check
```

Expected: all pass.

- [ ] **Step 3: Confirm the live OpenAI API E2E result**

Inspect run `30232604763`. If it failed, diagnose and fix the root cause before
squashing. Do not hide or disable the check.

### Task 5: Squash and publish the branch

**Files:**
- Rewrite: branch history only

**Interfaces:**
- Consumes: verified feature branch and its merge base with upstream
- Produces: one OIDC feature commit on the existing pull request

- [ ] **Step 1: Resolve the exact squash base**

Run:

```bash
git merge-base HEAD upstream/main
git log --oneline --decorate <merge-base>..HEAD
```

Verify every commit in the range belongs to the OIDC fork work.

- [ ] **Step 2: Squash without losing the working tree**

Use a soft reset to the verified merge base and create one commit:

```bash
git reset --soft <merge-base>
git commit -m "feat: add OIDC authentication and fork automation"
```

Exclude `.agent-progress.md` and `.claude/`.

- [ ] **Step 3: Re-run the smallest proof after rewriting history**

Run:

```bash
make oidc-fork-contract
actionlint .github/workflows/docker-publish.yml
actionlint .github/workflows/oidc-upstream-sync.yml
git status --short
git log --oneline <merge-base>..HEAD
```

Expected: checks pass and exactly one commit is listed.

- [ ] **Step 4: Update the PR safely**

Run:

```bash
git push --force-with-lease fork feature/oidc-authentik
```

Monitor all PR checks and CodeRabbit. Fix valid findings, re-squash if another
commit is required, and do not claim completion until CI is terminal.
