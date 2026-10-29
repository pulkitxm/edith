import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

async function notarize(status, artifact, credentials = true) {
  const root = mkdtempSync(join(tmpdir(), "edith-notarize-"));
  const log = join(root, "calls");
  const keyPath = join(root, "key.p8");
  Bun.spawnSync([
    "openssl",
    "genpkey",
    "-algorithm",
    "EC",
    "-pkeyopt",
    "ec_paramgen_curve:P-256",
    "-out",
    keyPath,
  ]);
  writeFileSync(
    join(root, "xcrun"),
    `#!/usr/bin/env bash
printf '%s\\n' "$1 $2" >> "$NOTARY_TEST_LOG"
if [ "$1 $2" = 'notarytool submit' ]; then
  case "$*" in *--no-wait*) ;; *) exit 9 ;; esac
  printf '{"id":"synthetic-submission"}'
fi
`,
    { mode: 0o755 },
  );
  const server = Bun.serve({
    port: 0,
    fetch: (request) =>
      new URL(request.url).pathname.endsWith("/logs")
        ? Response.json({ data: { attributes: { developerLogUrl: "" } } })
        : Response.json({ data: { attributes: { status } } }),
  });
  const env = {
    ...process.env,
    PATH: `${root}:${process.env.PATH}`,
    NOTARY_TEST_LOG: log,
    NOTARY_API_URL: `http://127.0.0.1:${server.port}/notary/v2`,
    NOTARY_POLL_SECONDS: "0.01",
    NOTARY_RETRY_SECONDS: "0",
  };
  for (const key of ["NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "NOTARY_KEY"]) {
    delete env[key];
    if (credentials) env[key] = "synthetic";
  }
  if (credentials) env.NOTARY_KEY = readFileSync(keyPath, "utf8");
  try {
    const child = Bun.spawn(
      ["bash", resolve("scripts/notarize.sh"), artifact],
      {
        env,
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    const error = await new Response(child.stderr).text();
    const code = await child.exited;
    let calls = "";
    try {
      calls = readFileSync(log, "utf8");
    } catch {}
    return { code, calls, error };
  } finally {
    server.stop(true);
    rmSync(root, { recursive: true, force: true });
  }
}

test("accepted disk images receive a validated stapled ticket", async () => {
  expect(await notarize("Accepted", "synthetic.dmg")).toMatchObject({
    code: 0,
    calls: "notarytool submit\nstapler staple\nstapler validate\n",
  });
});

test("rejected submissions stop publication and are never stapled", async () => {
  const result = await notarize("Invalid", "synthetic.dmg");
  expect(result.code).not.toBe(0);
  expect(result.calls).toBe("notarytool submit\n");
});

test("accepted extension archives are notarized without changing their signed archive bytes", async () => {
  expect(await notarize("Accepted", "synthetic.zip")).toMatchObject({
    code: 0,
    calls: "notarytool submit\n",
  });
});

test("missing notarization credentials fail before an upload", async () => {
  const result = await notarize("Accepted", "synthetic.dmg", false);
  expect(result.code).not.toBe(0);
  expect(result.calls).toBe("");
  expect(result.error).toContain("NOTARY_KEY_ID is required");
});
