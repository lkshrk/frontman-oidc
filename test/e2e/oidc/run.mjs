import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

async function availablePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close(() => resolvePort(address.port));
    });
  });
}

const ROOT = resolve(import.meta.dirname, "../../..");
const SERVER_DIR = resolve(ROOT, "apps/frontman_server");
const E2E_DIR = resolve(ROOT, "test/e2e");
const [providerPort, frontmanPort] = await Promise.all([
  availablePort(),
  availablePort(),
]);
const ISSUER = `http://127.0.0.1:${providerPort}`;
const FRONTMAN = `https://localhost:${frontmanPort}`;

const env = {
  ...process.env,
  MIX_ENV: "e2e",
  PHX_SERVER: "true",
  FRONTMAN_E2E_PORT: String(frontmanPort),
  FRONTMAN_E2E_URL: FRONTMAN,
  OIDC_ISSUER: ISSUER,
  OIDC_CLIENT_ID: "frontman-e2e",
  OIDC_CLIENT_SECRET: "frontman-e2e-secret",
  OIDC_PROVIDER_NAME: "Authentik",
  OIDC_GROUP_CLAIM: "groups",
};

const children = new Set();
let certificateDirectory;
let cleanupPromise;

function ensureCertificates() {
  certificateDirectory = mkdtempSync(resolve(tmpdir(), "frontman-oidc-e2e-"));
  const certFile = resolve(certificateDirectory, "frontman.local.pem");
  const keyFile = resolve(certificateDirectory, "frontman.local-key.pem");
  env.FRONTMAN_E2E_CERTFILE = certFile;
  env.FRONTMAN_E2E_KEYFILE = keyFile;
  execFileSync(
    "openssl",
    [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      keyFile,
      "-out",
      certFile,
      "-days",
      "1",
      "-subj",
      "/CN=localhost",
    ],
    { stdio: "ignore" },
  );
  chmodSync(keyFile, 0o600);
}

function cleanupCertificates() {
  if (!certificateDirectory) return;
  rmSync(certificateDirectory, { force: true, recursive: true });
}

function resolveBin(name) {
  let directory = E2E_DIR;
  while (true) {
    const candidate = resolve(directory, "node_modules/.bin", name);
    if (existsSync(candidate)) return candidate;
    const parent = resolve(directory, "..");
    if (parent === directory) throw new Error(`Cannot find ${name}`);
    directory = parent;
  }
}

function start(command, args, options = {}) {
  const child = spawn(command, args, {
    ...options,
    detached: process.platform !== "win32",
    env,
    stdio: "inherit",
  });
  children.add(child);
  child.spawnError = null;
  child.once("error", (error) => {
    child.spawnError = error;
  });
  child.failure = new Promise((_, reject) => {
    child.once("error", (error) => reject(error));
    child.once("exit", (code, signal) => {
      reject(
        new Error(
          `${command} exited before becoming ready (${signal ?? code ?? "unknown"})`,
        ),
      );
    });
  });
  child.failure.catch(() => {});
  child.once("exit", () => children.delete(child));
  return child;
}

function waitForExit(child) {
  if (child.spawnError) return Promise.reject(child.spawnError);
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  }
  return new Promise((resolveExit, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => resolveExit({ code, signal }));
  });
}

async function stop(child) {
  if (!child.pid || child.exitCode !== null) return;
  try {
    process.kill(
      process.platform === "win32" ? child.pid : -child.pid,
      "SIGTERM",
    );
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
  await Promise.race([
    waitForExit(child),
    new Promise((resolveWait) => setTimeout(resolveWait, 5_000)),
  ]);
  if (child.exitCode === null) {
    try {
      process.kill(
        process.platform === "win32" ? child.pid : -child.pid,
        "SIGKILL",
      );
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
}

function cleanup() {
  cleanupPromise ??= (async () => {
    try {
      await Promise.allSettled([...children].map(stop));
    } finally {
      cleanupCertificates();
    }
  })();
  return cleanupPromise;
}

async function waitFor(url, label, child) {
  const poll = async () => {
    const deadline = Date.now() + 60_000;
    while (Date.now() < deadline) {
      try {
        const response = await fetch(url, {
          signal: AbortSignal.timeout(Math.min(5_000, deadline - Date.now())),
        });
        if (response.ok || response.status === 302) return;
      } catch {
        // Process is still starting.
      }
      await new Promise((resolveWait) => setTimeout(resolveWait, 250));
    }
    throw new Error(`${label} did not become ready at ${url}`);
  };

  await Promise.race([poll(), child.failure]);
}

function mix(args, stdio = "inherit") {
  execFileSync("mix", args, { cwd: SERVER_DIR, env, stdio });
}

function make(args) {
  execFileSync("make", args, { cwd: SERVER_DIR, env, stdio: "inherit" });
}

function resetDatabaseFixtures() {
  const script = `
    import Ecto.Query
    alias FrontmanServer.Accounts
    alias FrontmanServer.Accounts.UserIdentity
    alias FrontmanServer.Organizations.Organization
    alias FrontmanServer.Repo

    if user = Accounts.get_user_by_email("oidc-user@example.com") do
      Repo.delete!(user)
    end

    if user = Accounts.get_user_by_email("e2e@frontman.local") do
      UserIdentity
      |> UserIdentity.for_user_and_provider(user.id, "oidc")
      |> Repo.delete_all()
    end

    unless Repo.one(Organization.by_slug("oidc-team")) do
      %Organization{}
      |> Organization.changeset(%{name: "OIDC Team", slug: "oidc-team"})
      |> Repo.insert!()
    end
  `;

  mix(["ecto.create", "--quiet"], "pipe");
  mix(["ecto.migrate", "--quiet"], "pipe");
  mix(["run", "priv/repo/e2e_seeds.exs"]);
  mix(["run", "-e", script], "pipe");
}

async function main() {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0";
  try {
    ensureCertificates();
    const provider = start(process.execPath, [
      resolve(import.meta.dirname, "provider.mjs"),
    ]);
    await waitFor(`${ISSUER}/health`, "OIDC provider", provider);

    make(["assets-setup", "assets-build-app"]);
    resetDatabaseFixtures();
    const phoenix = start("mix", ["phx.server"], { cwd: SERVER_DIR });
    await waitFor(`${FRONTMAN}/users/log-in`, "Phoenix", phoenix);

    const vitest = start(
      process.execPath,
      [resolveBin("vitest"), "run", "--config", "oidc/vitest.config.ts"],
      { cwd: E2E_DIR },
    );
    const result = await waitForExit(vitest);
    process.exitCode = result.code ?? 1;
  } finally {
    await cleanup();
  }
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, async () => {
    await cleanup();
    process.exit(128 + (signal === "SIGINT" ? 2 : 15));
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
