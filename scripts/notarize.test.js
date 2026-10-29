import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

function notarize(status, artifact, credentials = true) {
  const root = mkdtempSync(join(tmpdir(), "edith-notarize-"));
  const log = join(root, "calls");
  writeFileSync(
    join(root, "xcrun"),
    `#!/usr/bin/env bash
printf '%s\\n' "$1 $2" >> "$NOTARY_TEST_LOG"
if [ "$1 $2" = 'notarytool submit' ]; then
  printf '{"id":"synthetic-submission","status":"%s"}' "$NOTARY_TEST_STATUS"
fi
`,
    { mode: 0o755 },
  );
  const env = {
    ...process.env,
    PATH: `${root}:${process.env.PATH}`,
    NOTARY_TEST_LOG: log,
    NOTARY_TEST_STATUS: status,
  };
  for (const key of ["NOTARY_KEY_ID", "NOTARY_ISSUER_ID", "NOTARY_KEY"]) {
    delete env[key];
    if (credentials) env[key] = "synthetic";
  }
  try {
    const result = Bun.spawnSync(
      ["bash", resolve("scripts/notarize.sh"), artifact],
      { env },
    );
    let calls = "";
    try {
      calls = readFileSync(log, "utf8");
    } catch {}
    return { code: result.exitCode, calls, error: result.stderr.toString() };
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("accepted disk images receive a validated stapled ticket", () => {
  expect(notarize("Accepted", "synthetic.dmg")).toMatchObject({
    code: 0,
    calls: "notarytool submit\nstapler staple\nstapler validate\n",
  });
});

test("rejected submissions stop publication and retrieve Apple's diagnostic log", () => {
  const result = notarize("Invalid", "synthetic.dmg");
  expect(result.code).not.toBe(0);
  expect(result.calls).toBe("notarytool submit\nnotarytool log\n");
});

test("accepted extension archives are notarized without changing their signed archive bytes", () => {
  expect(notarize("Accepted", "synthetic.zip")).toMatchObject({
    code: 0,
    calls: "notarytool submit\n",
  });
});

test("missing notarization credentials fail before an upload", () => {
  const result = notarize("Accepted", "synthetic.dmg", false);
  expect(result.code).not.toBe(0);
  expect(result.calls).toBe("");
  expect(result.error).toContain("NOTARY_KEY_ID is required");
});
