import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

function getPepper(): string {
  const pepper = process.env.LICENSE_KEY_LOOKUP_PEPPER;

  if (!pepper) {
    throw new Error("LICENSE_KEY_LOOKUP_PEPPER is missing");
  }

  return pepper;
}

export function generateRefreshCredential(): string {
  return `edithrc_${randomBytes(32).toString("base64url")}`;
}

export function refreshCredentialDigest(credential: string): string {
  return createHmac("sha256", getPepper())
    .update(credential, "utf8")
    .digest("hex");
}

export function verifyRefreshCredential(
  credential: string,
  storedDigest: string,
): boolean {
  const expected = Buffer.from(storedDigest, "utf8");
  const provided = Buffer.from(refreshCredentialDigest(credential), "utf8");
  return (
    expected.length === provided.length && timingSafeEqual(expected, provided)
  );
}
