import { describe, expect, test } from "bun:test";
import {
  checkAuthFailures,
  checkKeyedRateLimit,
  checkRateLimit,
  getClientIp,
  registerAuthFailure,
} from "@/lib/ratelimit";

const windowStart = 1_700_000_400_000;

describe("client ip", () => {
  test("prefers x-forwarded-for", () => {
    const headers = new Headers({
      "x-forwarded-for": "1.2.3.4, 5.6.7.8",
      "x-real-ip": "9.9.9.9",
    });

    expect(getClientIp(headers)).toBe("1.2.3.4");
    expect(getClientIp(new Headers())).toBe("unknown");
  });
});

describe("memory rate limiting", () => {
  test("allows 20 requests per ip window then rejects with retry-after", async () => {
    for (let index = 0; index < 20; index += 1) {
      const result = await checkRateLimit("ip-a", "/route-ip", windowStart);
      expect(result.allowed).toBe(true);
    }

    const rejected = await checkRateLimit(
      "ip-a",
      "/route-ip",
      windowStart + 30_000,
    );

    expect(rejected.allowed).toBe(false);
    expect(rejected.retryAfterSeconds).toBe(30);

    const nextWindow = await checkRateLimit(
      "ip-a",
      "/route-ip",
      windowStart + 61_000,
    );

    expect(nextWindow.allowed).toBe(true);
  });

  test("keyed subjects get 30 per window and are isolated", async () => {
    for (let index = 0; index < 30; index += 1) {
      const result = await checkKeyedRateLimit(
        "digest-a",
        "/route-keyed",
        windowStart,
      );
      expect(result.allowed).toBe(true);
    }

    const rejected = await checkKeyedRateLimit(
      "digest-a",
      "/route-keyed",
      windowStart,
    );
    const other = await checkKeyedRateLimit(
      "digest-b",
      "/route-keyed",
      windowStart,
    );

    expect(rejected.allowed).toBe(false);
    expect(other.allowed).toBe(true);
  });

  test("failure bucket blocks after 5 failures with exponential retry-after", async () => {
    for (let index = 0; index < 4; index += 1) {
      await registerAuthFailure("ip-f", "/route-fail", windowStart);
    }

    const belowLimit = await checkAuthFailures(
      "ip-f",
      "/route-fail",
      windowStart,
    );

    expect(belowLimit.allowed).toBe(true);

    await registerAuthFailure("ip-f", "/route-fail", windowStart);
    const atLimit = await checkAuthFailures("ip-f", "/route-fail", windowStart);

    expect(atLimit.allowed).toBe(false);
    expect(atLimit.retryAfterSeconds).toBe(60);

    await registerAuthFailure("ip-f", "/route-fail", windowStart);
    await registerAuthFailure("ip-f", "/route-fail", windowStart);
    const escalated = await checkAuthFailures(
      "ip-f",
      "/route-fail",
      windowStart,
    );

    expect(escalated.allowed).toBe(false);
    expect(escalated.retryAfterSeconds).toBe(240);

    const nextWindow = await checkAuthFailures(
      "ip-f",
      "/route-fail",
      windowStart + 601_000,
    );

    expect(nextWindow.allowed).toBe(true);
  });
});
