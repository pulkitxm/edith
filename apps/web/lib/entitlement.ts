import { createPrivateKey, sign } from "node:crypto";

const ed25519Pkcs8Prefix = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

export type EntitlementInput = {
  receiptId: string;
  licenseId: string;
  deviceId: string;
  deviceKeyThumbprint: string;
  planId: string;
  maxMachines: number;
  now: number;
};

function getSigningKey() {
  const encodedSeed = process.env.LICENSE_SIGNING_PRIVATE_KEY;

  if (!encodedSeed) {
    throw new Error("LICENSE_SIGNING_PRIVATE_KEY is missing");
  }

  if (!/^[A-Za-z0-9+/]{43}=$/.test(encodedSeed)) {
    throw new Error(
      "LICENSE_SIGNING_PRIVATE_KEY must be base64 for a 32-byte Ed25519 seed",
    );
  }

  const seed = Buffer.from(encodedSeed, "base64");

  if (seed.length !== 32 || seed.toString("base64") !== encodedSeed) {
    throw new Error(
      "LICENSE_SIGNING_PRIVATE_KEY must be base64 for a 32-byte Ed25519 seed",
    );
  }

  const der = Buffer.concat([ed25519Pkcs8Prefix, seed]);
  return createPrivateKey({ key: der, format: "der", type: "pkcs8" });
}

function entitlementTtlSeconds(): number {
  const raw = process.env.LICENSE_ENTITLEMENT_TTL_DAYS;
  const days = raw ? Number.parseInt(raw, 10) : 30;

  if (!Number.isInteger(days) || days < 1) {
    throw new Error("LICENSE_ENTITLEMENT_TTL_DAYS must be a positive integer");
  }

  return days * 86_400;
}

export function signEntitlement(input: EntitlementInput): string {
  const payload = JSON.stringify({
    version: 2,
    keyId: process.env.LICENSE_SIGNING_KEY_ID ?? "edith-2026-07",
    receiptId: input.receiptId,
    licenseId: input.licenseId,
    deviceId: input.deviceId,
    deviceKeyThumbprint: input.deviceKeyThumbprint,
    productId: "edith",
    planId: input.planId,
    maxMachines: input.maxMachines,
    features: ["edith-core"],
    issuedAt: input.now,
    notBefore: input.now,
    expiresAt: input.now + entitlementTtlSeconds(),
    policyVersion: 2,
  });
  const message = Buffer.from(payload, "utf8");
  const signature = sign(null, message, getSigningKey());
  return `${message.toString("base64url")}.${signature.toString("base64url")}`;
}
