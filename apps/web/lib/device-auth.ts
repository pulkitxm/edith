import {
  createHash,
  createPublicKey,
  type KeyObject,
  randomBytes,
  verify,
} from "node:crypto";

const base64UrlPattern = /^[A-Za-z0-9_-]+$/;

function decodePublicKey(encoded: string): KeyObject | null {
  if (!base64UrlPattern.test(encoded)) {
    return null;
  }

  try {
    const key = createPublicKey({
      key: Buffer.from(encoded, "base64url"),
      format: "der",
      type: "spki",
    });

    if (
      key.asymmetricKeyType !== "ec" ||
      key.asymmetricKeyDetails?.namedCurve !== "prime256v1"
    ) {
      return null;
    }

    return key;
  } catch {
    return null;
  }
}

export function validateDevicePublicKey(encoded: string): boolean {
  return decodePublicKey(encoded) !== null;
}

export function publicKeyThumbprint(encoded: string): string {
  return createHash("sha256")
    .update(Buffer.from(encoded, "base64url"))
    .digest("base64url");
}

export function createChallengeNonce(): string {
  return randomBytes(32).toString("base64url");
}

export function nonceDigest(nonce: string): string {
  return createHash("sha256").update(nonce, "utf8").digest("hex");
}

export function challengeMessage(
  purpose: string,
  challengeId: string,
  nonce: string,
): string {
  return `edith-v2.${purpose}.${challengeId}.${nonce}`;
}

export function verifyChallengeSignature(
  encodedPublicKey: string,
  message: string,
  encodedSignature: string,
): boolean {
  const key = decodePublicKey(encodedPublicKey);

  if (!key || !base64UrlPattern.test(encodedSignature)) {
    return false;
  }

  try {
    return verify(
      "sha256",
      Buffer.from(message, "utf8"),
      { key, dsaEncoding: "der" },
      Buffer.from(encodedSignature, "base64url"),
    );
  } catch {
    return false;
  }
}
