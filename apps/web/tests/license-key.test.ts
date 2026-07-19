import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  displaySuffix,
  generateLicenseKey,
  keyLookupDigest,
  normalizeLicenseKey,
  redactSensitive,
} from "@/lib/license-key";

const previousPepper = process.env.LICENSE_KEY_LOOKUP_PEPPER;

beforeAll(() => {
  process.env.LICENSE_KEY_LOOKUP_PEPPER = "test-pepper-value";
});

afterAll(() => {
  if (previousPepper === undefined) {
    delete process.env.LICENSE_KEY_LOOKUP_PEPPER;
  } else {
    process.env.LICENSE_KEY_LOOKUP_PEPPER = previousPepper;
  }
});

describe("license keys", () => {
  test("generates keys in the EDITH format", () => {
    expect(generateLicenseKey()).toMatch(
      /^EDITH-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}$/,
    );
  });

  test("normalizes case and whitespace", () => {
    expect(normalizeLicenseKey(" edith-1111-2222-3333-4444 ")).toBe(
      "EDITH-1111-2222-3333-4444",
    );
  });

  test("digest is stable across normalization and hex encoded", () => {
    const digest = keyLookupDigest("EDITH-1111-2222-3333-4444");

    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(keyLookupDigest("edith-1111-2222-3333-4444")).toBe(digest);
    expect(keyLookupDigest("EDITH-1111-2222-3333-5555")).not.toBe(digest);
  });

  test("digest requires the pepper", () => {
    delete process.env.LICENSE_KEY_LOOKUP_PEPPER;

    expect(() => keyLookupDigest("EDITH-1111-2222-3333-4444")).toThrow();

    process.env.LICENSE_KEY_LOOKUP_PEPPER = "test-pepper-value";
  });

  test("display suffix is the last four characters", () => {
    expect(displaySuffix("edith-1111-2222-3333-4444")).toBe("4444");
  });

  test("redacts keys, refresh credentials, and bearer tokens", () => {
    const redacted = redactSensitive(
      "key EDITH-1111-2222-3333-4444 cred edithrc_abcDEF123-_ auth Bearer abc.def-ghi",
    );

    expect(redacted).toBe(
      "key EDITH-****-4444 cred edithrc_[redacted] auth Bearer [redacted]",
    );
    expect(redacted).not.toContain("1111");
    expect(redacted).not.toContain("abcDEF123");
  });
});
