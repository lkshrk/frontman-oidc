import crypto from "node:crypto";
import http from "node:http";

const issuer = process.env.OIDC_ISSUER ?? "http://127.0.0.1:3556";
const frontman = process.env.FRONTMAN_E2E_URL ?? "https://localhost:4002";
const clientId = process.env.OIDC_CLIENT_ID ?? "frontman-e2e";
const clientSecret = process.env.OIDC_CLIENT_SECRET ?? "frontman-e2e-secret";
const port = Number(new URL(issuer).port || 80);

const { privateKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 2048,
});
const { privateKey: invalidPrivateKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 2048,
});
const jwk = crypto.createPublicKey(privateKey).export({ format: "jwk" });
Object.assign(jwk, { kid: "frontman-e2e-key", alg: "RS256", use: "sig" });

const codes = new Map();
const accessTokens = new Map();
let sequence = 0;
let identity = {
  subject: "oidc-e2e-user",
  email: "oidc-user@example.com",
  groups: ["oidc-team"],
};
let tokenMode = "valid";

function sendJson(response, status, body) {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(body));
}

function sendHtml(response, status, body) {
  response.writeHead(status, { "content-type": "text/html; charset=utf-8" });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function parseBasicAuth(header) {
  if (!header?.startsWith("Basic ")) return null;
  const decoded = Buffer.from(header.slice(6), "base64").toString("utf8");
  const separator = decoded.indexOf(":");
  if (separator === -1) return null;
  return {
    id: decoded.slice(0, separator),
    secret: decoded.slice(separator + 1),
  };
}

function signIdToken(record) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", kid: jwk.kid, typ: "JWT" };
  const payload = {
    iss: issuer,
    sub: record.identity.subject,
    aud: clientId,
    exp: now + 300,
    iat: now,
    nonce: tokenMode === "wrong_nonce" ? `${record.nonce}-wrong` : record.nonce,
    email: record.identity.email,
    email_verified: tokenMode !== "unverified_email",
    name: "OIDC E2E User",
    groups: record.identity.groups,
  };
  const unsigned = `${Buffer.from(JSON.stringify(header)).toString("base64url")}.${Buffer.from(
    JSON.stringify(payload),
  ).toString("base64url")}`;
  const signature = crypto.sign(
    "RSA-SHA256",
    Buffer.from(unsigned),
    tokenMode === "invalid_signature" ? invalidPrivateKey : privateKey,
  );
  return `${unsigned}.${signature.toString("base64url")}`;
}

