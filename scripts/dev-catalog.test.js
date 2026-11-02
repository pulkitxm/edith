import { describe, expect, test } from "bun:test";
import { createPublicKey, verify } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  catalogPayload,
  developmentVersion,
  localRecord,
  releaseTag,
  signCatalog,
  signingKey,
} from "./dev-catalog.mjs";

const built = {
  id: "jev",
  version: "1.0.1761955200",
  hostABI: "edith-host-8",
  architecture: "arm64",
  minimumSystemVersion: "14.0.0",
  dependencies: [],
  downloadURL:
    "https://github.com/pulkitxm/edith/releases/download/whatever/jev.zip",
  sha256: "a".repeat(64),
  downloadBytes: 10,
  installedBytes: 20,
  sourceFingerprint: "f".repeat(64),
};

describe("development catalog", () => {
  test("versions stay numeric and increase with time", () => {
    expect(developmentVersion("1.0.5", 1_761_955_200_000)).toBe(
      "1.0.1761955200",
    );
    expect(releaseTag("jev", "1.0.7")).toBe("dev-jev-1.0.7");
  });

  test("records point at a release tag and drop build-only fields", () => {
    const record = localRecord(built, { tag: "dev-jev-1.0.1761955200" });
    expect(record.sourceFingerprint).toBeUndefined();
    expect(record.downloadURL).toBe(
      "https://github.com/pulkitxm/edith/releases/download/dev-jev-1.0.1761955200/jev.zip",
    );
    expect(record.hostABI).toBe("edith-host-8");
    expect(
      localRecord(built, { tag: "t", hostABI: "edith-host-0" }).hostABI,
    ).toBe("edith-host-0");
  });

  test("local records replace production entries with the same id", () => {
    const production = [
      { ...built, version: "1.0.5" },
      { ...built, id: "emoji" },
    ];
    const payload = catalogPayload([built], production, 7);
    expect(payload.revision).toBe(7);
    expect(payload.packages.map((p) => `${p.id}@${p.version}`)).toEqual([
      "emoji@1.0.1761955200",
      "jev@1.0.1761955200",
    ]);
  });

  test("signatures verify against the stored public key", async () => {
    const root = await mkdtemp(join(tmpdir(), "dev-catalog-"));
    try {
      const { privateKey, publicKey } = await signingKey(root);
      const again = await signingKey(root);
      expect(again.publicKey).toBe(publicKey);
      expect(Buffer.from(publicKey, "base64")).toHaveLength(32);
      const envelope = signCatalog(
        { schemaVersion: 1, revision: 1, packages: [] },
        privateKey,
      );
      const key = createPublicKey({
        key: {
          kty: "OKP",
          crv: "Ed25519",
          x: Buffer.from(publicKey, "base64").toString("base64url"),
        },
        format: "jwk",
      });
      expect(
        verify(
          null,
          Buffer.from(envelope.payload, "base64"),
          key,
          Buffer.from(envelope.signature, "base64"),
        ),
      ).toBe(true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
