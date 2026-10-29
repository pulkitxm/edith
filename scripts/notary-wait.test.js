import { afterEach, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = mkdtempSync(join(tmpdir(), "edith-notary-wait-"));
const keyPath = join(root, "key.p8");
let key;
let server;

beforeAll(() => {
  const generated = Bun.spawnSync([
    "openssl",
    "genpkey",
    "-algorithm",
    "EC",
    "-pkeyopt",
    "ec_paramgen_curve:P-256",
    "-out",
    keyPath,
  ]);
  expect(generated.exitCode).toBe(0);
  key = readFileSync(keyPath, "utf8");
});

afterEach(() => {
  server?.stop(true);
  server = undefined;
});

function serve(handler) {
  const requests = [];
  server = Bun.serve({
    port: 0,
    fetch(request) {
      const url = new URL(request.url);
      requests.push({
        path: url.pathname,
        authorization: request.headers.get("authorization"),
      });
      return handler(url.pathname, requests.length);
    },
  });
  return { url: `http://127.0.0.1:${server.port}/notary/v2`, requests };
}

const status = (value) =>
  Response.json({ data: { attributes: { status: value } } });

async function wait(url, submissions, extra = {}) {
  const file = join(root, "submissions.json");
  writeFileSync(file, JSON.stringify(submissions));
  const child = Bun.spawn(
    ["python3", resolve("scripts/notary_wait.py"), file],
    {
      env: {
        ...process.env,
        NOTARY_KEY: key,
        NOTARY_KEY_ID: "KEYID",
        NOTARY_ISSUER_ID: "issuer-uuid",
        NOTARY_API_URL: url,
        NOTARY_POLL_SECONDS: "0.01",
        ...extra,
      },
      stdout: "pipe",
      stderr: "pipe",
    },
  );
  const [out, err] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  return { code: await child.exited, out, err };
}

test("succeeds once every submission is accepted after several polls", async () => {
  const polls = {};
  const { url } = serve((path) => {
    polls[path] = (polls[path] ?? 0) + 1;
    return status(polls[path] < 3 ? "In Progress" : "Accepted");
  });
  const result = await wait(url, { "a.zip": "id-a", "b.zip": "id-b" });
  expect(result.code).toBe(0);
  expect(polls["/notary/v2/submissions/id-a"]).toBe(3);
  expect(result.out).toContain("notarization id-b for b.zip: Accepted");
});

test("tolerates server errors and dropped connections", async () => {
  let calls = 0;
  const { url } = serve(() => {
    calls += 1;
    if (calls === 1) return new Response("down", { status: 503 });
    if (calls === 2) return new Response("slow", { status: 429 });
    return status("Accepted");
  });
  const result = await wait(url, { "a.zip": "id-a" });
  expect(result.code).toBe(0);
  expect(result.err).toContain("transient notary error");
  const offline = await wait(
    "http://127.0.0.1:1/notary/v2",
    { "a.zip": "x" },
    {
      NOTARY_DEADLINE_SECONDS: "0.3",
    },
  );
  expect(offline.code).toBe(1);
  expect(offline.err).toContain("did not finish before the deadline");
});

test("an invalid submission fails and prints the developer log", async () => {
  const { url } = serve((path) => {
    if (path.endsWith("/logs"))
      return Response.json({
        data: {
          attributes: {
            developerLogUrl: `${new URL(url).origin}/log.json`,
          },
        },
      });
    if (path === "/log.json")
      return new Response('{"issues":["bad signature"]}');
    return status("Invalid");
  });
  const result = await wait(url, { "a.zip": "id-a" });
  expect(result.code).toBe(1);
  expect(result.err).toContain("a.zip: Invalid");
  expect(result.err).toContain("bad signature");
});

test("requests carry a short-lived ES256 token with the notary claims", async () => {
  const { url, requests } = serve(() => status("Accepted"));
  await wait(url, { "a.zip": "id-a" });
  const token = requests[0].authorization.replace("Bearer ", "");
  const [header, claims, signature] = token.split(".");
  const decode = (part) =>
    JSON.parse(Buffer.from(part, "base64url").toString());
  expect(decode(header)).toMatchObject({ alg: "ES256", kid: "KEYID" });
  const payload = decode(claims);
  expect(payload).toMatchObject({
    iss: "issuer-uuid",
    aud: "appstoreconnect-v1",
  });
  expect(payload.exp - payload.iat).toBeLessThanOrEqual(20 * 60);
  expect(Buffer.from(signature, "base64url").length).toBe(64);
});

test("the signature verifies against the public key", async () => {
  const { url, requests } = serve(() => status("Accepted"));
  await wait(url, { "a.zip": "id-a" });
  const [header, claims, signature] = requests[0].authorization
    .replace("Bearer ", "")
    .split(".");
  const raw = Buffer.from(signature, "base64url");
  const integer = (bytes) => {
    const trimmed = bytes.subarray(bytes.findIndex((b) => b !== 0));
    const lead = trimmed[0] & 0x80 ? [0] : [];
    return Buffer.from([
      0x02,
      trimmed.length + lead.length,
      ...lead,
      ...trimmed,
    ]);
  };
  const body = Buffer.concat([
    integer(raw.subarray(0, 32)),
    integer(raw.subarray(32)),
  ]);
  const der = Buffer.concat([Buffer.from([0x30, body.length]), body]);
  const pub = join(root, "pub.pem");
  Bun.spawnSync(["openssl", "pkey", "-in", keyPath, "-pubout", "-out", pub]);
  writeFileSync(join(root, "sig.der"), der);
  writeFileSync(join(root, "msg"), `${header}.${claims}`);
  const verified = Bun.spawnSync([
    "openssl",
    "dgst",
    "-sha256",
    "-verify",
    pub,
    "-signature",
    join(root, "sig.der"),
    join(root, "msg"),
  ]);
  expect(verified.exitCode).toBe(0);
});

const extensions = Bun.YAML.parse(
  readFileSync(".github/workflows/extensions.yml", "utf8"),
).jobs;
const extensionsText = readFileSync(".github/workflows/extensions.yml", "utf8");

test("extension publication waits for notarization that runs off macOS", () => {
  expect(extensions.publish.needs).toContain("notarize");
  expect(extensions.publish.if).toContain("needs.notarize.result == 'success'");
  expect(extensions.notarize.needs).toContain("build");
  expect(extensions.notarize["runs-on"]).toBe("ubuntu-latest");
  expect(JSON.stringify(extensions.notarize)).toContain("notary_wait.py");
  expect(JSON.stringify(extensions.build)).toContain("notary-submit.sh");
  expect(JSON.stringify(extensions.build)).not.toContain("--wait");
  expect(extensionsText).not.toContain("scripts/notarize.sh");
});

test("no extension notarization step can be skipped or tolerated", () => {
  const text = JSON.stringify(extensions.notarize);
  expect(text).not.toContain("continue-on-error");
  expect(text).not.toContain("|| true");
  expect(extensions.notarize["continue-on-error"]).toBeUndefined();
});
