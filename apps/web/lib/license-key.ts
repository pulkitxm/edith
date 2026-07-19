import { createHmac, randomBytes } from "node:crypto";

function getPepper(): string {
  const pepper = process.env.LICENSE_KEY_LOOKUP_PEPPER;

  if (!pepper) {
    throw new Error("LICENSE_KEY_LOOKUP_PEPPER is missing");
  }

  return pepper;
}

export function normalizeLicenseKey(key: string): string {
  return key.trim().toUpperCase();
}

export function generateLicenseKey(): string {
  const characters = randomBytes(8).toString("hex").toUpperCase();
  const groups = characters.match(/.{4}/g);

  if (!groups) {
    throw new Error("Unable to generate a license key");
  }

  return `EDITH-${groups.join("-")}`;
}

export function keyLookupDigest(key: string): string {
  return createHmac("sha256", getPepper())
    .update(normalizeLicenseKey(key), "utf8")
    .digest("hex");
}

export function displaySuffix(key: string): string {
  return normalizeLicenseKey(key).slice(-4);
}

export function redactSensitive(text: string): string {
  return text
    .replace(
      /EDITH-[A-Z0-9-]+/g,
      (match) => `EDITH-****-${match.slice(-4)}`,
    )
    .replace(/edithrc_[A-Za-z0-9_-]+/g, "edithrc_[redacted]")
    .replace(/Bearer\s+[A-Za-z0-9._~+/-]+=*/gi, "Bearer [redacted]");
}
