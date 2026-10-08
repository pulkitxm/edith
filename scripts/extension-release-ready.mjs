import { createPublicKey, verify } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { writeHostABI } from "./extension-host-abi.mjs";
import { extensionFingerprint } from "./extension-release-plan.mjs";

export function verifyCatalog(envelope, publicKey) {
  if (Buffer.byteLength(envelope) > 3_000_000)
    throw new Error("Catalog exceeds size limit");
  const signed = JSON.parse(envelope);
  const payload = Buffer.from(signed.payload, "base64");
  const key = createPublicKey({
    key: Buffer.concat([
      Buffer.from("302a300506032b6570032100", "hex"),
      Buffer.from(publicKey, "base64"),
    ]),
    format: "der",
    type: "spki",
  });
  if (!verify(null, payload, key, Buffer.from(signed.signature, "base64")))
    throw new Error("Invalid catalog signature");
  const catalog = JSON.parse(payload);
  if (
    catalog.schemaVersion !== 1 ||
    !Number.isSafeInteger(catalog.revision) ||
    catalog.revision <= 0 ||
    !Array.isArray(catalog.packages)
  )
    throw new Error("Invalid catalog");
  return catalog;
}

export function missingPackages(expected, catalog) {
  return expected.filter(
    (entry) =>
      !catalog.packages.some(
        (published) =>
          published.id === entry.id &&
          published.hostABI === entry.hostABI &&
          published.architecture === "arm64" &&
          published.sourceFingerprint === entry.fingerprint,
      ),
  );
}

export async function expectedPackages(root) {
  await writeHostABI(root);
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  return Promise.all(
    definitions.map(async (entry) => ({
      id: entry.id,
      hostABI: entry.hostABI,
      fingerprint: await extensionFingerprint(root, entry, definitions),
    })),
  );
}

export async function waitForPackages({
  expected,
  url,
  publicKey,
  timeout = 600_000,
  interval = 15_000,
  fetchCatalog = fetch,
  sleep = (duration) => new Promise((done) => setTimeout(done, duration)),
  now = Date.now,
}) {
  const deadline = now() + timeout;
  let missing = expected;
  while (true) {
    const response = await fetchCatalog(url, {
      signal: AbortSignal.timeout(15_000),
      headers: { "Cache-Control": "no-cache" },
    });
    if (response.status === 200) {
      const catalog = verifyCatalog(await response.text(), publicKey);
      missing = missingPackages(expected, catalog);
      if (missing.length === 0) return catalog.revision;
    } else if (response.status !== 404) {
      throw new Error(
        `Cannot verify extension catalog: HTTP ${response.status}`,
      );
    }
    if (now() >= deadline)
      throw new Error(
        `App publication blocked: extensions not published: ${missing.map(({ id }) => id).join(", ")}`,
      );
    await sleep(Math.min(interval, Math.max(0, deadline - now())));
  }
}

if (import.meta.main) {
  const revision = await waitForPackages({
    expected: await expectedPackages(process.argv[2] ?? process.cwd()),
    url: "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog.json",
    publicKey: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=",
  });
  process.stdout.write(`Compatible extension catalog verified: ${revision}\n`);
}
