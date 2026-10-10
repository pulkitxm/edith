import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  missingPackages,
  verifyCatalog,
  waitForPackages,
} from "./extension-release-ready.mjs";

const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const rawKey = publicKey
  .export({ type: "spki", format: "der" })
  .subarray(-32)
  .toString("base64");
const expected = [
  {
    id: "calendar",
    hostABI: "runtime-2",
    architecture: "arm64",
    minimumSystemVersion: 14,
    fingerprint: "a".repeat(64),
  },
];
const record = {
  id: "calendar",
  hostABI: "runtime-2",
  version: "1.0.0",
  minimumSystemVersion: 14,
  sourceFingerprint: "a".repeat(64),
  architecture: "arm64",
  dependencies: [],
  sha256: "c".repeat(64),
  downloadBytes: 100,
  installedBytes: 200,
  downloadURL:
    "https://github.com/pulkitxm/edith/releases/download/synthetic/calendar.zip",
};
function signed(packages) {
  const payload = Buffer.from(
    JSON.stringify({ schemaVersion: 1, revision: 2, packages }),
  );
  return JSON.stringify({
    payload: payload.toString("base64"),
    signature: sign(null, payload, privateKey).toString("base64"),
  });
}

test("app publication requires its own source and host contract", () => {
  for (const change of [
    { hostABI: "runtime-1" },
    { sourceFingerprint: "b".repeat(64) },
    { architecture: "x86_64" },
  ])
    expect(
      missingPackages(expected, { packages: [{ ...record, ...change }] }),
    ).toEqual(expected);
  expect(
    missingPackages(expected, {
      packages: [
        record,
        { ...record, version: "1.1.0", sourceFingerprint: "b".repeat(64) },
      ],
    }),
  ).toEqual(expected);
});

test("the release guard authenticates the catalog before trusting fingerprints", () => {
  expect(verifyCatalog(signed([record]), rawKey).packages).toEqual([record]);
  const forged = JSON.parse(signed([record]));
  forged.payload = Buffer.from(
    JSON.stringify({ schemaVersion: 1, revision: 99, packages: [record] }),
  ).toString("base64");
  expect(() => verifyCatalog(JSON.stringify(forged), rawKey)).toThrow(
    "signature",
  );
});

test("an app waits for separately published extensions", async () => {
  let calls = 0;
  const result = await waitForPackages({
    expected,
    url: "https://synthetic.invalid/catalog.json",
    publicKey: rawKey,
    fetchCatalog: async () =>
      new Response(signed(++calls === 1 ? [] : [record])),
    sleep: async () => {},
  });
  expect(calls).toBe(2);
  expect(result).toBe(2);
});

test("missing packages and failed catalog responses block app publication", async () => {
  for (const response of [
    new Response("", { status: 404 }),
    new Response(signed([])),
    new Response("", { status: 503 }),
  ])
    await expect(
      waitForPackages({
        expected,
        url: "https://synthetic.invalid",
        publicKey: rawKey,
        timeout: 0,
        fetchCatalog: async () => response,
      }),
    ).rejects.toThrow();
});

test("the Node command rejects an invalid release source instead of skipping validation", () => {
  const root = mkdtempSync(join(tmpdir(), "extension-readiness-"));
  try {
    const result = spawnSync(
      process.env.EXTENSION_TEST_NODE ?? "node",
      [
        fileURLToPath(
          new URL("./extension-release-ready.mjs", import.meta.url),
        ),
        root,
      ],
      { encoding: "utf8", timeout: 10_000 },
    );
    expect(result.error).toBeUndefined();
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain("ENOENT");
    expect(result.stdout).not.toContain(
      "Compatible extension catalog verified",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("source reverts wait for the new selected release instead of retained rollback code", async () => {
  const changed = {
    ...record,
    version: "1.1.0",
    sourceFingerprint: "b".repeat(64),
  };
  const reverted = { ...record, version: "1.2.0" };
  expect(missingPackages(expected, { packages: [record, changed] })).toEqual(
    expected,
  );
  expect(
    missingPackages(expected, { packages: [record, changed, reverted] }),
  ).toEqual([]);
  let calls = 0;
  await waitForPackages({
    expected,
    url: "https://synthetic.invalid/catalog.json",
    publicKey: rawKey,
    fetchCatalog: async () =>
      new Response(
        signed(++calls === 1 ? [record, changed] : [changed, reverted]),
      ),
    sleep: async () => {},
  });
  expect(calls).toBe(2);
});

test("every supported OS tier selects its highest compatible numeric version", () => {
  const future = {
    ...record,
    version: "1.10.0",
    minimumSystemVersion: 15,
    sourceFingerprint: "b".repeat(64),
  };
  const current = { ...record, version: "1.9.0" };
  expect(missingPackages(expected, { packages: [future, current] })).toEqual(
    expected,
  );
  expect(
    missingPackages(expected, {
      packages: [future, { ...current, version: "1.11.0" }],
    }),
  ).toEqual([]);
  expect(missingPackages(expected, { packages: [future] })).toEqual(expected);
  const onlyNewerOS = [{ ...expected[0], minimumSystemVersion: 15 }];
  expect(missingPackages(onlyNewerOS, { packages: [future, current] })).toEqual(
    onlyNewerOS,
  );
  expect(
    missingPackages(onlyNewerOS, {
      packages: [{ ...future, sourceFingerprint: record.sourceFingerprint }],
    }),
  ).toEqual([]);
  expect(
    missingPackages(expected, {
      packages: [current, { ...future, architecture: "x86_64" }],
    }),
  ).toEqual([]);
  expect(
    missingPackages(expected, {
      packages: [current, { ...future, hostABI: "runtime-3" }],
    }),
  ).toEqual([]);
});

test("signed malformed, duplicate, missing dependency and oversized catalogs reject before selection", () => {
  for (const packages of [
    [record, record],
    [{ ...record, version: "broken" }],
    [{ ...record, sourceFingerprint: "invalid" }],
    [{ ...record, minimumSystemVersion: 13 }],
    [{ ...record, dependencies: ["missing"] }],
    [{ ...record, downloadURL: "https://synthetic.invalid/calendar.zip" }],
    Array.from({ length: 1001 }, (_, index) => ({
      ...record,
      version: `1.0.${index}`,
    })),
  ])
    expect(() => verifyCatalog(signed(packages), rawKey)).toThrow();
  const envelope = JSON.parse(signed([record]));
  expect(() =>
    verifyCatalog(JSON.stringify({ ...envelope, extra: true }), rawKey),
  ).toThrow();
  expect(() =>
    verifyCatalog(
      JSON.stringify({
        ...envelope,
        payload: `${envelope.payload}=`,
      }),
      rawKey,
    ),
  ).toThrow();
});
