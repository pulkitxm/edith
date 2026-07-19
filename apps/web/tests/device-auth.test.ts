import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { describe, expect, test } from "bun:test";
import {
  challengeMessage,
  createChallengeNonce,
  nonceDigest,
  publicKeyThumbprint,
  validateDevicePublicKey,
  verifyChallengeSignature,
} from "@/lib/device-auth";

function makeDeviceKey(namedCurve = "P-256") {
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve });
  const spki = publicKey.export({ format: "der", type: "spki" });
  return {
    privateKey,
    encodedPublicKey: Buffer.from(spki).toString("base64url"),
  };
}

function signMessage(
  privateKey: ReturnType<typeof makeDeviceKey>["privateKey"],
  message: string,
): string {
  return sign("sha256", Buffer.from(message, "utf8"), privateKey).toString(
    "base64url",
  );
}

describe("device public keys", () => {
  test("accepts a P-256 SPKI key", () => {
    const { encodedPublicKey } = makeDeviceKey();
    expect(validateDevicePublicKey(encodedPublicKey)).toBe(true);
  });

  test("rejects other curves and garbage", () => {
    const { encodedPublicKey } = makeDeviceKey("P-384");
    expect(validateDevicePublicKey(encodedPublicKey)).toBe(false);
    expect(validateDevicePublicKey("not-a-key")).toBe(false);
    expect(validateDevicePublicKey("+invalid+chars=")).toBe(false);
  });

  test("thumbprint is the base64url sha256 of the DER", () => {
    const { encodedPublicKey } = makeDeviceKey();
    const expected = createHash("sha256")
      .update(Buffer.from(encodedPublicKey, "base64url"))
      .digest("base64url");

    expect(publicKeyThumbprint(encodedPublicKey)).toBe(expected);
  });
});

describe("challenges", () => {
  test("nonce is base64url and digest is sha256 hex", () => {
    const nonce = createChallengeNonce();

    expect(nonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(nonceDigest(nonce)).toBe(
      createHash("sha256").update(nonce, "utf8").digest("hex"),
    );
  });

  test("message layout matches the wire contract", () => {
    expect(challengeMessage("activate", "challenge-1", "nonce-1")).toBe(
      "edith-v2.activate.challenge-1.nonce-1",
    );
  });

  test("verifies a genuine signature", () => {
    const { privateKey, encodedPublicKey } = makeDeviceKey();
    const message = challengeMessage("refresh", "c1", createChallengeNonce());
    const signature = signMessage(privateKey, message);

    expect(verifyChallengeSignature(encodedPublicKey, message, signature)).toBe(
      true,
    );
  });

  test("rejects a signature from another key or altered message", () => {
    const device = makeDeviceKey();
    const attacker = makeDeviceKey();
    const message = challengeMessage("refresh", "c1", "nonce");

    expect(
      verifyChallengeSignature(
        device.encodedPublicKey,
        message,
        signMessage(attacker.privateKey, message),
      ),
    ).toBe(false);
    expect(
      verifyChallengeSignature(
        device.encodedPublicKey,
        `${message}x`,
        signMessage(device.privateKey, message),
      ),
    ).toBe(false);
  });

  test("rejects wrong-curve keys during verification", () => {
    const p384 = makeDeviceKey("P-384");
    const message = challengeMessage("activate", "c1", "nonce");

    expect(
      verifyChallengeSignature(
        p384.encodedPublicKey,
        message,
        signMessage(p384.privateKey, message),
      ),
    ).toBe(false);
  });
});
