import { createHmac, randomBytes } from "node:crypto";
import { beforeEach, describe, expect, mock, test } from "bun:test";
import { signAccessToken } from "@/lib/access-token";
import { FakeStoreV2 } from "./fakes";

process.env.LICENSE_KEY_LOOKUP_PEPPER = "api-test-pepper";
process.env.LICENSE_ACCESS_TOKEN_SECRET = "api-test-access-secret";
process.env.LICENSE_SIGNING_PRIVATE_KEY = randomBytes(32).toString("base64");

const store = new FakeStoreV2();

mock.module("@/lib/db", () => ({ licenseStore: store }));

const { deviceSessionJson, isDownloadAuthorized } = await import(
  "@/lib/v2-api"
);

const licenseKey = "EDITH-AAAA-BBBB-CCCC-DDDD";

function headersOf(entries: Record<string, string>): Headers {
  return new Headers(entries);
}

function bearerHeaders(token: string): Headers {
  return headersOf({ authorization: `Bearer ${token}` });
}

function tokenWithScope(
  deviceId: string,
  licenseId: string,
  scope: string[],
): string {
  const now = Math.floor(Date.now() / 1000);
  const payloadSegment = Buffer.from(
    JSON.stringify({
      v: 1,
      deviceId,
      licenseId,
      scope,
      iat: now,
      exp: now + 1800,
    }),
    "utf8",
  ).toString("base64url");
  const signature = createHmac("sha256", "api-test-access-secret")
    .update(payloadSegment, "utf8")
    .digest("base64url");
  return `${payloadSegment}.${signature}`;
}

async function seedActiveDevice(deviceId = "device-1") {
  const license = store.addLicense({ key: licenseKey, maxMachines: 3 });
  await store.insertDevice({
    id: deviceId,
    licenseId: license.id,
    publicKey: "pk",
    publicKeyThumbprint: "thumb",
    hardwareUuidDigest: null,
    deviceName: null,
    appVersion: "2.0.0",
  });
  return license;
}

beforeEach(() => {
  store.reset();
});

describe("isDownloadAuthorized bearer path", () => {
  test("a valid token for an active matching device is authorized", async () => {
    const license = await seedActiveDevice();
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: license.id,
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      true,
    );
    expect(await isDownloadAuthorized(bearerHeaders(token), "appcast")).toBe(
      true,
    );
  });

  test("a malformed token is rejected", async () => {
    await seedActiveDevice();

    expect(
      await isDownloadAuthorized(bearerHeaders("not-a-token"), "download"),
    ).toBe(false);
  });

  test("an expired token is rejected", async () => {
    const license = await seedActiveDevice();
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: license.id,
      now: Math.floor(Date.now() / 1000) - 90_000,
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
  });

  test("a token missing the requested scope is rejected", async () => {
    const license = await seedActiveDevice();
    const token = tokenWithScope("device-1", license.id, ["appcast"]);

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
    expect(await isDownloadAuthorized(bearerHeaders(token), "appcast")).toBe(
      true,
    );
  });

  test("a token for a device on a refunded license is rejected", async () => {
    const license = await seedActiveDevice();
    await store.updateLicenseStatus(license.id, "refunded", null);
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: license.id,
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
  });

  test("a token for a deactivated device is rejected", async () => {
    const license = await seedActiveDevice();
    await store.updateDeviceStatus("device-1", "deactivated", new Date());
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: license.id,
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
  });

  test("a token whose licenseId does not match the device is rejected", async () => {
    await seedActiveDevice();
    const { token } = signAccessToken({
      deviceId: "device-1",
      licenseId: "some-other-license",
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
  });

  test("a token for an unknown device is rejected", async () => {
    const license = await seedActiveDevice();
    const { token } = signAccessToken({
      deviceId: "device-ghost",
      licenseId: license.id,
    });

    expect(await isDownloadAuthorized(bearerHeaders(token), "download")).toBe(
      false,
    );
  });
});

describe("isDownloadAuthorized header fallback path", () => {
  test("valid legacy license headers are authorized", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-1",
      hostname: null,
    });

    expect(
      await isDownloadAuthorized(
        headersOf({ "x-edith-license": licenseKey, "x-edith-machine": "hw-1" }),
        "download",
      ),
    ).toBe(true);
  });

  test("headers with an unregistered machine are rejected", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });

    expect(
      await isDownloadAuthorized(
        headersOf({ "x-edith-license": licenseKey, "x-edith-machine": "hw-1" }),
        "download",
      ),
    ).toBe(false);
  });

  test("headers with an unknown key are rejected", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-1",
      hostname: null,
    });

    expect(
      await isDownloadAuthorized(
        headersOf({
          "x-edith-license": "EDITH-0000-0000-0000-0000",
          "x-edith-machine": "hw-1",
        }),
        "download",
      ),
    ).toBe(false);
  });

  test("a request with neither bearer nor license headers is rejected", async () => {
    await seedActiveDevice();

    expect(await isDownloadAuthorized(headersOf({}), "download")).toBe(false);
  });

  test("a bad bearer is rejected even when valid license headers are present", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-1",
      hostname: null,
    });

    expect(
      await isDownloadAuthorized(
        headersOf({
          authorization: "Bearer bogus.token",
          "x-edith-license": licenseKey,
          "x-edith-machine": "hw-1",
        }),
        "download",
      ),
    ).toBe(false);
  });
});

