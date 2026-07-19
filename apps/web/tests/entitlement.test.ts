import { createPublicKey, generateKeyPairSync, verify } from "node:crypto";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { signEntitlement } from "@/lib/entitlement";

const ed25519SpkiPrefix = Buffer.from("302a300506032b6570032100", "hex");
const previousEnv = {
  seed: process.env.LICENSE_SIGNING_PRIVATE_KEY,
  keyId: process.env.LICENSE_SIGNING_KEY_ID,
  ttl: process.env.LICENSE_ENTITLEMENT_TTL_DAYS,
};

function restore(name: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const verificationKey = createPublicKey({
  key: Buffer.concat([
    ed25519SpkiPrefix,
    publicKey.export({ format: "der", type: "spki" }).subarray(-32),
  ]),
  format: "der",
  type: "spki",
});

beforeAll(() => {
  process.env.LICENSE_SIGNING_PRIVATE_KEY = privateKey
    .export({ format: "der", type: "pkcs8" })
    .subarray(-32)
    .toString("base64");
  delete process.env.LICENSE_SIGNING_KEY_ID;
  delete process.env.LICENSE_ENTITLEMENT_TTL_DAYS;
});

afterAll(() => {
  restore("LICENSE_SIGNING_PRIVATE_KEY", previousEnv.seed);
  restore("LICENSE_SIGNING_KEY_ID", previousEnv.keyId);
  restore("LICENSE_ENTITLEMENT_TTL_DAYS", previousEnv.ttl);
});

describe("entitlements", () => {
  test("serializes the payload in the exact contract order", () => {
    const entitlement = signEntitlement({
      receiptId: "receipt-1",
      licenseId: "license-1",
      deviceId: "device-1",
      deviceKeyThumbprint: "thumbprint-1",
      planId: "personal_3",
      maxMachines: 3,
      now: 1_700_000_000,
    });
    const [payloadSegment, signatureSegment] = entitlement.split(".");
    const payloadBytes = Buffer.from(payloadSegment, "base64url");

    expect(payloadBytes.toString("utf8")).toBe(
      '{"version":2,"keyId":"edith-2026-07","receiptId":"receipt-1","licenseId":"license-1","deviceId":"device-1","deviceKeyThumbprint":"thumbprint-1","productId":"edith","planId":"personal_3","maxMachines":3,"features":["edith-core"],"issuedAt":1700000000,"notBefore":1700000000,"expiresAt":1702592000,"policyVersion":2}',
    );
    expect(
      verify(
        null,
        payloadBytes,
        verificationKey,
        Buffer.from(signatureSegment, "base64url"),
      ),
    ).toBe(true);
  });

  test("honors the configured key id and TTL", () => {
    process.env.LICENSE_SIGNING_KEY_ID = "edith-test-key";
    process.env.LICENSE_ENTITLEMENT_TTL_DAYS = "7";

    try {
      const entitlement = signEntitlement({
        receiptId: "receipt-1",
        licenseId: "license-1",
        deviceId: "device-1",
        deviceKeyThumbprint: "thumbprint-1",
        planId: "individual_1",
        maxMachines: 1,
        now: 1_700_000_000,
      });
      const payload = JSON.parse(
        Buffer.from(entitlement.split(".")[0], "base64url").toString("utf8"),
      );

      expect(payload.keyId).toBe("edith-test-key");
      expect(payload.expiresAt).toBe(1_700_000_000 + 7 * 86_400);
    } finally {
      delete process.env.LICENSE_SIGNING_KEY_ID;
      delete process.env.LICENSE_ENTITLEMENT_TTL_DAYS;
    }
  });
});
