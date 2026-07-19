import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { signAccessToken, verifyAccessToken } from "@/lib/access-token";

const previousSecret = process.env.LICENSE_ACCESS_TOKEN_SECRET;
const previousTtl = process.env.LICENSE_ACCESS_TOKEN_TTL_MINUTES;

beforeAll(() => {
  process.env.LICENSE_ACCESS_TOKEN_SECRET = "sixteen-characters-minimum";
  delete process.env.LICENSE_ACCESS_TOKEN_TTL_MINUTES;
});

afterAll(() => {
  if (previousSecret === undefined) {
    delete process.env.LICENSE_ACCESS_TOKEN_SECRET;
  } else {
    process.env.LICENSE_ACCESS_TOKEN_SECRET = previousSecret;
  }

  if (previousTtl === undefined) {
    delete process.env.LICENSE_ACCESS_TOKEN_TTL_MINUTES;
  } else {
    process.env.LICENSE_ACCESS_TOKEN_TTL_MINUTES = previousTtl;
  }
});

describe("access tokens", () => {
  test("round-trips with the default 30 minute TTL", () => {
    const { token, expiresAt } = signAccessToken({
      deviceId: "device-1",
      licenseId: "license-1",
      now: 1_700_000_000,
    });

    expect(expiresAt).toBe(1_700_000_000 + 30 * 60);
    expect(verifyAccessToken(token, 1_700_000_100)).toEqual({
      v: 1,
      deviceId: "device-1",
      licenseId: "license-1",
      scope: ["download", "appcast"],
      iat: 1_700_000_000,
      exp: expiresAt,
    });
  });

  test("rejects an expired token", () => {
    const { token, expiresAt } = signAccessToken({
      deviceId: "device-1",
      licenseId: "license-1",
      now: 1_700_000_000,
    });

    expect(verifyAccessToken(token, expiresAt)).toBeNull();
  });

  test("rejects a tampered payload or signature", () => {
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: "license-1",
      now: 1_700_000_000,
    });
    const [payloadSegment, signatureSegment] = token.split(".");
    const forgedPayload = Buffer.from(
      JSON.stringify({
        v: 1,
        deviceId: "device-2",
        licenseId: "license-1",
        scope: ["download", "appcast"],
        iat: 1_700_000_000,
        exp: 1_700_002_000,
      }),
      "utf8",
    ).toString("base64url");

    expect(
      verifyAccessToken(`${forgedPayload}.${signatureSegment}`, 1_700_000_100),
    ).toBeNull();
    expect(
      verifyAccessToken(`${payloadSegment}.AAAA${signatureSegment.slice(4)}`, 1_700_000_100),
    ).toBeNull();
    expect(verifyAccessToken(payloadSegment, 1_700_000_100)).toBeNull();
  });

  test("requires a sufficiently long secret", () => {
    process.env.LICENSE_ACCESS_TOKEN_SECRET = "short";

    try {
      expect(() =>
        signAccessToken({ deviceId: "d", licenseId: "l", now: 0 }),
      ).toThrow();
    } finally {
      process.env.LICENSE_ACCESS_TOKEN_SECRET = "sixteen-characters-minimum";
    }
  });
});
