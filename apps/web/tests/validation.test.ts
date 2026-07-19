import { describe, expect, test } from "bun:test";
import {
  activationBodySchema,
  deactivateV2BodySchema,
  licenseKeySchema,
  parseBearerToken,
  parseLicenseHeaders,
  refreshChallengeBodySchema,
  refreshV2BodySchema,
} from "@/lib/validation";

const validKey = "EDITH-AB12-CD34-EF56-GH78";
const uuid = "0b6f9f9e-1c2d-4e3f-8a9b-0c1d2e3f4a5b";

describe("parseBearerToken", () => {
  test("extracts the token from a valid Bearer header", () => {
    const headers = new Headers({ authorization: "Bearer abc123" });
    expect(parseBearerToken(headers)).toBe("abc123");
  });

  test("returns null when the header is missing", () => {
    expect(parseBearerToken(new Headers())).toBeNull();
  });

  test("returns null for an empty token", () => {
    const headers = new Headers({ authorization: "Bearer " });
    expect(parseBearerToken(headers)).toBeNull();
  });

  test("returns null for a different scheme", () => {
    const headers = new Headers({ authorization: "Basic abc123" });
    expect(parseBearerToken(headers)).toBeNull();
  });

  test("accepts any casing of the scheme", () => {
    expect(
      parseBearerToken(new Headers({ authorization: "bearer tok" })),
    ).toBe("tok");
    expect(
      parseBearerToken(new Headers({ authorization: "BEARER tok" })),
    ).toBe("tok");
  });

  test("tolerates surrounding and internal extra whitespace", () => {
    const headers = new Headers({ authorization: "   Bearer    tok   " });
    expect(parseBearerToken(headers)).toBe("tok");
  });

  test("returns null when the token contains spaces", () => {
    const headers = new Headers({ authorization: "Bearer a b" });
    expect(parseBearerToken(headers)).toBeNull();
  });
});

describe("parseLicenseHeaders", () => {
  test("succeeds when both headers are present and valid", () => {
    const headers = new Headers({
      "x-edith-license": validKey,
      "x-edith-machine": "machine-1",
    });
    const result = parseLicenseHeaders(headers);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data).toEqual({ key: validKey, hardwareUuid: "machine-1" });
    }
  });

  test("fails when the license header is missing", () => {
    const headers = new Headers({ "x-edith-machine": "machine-1" });
    const result = parseLicenseHeaders(headers);
    expect(result.success).toBe(false);
  });

  test("fails when the machine header is missing", () => {
    const headers = new Headers({ "x-edith-license": validKey });
    const result = parseLicenseHeaders(headers);
    expect(result.success).toBe(false);
  });

  test("fails on malformed values", () => {
    const headers = new Headers({
      "x-edith-license": "EDITH-lower-case-bad-keyy",
      "x-edith-machine": "   ",
    });
    const result = parseLicenseHeaders(headers);
    expect(result.success).toBe(false);
  });
});

describe("licenseKeySchema", () => {
  test("accepts EDITH-XXXX-XXXX-XXXX-XXXX shapes", () => {
    expect(licenseKeySchema.safeParse(validKey).success).toBe(true);
    expect(licenseKeySchema.safeParse("EDITH-0000-1111-2222-3333").success).toBe(
      true,
    );
  });

  test("rejects wrong segment counts", () => {
    expect(licenseKeySchema.safeParse("EDITH-AB12-CD34-EF56").success).toBe(
      false,
    );
    expect(
      licenseKeySchema.safeParse("EDITH-AB12-CD34-EF56-GH78-IJ90").success,
    ).toBe(false);
  });

  test("rejects lowercase", () => {
    expect(
      licenseKeySchema.safeParse("EDITH-ab12-cd34-ef56-gh78").success,
    ).toBe(false);
  });

  test("rejects a wrong prefix", () => {
    expect(
      licenseKeySchema.safeParse("EDYTH-AB12-CD34-EF56-GH78").success,
    ).toBe(false);
  });
});

describe("refreshChallengeBodySchema refreshCredential", () => {
  test("accepts edithrc_ tokens", () => {
    const body = { deviceId: "dev-1", refreshCredential: "edithrc_abc-DEF_123" };
    expect(refreshChallengeBodySchema.safeParse(body).success).toBe(true);
  });

  test("rejects tokens without the edithrc_ prefix", () => {
    const body = { deviceId: "dev-1", refreshCredential: "rc_abc123" };
    expect(refreshChallengeBodySchema.safeParse(body).success).toBe(false);
  });
});

describe("strict body schemas", () => {
  const refreshBody = {
    deviceId: "dev-1",
    challengeId: uuid,
    nonce: "nonce_abc",
    signature: "sig_abc",
    appVersion: "1.0.0",
  };
  const deactivateBody = {
    deviceId: "dev-1",
    challengeId: uuid,
    nonce: "nonce_abc",
    signature: "sig_abc",
  };

  test("activationBodySchema accepts a minimal valid body", () => {
    const body = { key: validKey, hardwareUuid: "hw-1" };
    expect(activationBodySchema.safeParse(body).success).toBe(true);
  });

  test("activationBodySchema rejects unknown extra keys", () => {
    const body = { key: validKey, hardwareUuid: "hw-1", extra: "nope" };
    expect(activationBodySchema.safeParse(body).success).toBe(false);
  });

  test("activationBodySchema rejects missing required keys", () => {
    expect(activationBodySchema.safeParse({ key: validKey }).success).toBe(
      false,
    );
  });

  test("refreshV2BodySchema accepts a minimal valid body", () => {
    expect(refreshV2BodySchema.safeParse(refreshBody).success).toBe(true);
  });

  test("refreshV2BodySchema rejects unknown extra keys", () => {
    expect(
      refreshV2BodySchema.safeParse({ ...refreshBody, extra: 1 }).success,
    ).toBe(false);
  });

  test("refreshV2BodySchema rejects missing required keys", () => {
    const { appVersion, ...rest } = refreshBody;
    expect(refreshV2BodySchema.safeParse(rest).success).toBe(false);
  });

  test("deactivateV2BodySchema accepts a minimal valid body", () => {
    expect(deactivateV2BodySchema.safeParse(deactivateBody).success).toBe(true);
  });

  test("deactivateV2BodySchema rejects unknown extra keys", () => {
    expect(
      deactivateV2BodySchema.safeParse({ ...deactivateBody, extra: 1 })
        .success,
    ).toBe(false);
  });

  test("deactivateV2BodySchema rejects missing required keys", () => {
    const { signature, ...rest } = deactivateBody;
    expect(deactivateV2BodySchema.safeParse(rest).success).toBe(false);
  });
});
