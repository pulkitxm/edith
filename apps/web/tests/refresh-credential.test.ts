import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  generateRefreshCredential,
  refreshCredentialDigest,
  verifyRefreshCredential,
} from "@/lib/refresh-credential";

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

describe("refresh credentials", () => {
  test("uses the edithrc_ prefix with 32 random bytes", () => {
    const credential = generateRefreshCredential();

    expect(credential).toMatch(/^edithrc_[A-Za-z0-9_-]{43}$/);
    expect(generateRefreshCredential()).not.toBe(credential);
  });

  test("digest verifies only the original credential", () => {
    const credential = generateRefreshCredential();
    const digest = refreshCredentialDigest(credential);

    expect(digest).toMatch(/^[a-f0-9]{64}$/);
    expect(verifyRefreshCredential(credential, digest)).toBe(true);
    expect(verifyRefreshCredential(generateRefreshCredential(), digest)).toBe(
      false,
    );
    expect(verifyRefreshCredential(credential, "deadbeef")).toBe(false);
  });
});
