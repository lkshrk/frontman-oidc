import { execFileSync } from "node:child_process";
import { chromium, type Browser, type Page } from "playwright";
import { afterAll, beforeAll, describe, expect, test } from "vitest";

import { login } from "../helpers/auth";

const FRONTMAN = process.env.FRONTMAN_E2E_URL ?? "https://localhost:4002";
const PROVIDER = process.env.OIDC_ISSUER ?? "http://127.0.0.1:3556";
const OIDC_EMAIL = "oidc-user@example.com";
const LINK_EMAIL = "e2e@frontman.local";
const SERVER_DIR = new URL("../../../apps/frontman_server/", import.meta.url);

let browser: Browser;

async function setProviderIdentity(
  page: Page,
  identity: { subject: string; email: string; groups: string[] },
): Promise<void> {
  const response = await page.request.post(`${PROVIDER}/__test/identity`, {
    data: identity,
  });
  expect(response.status()).toBe(204);
}

async function setTokenMode(
  page: Page,
  mode: "valid" | "invalid_signature" | "wrong_nonce" | "unverified_email",
): Promise<void> {
  const response = await page.request.post(`${PROVIDER}/__test/token-mode`, {
    data: { mode },
  });
  expect(response.status()).toBe(204);
}

async function approve(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Approve" }).click();
  await page.waitForURL((url) => url.origin === FRONTMAN, { timeout: 30_000 });
}

async function startLogin(page: Page): Promise<URL> {
  await page.goto(`${FRONTMAN}/users/log-in`);
  expect(
    await page.getByRole("link", { name: "Login with Authentik" }).isVisible(),
  ).toBe(true);
  await page.getByRole("link", { name: "Login with Authentik" }).click();
  await page.waitForURL(`${PROVIDER}/authorize?*`);

  const authorizationUrl = new URL(page.url());
  expect(
    await page.getByRole("heading", { name: "Approve Frontman" }).isVisible(),
  ).toBe(true);
  expect(authorizationUrl.searchParams.get("state")).toMatch(
    /^[A-Za-z0-9_-]{43}$/,
  );
  expect(authorizationUrl.searchParams.get("nonce")).toMatch(
    /^[A-Za-z0-9_-]{43}$/,
  );
  expect(authorizationUrl.searchParams.get("code_challenge")).toMatch(
    /^[A-Za-z0-9_-]{43}$/,
  );
  expect(authorizationUrl.searchParams.get("code_challenge_method")).toBe(
    "S256",
  );
  return authorizationUrl;
}

function organizationSlugs(email: string): string[] | null {
  const script = `
    alias FrontmanServer.Accounts
    alias FrontmanServer.Accounts.Scope
    alias FrontmanServer.Organizations
    alias FrontmanServer.Repo
    {:ok, _applications} = Application.ensure_all_started(:ecto_sql)
    {:ok, _repo} = Repo.start_link()
    case Accounts.get_user_by_email(${JSON.stringify(email)}) do
      nil -> nil
      user ->
        user
        |> Scope.for_user()
        |> Organizations.list_organizations()
        |> Enum.map(& &1.slug)
    end
    |> Jason.encode!()
    |> then(&IO.puts("<<<ORG_SLUGS>>>#{&1}<<</ORG_SLUGS>>>"))
  `;
  const output = execFileSync("mix", ["run", "--no-start", "-e", script], {
    cwd: SERVER_DIR,
    env: { ...process.env, MIX_ENV: "e2e" },
    encoding: "utf8",
  });
  const payload = output.match(
    /<<<ORG_SLUGS>>>(.*?)<<<\/ORG_SLUGS>>>/s,
  )?.[1];
  if (payload === undefined) {
    throw new Error("OIDC organization query did not emit its payload");
  }
  return JSON.parse(payload);
}

async function expectRejectedToken(
  page: Page,
  mode: "invalid_signature" | "wrong_nonce" | "unverified_email",
): Promise<void> {
  const email = `${mode}@example.com`;
  await setProviderIdentity(page, {
    subject: `oidc-${mode}`,
    email,
    groups: ["oidc-team"],
  });
  await setTokenMode(page, mode);
  await startLogin(page);
  await approve(page);
  expect(
    await page
      .getByText("Authentication failed. Please try again.")
      .isVisible(),
  ).toBe(true);
  expect(organizationSlugs(email)).toBeNull();
}

beforeAll(async () => {
  browser = await chromium.launch({ headless: true });
});

afterAll(async () => {
  await browser?.close();
});

describe.sequential("OIDC browser flow", () => {
  test("logs in, enforces protocol checks, synchronizes groups, and links accounts", async () => {
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();

    await setProviderIdentity(page, {
      subject: "oidc-e2e-user",
      email: OIDC_EMAIL,
      groups: ["oidc-team", "OIDC-Team", "missing-team"],
    });

    await startLogin(page);
    await approve(page);
    await page.goto(`${FRONTMAN}/users/settings`);
    expect(await page.locator(`input[value="${OIDC_EMAIL}"]`).count()).toBe(1);
    expect(organizationSlugs(OIDC_EMAIL)).toEqual(["oidc-team"]);

    await context.clearCookies();
    await setProviderIdentity(page, {
      subject: "oidc-e2e-user",
      email: OIDC_EMAIL,
      groups: [],
    });
    await startLogin(page);
    await approve(page);
    expect(organizationSlugs(OIDC_EMAIL)).toEqual([]);

    await context.clearCookies();
    const authorizationUrl = await startLogin(page);
    const wrongState = `${authorizationUrl.searchParams.get("state")}-wrong`;
    await page.goto(
      `${FRONTMAN}/auth/oidc/callback?code=unused&state=${wrongState}`,
    );
    expect(
      await page
        .getByText("Authentication failed. Please try again.")
        .isVisible(),
    ).toBe(true);

    for (const mode of [
      "invalid_signature",
      "wrong_nonce",
      "unverified_email",
    ] as const) {
      await context.clearCookies();
      await expectRejectedToken(page, mode);
    }

    await context.clearCookies();
    await login(page);
    await setProviderIdentity(page, {
      subject: "oidc-linked-user",
      email: LINK_EMAIL,
      groups: [],
    });
    await page.goto(`${FRONTMAN}/users/settings`);
    await page.locator('a[href="/auth/oidc/link"]').click();
    await approve(page);
    expect(await page.locator('a[href="/auth/oidc/unlink"]').count()).toBe(1);
    expect(
      await page.getByText(LINK_EMAIL, { exact: true }).count(),
    ).toBeGreaterThan(0);

    await page.getByRole("link", { name: "Disconnect" }).click();
    await page.waitForURL(`${FRONTMAN}/users/settings`);
    expect(await page.locator('a[href="/auth/oidc/link"]').count()).toBe(1);

    await context.close();
  });
});