function validAuthorization(params) {
  const callback = params.get("redirect_uri");
  return (
    params.get("response_type") === "code" &&
    params.get("client_id") === clientId &&
    (callback === `${frontman}/auth/oidc/callback` ||
      callback === `${frontman}/auth/oidc/link/callback`) &&
    /^[A-Za-z0-9_-]{43}$/.test(params.get("state") ?? "") &&
    /^[A-Za-z0-9_-]{43}$/.test(params.get("nonce") ?? "") &&
    /^[A-Za-z0-9_-]{43}$/.test(params.get("code_challenge") ?? "") &&
    params.get("code_challenge_method") === "S256"
  );
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", issuer);

  if (request.method === "GET" && url.pathname === "/health") {
    return sendJson(response, 200, { ok: true });
  }

  if (
    request.method === "GET" &&
    url.pathname === "/.well-known/openid-configuration"
  ) {
    return sendJson(response, 200, {
      issuer,
      authorization_endpoint: `${issuer}/authorize`,
      token_endpoint: `${issuer}/token`,
      jwks_uri: `${issuer}/jwks`,
      response_types_supported: ["code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      token_endpoint_auth_methods_supported: [
        "client_secret_basic",
        "client_secret_post",
      ],
      scopes_supported: ["openid", "profile", "email", "groups"],
      claims_supported: ["sub", "email", "email_verified", "name", "groups"],
      code_challenge_methods_supported: ["S256"],
    });
  }

  if (request.method === "GET" && url.pathname === "/jwks") {
    return sendJson(response, 200, { keys: [jwk] });
  }

  if (request.method === "POST" && url.pathname === "/__test/identity") {
    const candidate = JSON.parse(await readBody(request));
    if (
      typeof candidate.subject !== "string" ||
      typeof candidate.email !== "string" ||
      !Array.isArray(candidate.groups) ||
      !candidate.groups.every((group) => typeof group === "string")
    ) {
      return sendJson(response, 400, { error: "invalid_identity" });
    }
    identity = candidate;
    codes.clear();
    accessTokens.clear();
    response.writeHead(204);
    return response.end();
  }

  if (request.method === "POST" && url.pathname === "/__test/token-mode") {
    const candidate = JSON.parse(await readBody(request));
    if (
      ![
        "valid",
        "invalid_signature",
        "wrong_nonce",
        "unverified_email",
      ].includes(candidate.mode)
    ) {
      return sendJson(response, 400, { error: "invalid_token_mode" });
    }
    tokenMode = candidate.mode;
    response.writeHead(204);
    return response.end();
  }

  if (request.method === "GET" && url.pathname === "/authorize") {
    if (!validAuthorization(url.searchParams)) {
      return sendJson(response, 400, {
        error: "invalid_authorization_request",
      });
    }
    return sendHtml(
      response,
      200,
      `<!doctype html>
      <html lang="en">
        <head><title>Approve Frontman</title></head>
        <body>
          <main>
            <h1>Approve Frontman</h1>
            <p>Continue as ${escapeHtml(identity.email)}</p>
            <form method="post" action="/approve">
              <input type="hidden" name="params" value="${escapeHtml(url.searchParams.toString())}" />
              <button type="submit">Approve</button>
            </form>
          </main>
        </body>
      </html>`,
    );
  }

  if (request.method === "POST" && url.pathname === "/approve") {
    const body = new URLSearchParams(await readBody(request));
    const params = new URLSearchParams(body.get("params") ?? "");
    if (!validAuthorization(params)) {
      return sendJson(response, 400, {
        error: "invalid_authorization_request",
      });
    }
    const code = `frontman-e2e-code-${++sequence}`;
    const record = {
      nonce: params.get("nonce"),
      codeChallenge: params.get("code_challenge"),
      redirectUri: params.get("redirect_uri"),
      identity: structuredClone(identity),
    };
    codes.set(code, record);
    const redirect = new URL(record.redirectUri);
    redirect.searchParams.set("code", code);
    redirect.searchParams.set("state", params.get("state"));
    response.writeHead(302, { location: redirect.toString() });
    return response.end();
  }

  if (request.method === "POST" && url.pathname === "/token") {
    const body = new URLSearchParams(await readBody(request));
    const basic = parseBasicAuth(request.headers.authorization);
    const requestedId = basic?.id ?? body.get("client_id");
    const requestedSecret = basic?.secret ?? body.get("client_secret");
    const code = body.get("code");
    const record = code ? codes.get(code) : undefined;
    const verifier = body.get("code_verifier") ?? "";
    const challenge = crypto
      .createHash("sha256")
      .update(verifier)
      .digest("base64url");

    if (requestedId !== clientId || requestedSecret !== clientSecret) {
      return sendJson(response, 401, { error: "invalid_client" });
    }
    if (
      body.get("grant_type") !== "authorization_code" ||
      !code ||
      !record ||
      body.get("redirect_uri") !== record.redirectUri ||
      challenge !== record.codeChallenge
    ) {
      return sendJson(response, 400, { error: "invalid_grant" });
    }

    codes.delete(code);
    const accessToken = `frontman-e2e-access-${sequence}`;
    accessTokens.set(accessToken, record.identity);
    const idToken = signIdToken(record);
    tokenMode = "valid";
    return sendJson(response, 200, {
      access_token: accessToken,
      token_type: "Bearer",
      expires_in: 300,
      id_token: idToken,
    });
  }

  if (request.method === "GET" && url.pathname === "/userinfo") {
    const token = request.headers.authorization?.replace(/^Bearer /, "");
    const currentIdentity = token ? accessTokens.get(token) : undefined;
    if (!currentIdentity)
      return sendJson(response, 401, { error: "invalid_token" });
    return sendJson(response, 200, {
      sub: currentIdentity.subject,
      email: currentIdentity.email,
      email_verified: true,
      name: "OIDC E2E User",
      groups: currentIdentity.groups,
    });
  }

  return sendJson(response, 404, { error: "not_found" });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`OIDC E2E provider listening on ${issuer}`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
