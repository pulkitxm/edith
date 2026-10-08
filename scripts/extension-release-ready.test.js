import { expect, test } from "bun:test";
import { generateKeyPairSync, sign } from "node:crypto";
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
  { id: "calendar", hostABI: "runtime-2", fingerprint: "current-source" },
];
const record = {
  ...expected[0],
  sourceFingerprint: "current-source",
  architecture: "arm64",
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
    { sourceFingerprint: "old-source" },
    { architecture: "x86_64" },
  ])
    expect(
      missingPackages(expected, { packages: [{ ...record, ...change }] }),
    ).toEqual(expected);
  expect(
    missingPackages(expected, {
      packages: [record, { ...record, sourceFingerprint: "newer-source" }],
    }),
  ).toEqual([]);
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
