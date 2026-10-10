import { createPublicKey, verify } from "node:crypto";
import { mkdtemp, open, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const maximumEnvelopeBytes = 3 * 1024 ** 2;
export const maximumPayloadBytes = 2 * 1024 ** 2;

const fail = (message) => {
  throw new Error(message);
};
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const component = (value) =>
  typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(value);
const digest = (value) =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const integer = (value, minimum, maximum = Number.MAX_SAFE_INTEGER) =>
  Number.isSafeInteger(value) && value >= minimum && value <= maximum;

function base64(value, maximum, size) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > Math.ceil(maximum / 3) * 4 ||
    value.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(value)
  )
    fail("Invalid base64 encoding");
  const decoded = Buffer.from(value, "base64");
  if (
    decoded.length > maximum ||
    (size !== undefined && decoded.length !== size) ||
    decoded.toString("base64") !== value
  )
    fail("Invalid base64 length or encoding");
  return decoded;
}

function json(bytes) {
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

function validateCatalog(catalog) {
  if (
    !object(catalog) ||
    catalog.schemaVersion !== 1 ||
    !integer(catalog.revision, 0) ||
    !Array.isArray(catalog.packages) ||
    catalog.packages.length > 1000
  )
    fail("Invalid catalog schema");
  const identities = new Set();
  for (const entry of catalog.packages) {
    if (
      !object(entry) ||
      !component(entry.id) ||
      !component(entry.hostABI) ||
      !component(entry.version) ||
      !/^\d+\.\d+\.\d+$/.test(entry.version) ||
      !entry.version.split(".").every((part) => integer(Number(part), 0)) ||
      !["arm64", "x86_64"].includes(entry.architecture) ||
      !integer(entry.minimumSystemVersion, 14) ||
      !integer(entry.downloadBytes, 1, 512 * 1024 ** 2) ||
      !integer(entry.installedBytes, 1, 1024 ** 3) ||
      !digest(entry.sha256) ||
      !digest(entry.sourceFingerprint) ||
      !Array.isArray(entry.dependencies) ||
      entry.dependencies.length > 1000 ||
      !entry.dependencies.every(component) ||
      new Set(entry.dependencies).size !== entry.dependencies.length ||
      entry.dependencies.includes(entry.id) ||
      typeof entry.downloadURL !== "string"
    )
      fail("Invalid package schema");
    const url = new URL(entry.downloadURL);
    if (
      url.protocol !== "https:" ||
      url.hostname !== "github.com" ||
      url.username ||
      url.password ||
      url.port ||
      url.search ||
      url.hash ||
      url.href !== entry.downloadURL ||
      !url.pathname.startsWith("/pulkitxm/edith/releases/download/") ||
      !url.pathname.endsWith(`/${entry.id}.zip`)
    )
      fail("Invalid package download URL");
    const identity = [
      entry.id,
      entry.hostABI,
      entry.version,
      entry.architecture,
    ].join("/");
    if (identities.has(identity)) fail("Duplicate package identity");
    identities.add(identity);
  }
  for (const entry of catalog.packages) {
    if (
      !entry.dependencies.every((id) =>
        catalog.packages.some(
          (dependency) =>
            dependency.id === id &&
            dependency.hostABI === entry.hostABI &&
            dependency.architecture === entry.architecture,
        ),
      )
    )
      fail("Missing package dependency");
  }
}

export function verifiedCatalogPayload(data, encodedPublicKey) {
  if (!(data instanceof Uint8Array) || data.length > maximumEnvelopeBytes)
    fail("Catalog envelope exceeds its limit");
  const rawKey = base64(encodedPublicKey, 32, 32);
  const envelope = json(data);
  if (
    !object(envelope) ||
    Object.keys(envelope).length !== 2 ||
    !Object.hasOwn(envelope, "payload") ||
    !Object.hasOwn(envelope, "signature")
  )
    fail("Invalid catalog envelope");
  const payload = base64(envelope.payload, maximumPayloadBytes);
  const signature = base64(envelope.signature, 64, 64);
  const key = createPublicKey({
    key: { kty: "OKP", crv: "Ed25519", x: rawKey.toString("base64url") },
    format: "jwk",
  });
  if (!verify(null, payload, key, signature)) fail("Invalid catalog signature");
  validateCatalog(json(payload));
  return payload;
}

export async function verifyCatalogFile(envelopePath, payloadPath, publicKey) {
  const handle = await open(envelopePath, "r");
  const buffer = Buffer.alloc(maximumEnvelopeBytes + 1);
  let length = 0;
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.size > maximumEnvelopeBytes)
      fail("Invalid catalog file or envelope size");
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(
        buffer,
        length,
        buffer.length - length,
      );
      if (bytesRead === 0) break;
      length += bytesRead;
    }
  } finally {
    await handle.close();
  }
  const payload = verifiedCatalogPayload(buffer.subarray(0, length), publicKey);
  const destination = resolve(payloadPath);
  const temporary = await mkdtemp(
    join(dirname(destination), ".verified-catalog-"),
  );
  try {
    const candidate = join(temporary, "payload.json");
    await writeFile(candidate, payload, { mode: 0o600, flag: "wx" });
    await rename(candidate, destination);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    const arguments_ = process.argv.slice(2);
    if (arguments_.length !== 3)
      fail("Supply an envelope path, payload path, and raw base64 public key");
    await verifyCatalogFile(...arguments_);
  } catch (error) {
    process.stderr.write(`Catalog verification failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