describe("deviceSessionJson", () => {
  test("assembles entitlement and access token fields for the session", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 3 });
    const response = deviceSessionJson("device-1", {
      ok: true,
      licenseId: license.id,
      planId: "personal_3",
      machinesUsed: 2,
      maxMachines: 3,
      deviceKeyThumbprint: "thumb-1",
      refreshCredential: "edithrc_fresh",
    });

    expect(response.status).toBe(200);

    const body = (await response.json()) as Record<string, unknown>;

    expect(Object.keys(body).sort()).toEqual([
      "accessToken",
      "accessTokenExpiresAt",
      "entitlement",
      "machinesUsed",
      "maxMachines",
      "ok",
      "planId",
      "refreshCredential",
    ]);
    expect(body).toMatchObject({
      ok: true,
      planId: "personal_3",
      machinesUsed: 2,
      maxMachines: 3,
      refreshCredential: "edithrc_fresh",
    });
    const expiresAtMs = Date.parse(String(body.accessTokenExpiresAt));

    expect(Number.isNaN(expiresAtMs)).toBe(false);
    expect(expiresAtMs).toBeGreaterThan(Date.now());

    const tokenPayload = JSON.parse(
      Buffer.from(String(body.accessToken).split(".")[0], "base64url").toString(
        "utf8",
      ),
    ) as Record<string, unknown>;

    expect(tokenPayload).toMatchObject({
      v: 1,
      deviceId: "device-1",
      licenseId: license.id,
      scope: ["download", "appcast"],
    });
    expect((tokenPayload.exp as number) * 1000).toBe(expiresAtMs);

    const entitlement = JSON.parse(
      Buffer.from(String(body.entitlement).split(".")[0], "base64url").toString(
        "utf8",
      ),
    ) as Record<string, unknown>;

    expect(entitlement).toMatchObject({
      version: 2,
      productId: "edith",
      licenseId: license.id,
      deviceId: "device-1",
      deviceKeyThumbprint: "thumb-1",
      planId: "personal_3",
      maxMachines: 3,
      features: ["edith-core"],
      policyVersion: 2,
    });
    expect(typeof entitlement.receiptId).toBe("string");
    expect(entitlement.notBefore).toBe(entitlement.issuedAt);
    expect(entitlement.expiresAt as number).toBeGreaterThan(
      entitlement.issuedAt as number,
    );
  });

  test("a null planId falls back to custom", async () => {
    const response = deviceSessionJson("device-2", {
      ok: true,
      licenseId: "license-x",
      planId: null,
      machinesUsed: 1,
      maxMachines: 5,
      deviceKeyThumbprint: "thumb-2",
      refreshCredential: "edithrc_other",
    });
    const body = (await response.json()) as Record<string, unknown>;

    expect(body.planId).toBe("custom");

    const entitlement = JSON.parse(
      Buffer.from(String(body.entitlement).split(".")[0], "base64url").toString(
        "utf8",
      ),
    ) as Record<string, unknown>;

    expect(entitlement.planId).toBe("custom");
  });
});
