import { createHmac, randomBytes } from "node:crypto";
import { beforeEach, describe, expect, mock, test } from "bun:test";
import { signAccessToken } from "@/lib/access-token";
import { FakeStoreV2, makeDeviceKey, signChallenge } from "./fakes";

process.env.LICENSE_KEY_LOOKUP_PEPPER = "route-test-pepper";
process.env.LICENSE_ACCESS_TOKEN_SECRET = "route-test-access-secret";
process.env.LICENSE_SIGNING_PRIVATE_KEY = randomBytes(32).toString("base64");
process.env.PAYMENT_WEBHOOK_SECRET = "route-test-webhook-secret";

const store = new FakeStoreV2();

mock.module("@/lib/db", () => ({ licenseStore: store }));
mock.module("@/lib/github", () => ({
  getLatestRelease: async () => ({
    assets: [
      { name: "Edith-v2.0.0.dmg", url: "https://upstream.test/dmg" },
      { name: "appcast.xml", url: "https://upstream.test/appcast" },
    ],
  }),
  findReleaseAsset: (
    assets: { name: string }[],
    predicate: (name: string) => boolean,
  ) => assets.find((asset) => predicate(asset.name)) ?? null,
  fetchReleaseAsset: async (asset: { name: string }) =>
    new Response(asset.name === "appcast.xml" ? "<rss/>" : "dmg-bytes"),
  rewriteAppcastEnclosureUrls: (xml: string) => xml,
}));

const activationChallengeRoute = await import(
  "@/app/api/v2/activation/challenge/route"
);
const activationRoute = await import("@/app/api/v2/activation/route");
const refreshChallengeRoute = await import(
  "@/app/api/v2/devices/refresh/challenge/route"
);
const refreshRoute = await import("@/app/api/v2/devices/refresh/route");
const deactivateRoute = await import("@/app/api/v2/devices/deactivate/route");
const migrateRoute = await import("@/app/api/v2/devices/migrate/route");
const webhookRoute = await import(
  "@/app/api/v2/payments/lemonsqueezy/webhook/route"
);
const dmgRoute = await import("@/app/api/v1/download/dmg/route");
const appcastRoute = await import("@/app/api/v1/appcast/route");

let ipCounter = 0;

function nextIp(): string {
  ipCounter += 1;
  return `10.0.${Math.floor(ipCounter / 250)}.${ipCounter % 250}`;
}

function postJson(
  path: string,
  body: unknown,
  ip: string,
  headers: Record<string, string> = {},
): Request {
  return new Request(`https://edith.test${path}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-forwarded-for": ip,
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

function getRequest(
  path: string,
  ip: string,
  headers: Record<string, string> = {},
): Request {
  return new Request(`https://edith.test${path}`, {
    headers: { "x-forwarded-for": ip, ...headers },
  });
}

let keyCounter = 0;
let licenseKey = "EDITH-AAAA-BBBB-CCCC-DDDD";

async function activateViaRoutes(
  deviceId: string,
  key = licenseKey,
  keyPair = makeDeviceKey(),
) {
  const challengeResponse = await activationChallengeRoute.POST(
    postJson(
      "/api/v2/activation/challenge",
      { licenseKey: key, deviceId, devicePublicKey: keyPair.encodedPublicKey },
      nextIp(),
    ),
  );
  const challenge = (await challengeResponse.json()) as {
    challengeId: string;
    nonce: string;
  };
  const activationResponse = await activationRoute.POST(
    postJson(
      "/api/v2/activation",
      {
        licenseKey: key,
        challengeId: challenge.challengeId,
        nonce: challenge.nonce,
        deviceId,
        devicePublicKey: keyPair.encodedPublicKey,
        signature: signChallenge(
          keyPair.privateKey,
          "activate",
          challenge.challengeId,
          challenge.nonce,
        ),
        appVersion: "2.0.0",
      },
      nextIp(),
    ),
  );
  return { challenge, activationResponse, keyPair };
}

async function issueRefreshChallenge(
  deviceId: string,
  refreshCredential: string,
  purpose?: "refresh" | "deactivate",
) {
  const response = await refreshChallengeRoute.POST(
    postJson(
      "/api/v2/devices/refresh/challenge",
      { deviceId, refreshCredential, ...(purpose ? { purpose } : {}) },
      nextIp(),
    ),
  );
  return {
    response,
    challenge: (await response.clone().json()) as {
      challengeId: string;
      nonce: string;
    },
  };
}

beforeEach(() => {
  store.reset();
  keyCounter += 1;
  licenseKey = `EDITH-${String(keyCounter).padStart(4, "0")}-AAAA-BBBB-CCCC`;
});

describe("v2 activation routes", () => {
  test("activation happy path issues entitlement, credential, and tokens", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 3 });
    const { activationResponse } = await activateViaRoutes("device-1");

    expect(activationResponse.status).toBe(200);

    const body = (await activationResponse.json()) as Record<string, unknown>;

    expect(body).toMatchObject({
      ok: true,
      planId: "personal_3",
      machinesUsed: 1,
      maxMachines: 3,
    });
    expect(String(body.refreshCredential)).toStartWith("edithrc_");
    expect(String(body.accessToken)).toContain(".");
    expect(
      Number.isNaN(Date.parse(String(body.accessTokenExpiresAt))),
    ).toBe(false);

    const payloadSegment = String(body.entitlement).split(".")[0];
    const entitlement = JSON.parse(
      Buffer.from(payloadSegment, "base64url").toString("utf8"),
    ) as Record<string, unknown>;

    expect(entitlement).toMatchObject({
      version: 2,
      productId: "edith",
      deviceId: "device-1",
      planId: "personal_3",
      maxMachines: 3,
    });
  });

  test("unknown key gets generic invalid_credentials", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 3 });
    const { activationResponse } = await activateViaRoutes(
      "device-1",
      "EDITH-0000-0000-0000-0000",
    );

    expect(activationResponse.status).toBe(403);
    expect(await activationResponse.json()).toEqual({
      error: "invalid_credentials",
    });
  });

  test("valid key over the limit gets counts", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });

    expect((await activateViaRoutes("device-1")).activationResponse.status).toBe(
      200,
    );

    const { activationResponse } = await activateViaRoutes("device-2");

    expect(activationResponse.status).toBe(403);
    expect(await activationResponse.json()).toEqual({
      error: "machine_limit_reached",
      machinesUsed: 1,
      maxMachines: 1,
    });
  });

  test("a challenge cannot be replayed through the route", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 3 });
    const keyPair = makeDeviceKey();
    const { challenge, activationResponse } = await activateViaRoutes(
      "device-1",
      licenseKey,
      keyPair,
    );

    expect(activationResponse.status).toBe(200);

    const replay = await activationRoute.POST(
      postJson(
        "/api/v2/activation",
        {
          licenseKey,
          challengeId: challenge.challengeId,
          nonce: challenge.nonce,
          deviceId: "device-2",
          devicePublicKey: keyPair.encodedPublicKey,
          signature: signChallenge(
            keyPair.privateKey,
            "activate",
            challenge.challengeId,
            challenge.nonce,
          ),
          appVersion: "2.0.0",
        },
        nextIp(),
      ),
    );

    expect(replay.status).toBe(403);
    expect(await replay.json()).toEqual({ error: "invalid_credentials" });
  });

  test("unknown body fields are rejected", async () => {
    const response = await activationRoute.POST(
      postJson(
        "/api/v2/activation",
        { licenseKey, maxMachines: 99 },
        nextIp(),
      ),
    );

    expect(response.status).toBe(400);
  });

  test("challenge issuance is rate limited per ip with retry-after", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 3 });
    const ip = nextIp();
    const keyPair = makeDeviceKey();
    let lastResponse: Response | null = null;

    for (let attempt = 0; attempt < 21; attempt += 1) {
      lastResponse = await activationChallengeRoute.POST(
        postJson(
          "/api/v2/activation/challenge",
          {
            licenseKey,
            deviceId: "device-1",
            devicePublicKey: keyPair.encodedPublicKey,
          },
          ip,
        ),
      );
    }

    expect(lastResponse?.status).toBe(429);
    expect(Number(lastResponse?.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await lastResponse?.json()).toEqual({ error: "rate_limited" });
  });
});

describe("v2 device routes", () => {
  test("refresh rotates the credential through the routes", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse, keyPair } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      refreshCredential: string;
    };
    const { response, challenge } = await issueRefreshChallenge(
      "device-1",
      session.refreshCredential,
    );

    expect(response.status).toBe(200);

    const refreshed = await refreshRoute.POST(
      postJson(
        "/api/v2/devices/refresh",
        {
          deviceId: "device-1",
          challengeId: challenge.challengeId,
          nonce: challenge.nonce,
          signature: signChallenge(
            keyPair.privateKey,
            "refresh",
            challenge.challengeId,
            challenge.nonce,
          ),
          appVersion: "2.0.1",
        },
        nextIp(),
      ),
    );

    expect(refreshed.status).toBe(200);

    const body = (await refreshed.json()) as { refreshCredential: string };

    expect(body.refreshCredential).toStartWith("edithrc_");
    expect(body.refreshCredential).not.toBe(session.refreshCredential);
  });

  test("a bad refresh credential gets generic invalid_credentials", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    await activateViaRoutes("device-1");

    const { response } = await issueRefreshChallenge(
      "device-1",
      "edithrc_not-the-real-credential",
    );

    expect(response.status).toBe(403);
  });

  test("deactivate frees the seat for another device", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse, keyPair } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      refreshCredential: string;
    };
    const { challenge } = await issueRefreshChallenge(
      "device-1",
      session.refreshCredential,
      "deactivate",
    );
    const deactivated = await deactivateRoute.POST(
      postJson(
        "/api/v2/devices/deactivate",
        {
          deviceId: "device-1",
          challengeId: challenge.challengeId,
          nonce: challenge.nonce,
          signature: signChallenge(
            keyPair.privateKey,
            "deactivate",
            challenge.challengeId,
            challenge.nonce,
          ),
        },
        nextIp(),
      ),
    );

    expect(deactivated.status).toBe(200);
    expect(await deactivated.json()).toEqual({ ok: true });

    const replacement = await activateViaRoutes("device-2");

    expect(replacement.activationResponse.status).toBe(200);
  });

  test("migrate converts a machine row without consuming a seat", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-1",
      hostname: "Studio Mac",
    });
    const keyPair = makeDeviceKey();
    const challengeResponse = await activationChallengeRoute.POST(
      postJson(
        "/api/v2/activation/challenge",
        {
          licenseKey,
          deviceId: "device-1",
          devicePublicKey: keyPair.encodedPublicKey,
          purpose: "migrate",
        },
        nextIp(),
      ),
    );
    const challenge = (await challengeResponse.json()) as {
      challengeId: string;
      nonce: string;
    };
    const migrated = await migrateRoute.POST(
      postJson(
        "/api/v2/devices/migrate",
        {
          licenseKey,
          hardwareUuid: "hw-1",
          challengeId: challenge.challengeId,
          nonce: challenge.nonce,
          deviceId: "device-1",
          devicePublicKey: keyPair.encodedPublicKey,
          signature: signChallenge(
            keyPair.privateKey,
            "migrate",
            challenge.challengeId,
            challenge.nonce,
          ),
          appVersion: "2.0.0",
        },
        nextIp(),
      ),
    );

    expect(migrated.status).toBe(200);
    expect(await migrated.json()).toMatchObject({
      ok: true,
      machinesUsed: 1,
      maxMachines: 1,
    });
    expect(await store.getMachine(license.id, "hw-1")).toBeNull();
    expect(await store.getDevice("device-1")).not.toBeNull();
  });
});

describe("protected downloads", () => {
  test("a bearer access token authorizes the dmg download", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      accessToken: string;
    };
    const response = await dmgRoute.GET(
      getRequest("/api/v1/download/dmg", nextIp(), {
        authorization: `Bearer ${session.accessToken}`,
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("dmg-bytes");
  });

  test("a bearer access token authorizes the appcast", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      accessToken: string;
    };
    const response = await appcastRoute.GET(
      getRequest("/api/v1/appcast", nextIp(), {
        authorization: `Bearer ${session.accessToken}`,
      }),
    );

    expect(response.status).toBe(200);
    expect(await response.text()).toBe("<rss/>");
  });

  test("an expired access token is rejected", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    await activateViaRoutes("device-1");
    const expired = signAccessToken({
      deviceId: "device-1",
      licenseId: "license-1",
      now: Math.floor(Date.now() / 1000) - 90_000,
    });
    const response = await dmgRoute.GET(
      getRequest("/api/v1/download/dmg", nextIp(), {
        authorization: `Bearer ${expired.token}`,
      }),
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "unlicensed" });
  });

  test("legacy license headers still authorize the download", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-legacy",
      hostname: null,
    });
    const response = await dmgRoute.GET(
      getRequest("/api/v1/download/dmg", nextIp(), {
        "x-edith-license": licenseKey,
        "x-edith-machine": "hw-legacy",
      }),
    );

    expect(response.status).toBe(200);
  });

  test("a refunded license's bearer token gets 403", async () => {
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      accessToken: string;
    };
    await store.updateLicenseStatus(license.id, "refunded", null);
    const response = await dmgRoute.GET(
      getRequest("/api/v1/download/dmg", nextIp(), {
        authorization: `Bearer ${session.accessToken}`,
      }),
    );

    expect(response.status).toBe(403);
  });

  test("a deactivated device's token stops working", async () => {
    store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { activationResponse } = await activateViaRoutes("device-1");
    const session = (await activationResponse.json()) as {
      accessToken: string;
    };
    await store.updateDeviceStatus("device-1", "deactivated", new Date());
    const response = await dmgRoute.GET(
      getRequest("/api/v1/download/dmg", nextIp(), {
        authorization: `Bearer ${session.accessToken}`,
      }),
    );

    expect(response.status).toBe(403);
  });
});

function signWebhook(rawBody: string): string {
  return createHmac("sha256", "route-test-webhook-secret")
    .update(rawBody, "utf8")
    .digest("hex");
}

function webhookRequest(
  payload: unknown,
  options: { signature?: string; ip?: string } = {},
): Request {
  const rawBody = JSON.stringify(payload);
  return new Request(
    "https://edith.test/api/v2/payments/lemonsqueezy/webhook",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-forwarded-for": options.ip ?? nextIp(),
        "x-signature": options.signature ?? signWebhook(rawBody),
      },
      body: rawBody,
    },
  );
}

function orderCreatedPayload(orderId: string, variantId: string) {
  return {
    meta: { event_name: "order_created" },
    data: {
      id: orderId,
      attributes: {
        customer_id: 42,
        first_order_item: { variant_id: variantId },
      },
    },
  };
}

describe("lemonsqueezy webhook", () => {
  test("an invalid signature is rejected with 401", async () => {
    const response = await webhookRoute.POST(
      webhookRequest(orderCreatedPayload("order-1", "variant-3"), {
        signature: "0".repeat(64),
      }),
    );

    expect(response.status).toBe(401);
    expect(store.paymentEvents.size).toBe(0);
  });

  test("order_created mints a license from the plan mapping", async () => {
    store.addPlan({
      id: "personal_3",
      provider: "lemonsqueezy",
      externalPriceId: "variant-3",
      maxMachines: 3,
    });
    const response = await webhookRoute.POST(
      webhookRequest(orderCreatedPayload("order-1", "variant-3")),
    );

    expect(response.status).toBe(200);

    const body = (await response.json()) as Record<string, unknown>;

    expect(body).toMatchObject({ ok: true, planId: "personal_3", maxMachines: 3 });
    expect(String(body.licenseKey)).toMatch(
      /^EDITH-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}$/,
    );

    const license = await store.getLicenseById(String(body.licenseId));

    expect(license).toMatchObject({
      planId: "personal_3",
      maxMachines: 3,
      status: "active",
    });
  });

  test("a replayed event returns the original result without a new license", async () => {
    store.addPlan({
      id: "personal_3",
      provider: "lemonsqueezy",
      externalPriceId: "variant-3",
      maxMachines: 3,
    });
    const payload = orderCreatedPayload("order-1", "variant-3");
    const first = await webhookRoute.POST(webhookRequest(payload));
    const firstBody = (await first.json()) as { licenseId: string };
    const replay = await webhookRoute.POST(webhookRequest(payload));

    expect(replay.status).toBe(200);
    expect(await replay.json()).toEqual({
      ok: true,
      licenseId: firstBody.licenseId,
      replayed: true,
    });
    expect(store.licensesById.size).toBe(1);
  });

  test("a concurrent duplicate hits the unique violation and one license exists", async () => {
    store.addPlan({
      id: "personal_3",
      provider: "lemonsqueezy",
      externalPriceId: "variant-3",
      maxMachines: 3,
    });

    const original = store.getPaymentEvent.bind(store);
    let lookups = 0;
    store.getPaymentEvent = async (provider, providerEventId) => {
      lookups += 1;
      return lookups <= 2 ? null : original(provider, providerEventId);
    };

    const payload = orderCreatedPayload("order-1", "variant-3");
    const first = await webhookRoute.POST(webhookRequest(payload));
    const second = await webhookRoute.POST(webhookRequest(payload));
    store.getPaymentEvent = original;

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect((await second.json()) as Record<string, unknown>).toMatchObject({
      ok: true,
      replayed: true,
    });
    expect(store.licensesById.size).toBe(1);
  });

  test("an unknown price records a failed event and mints nothing", async () => {
    const response = await webhookRoute.POST(
      webhookRequest(orderCreatedPayload("order-1", "variant-unknown")),
    );

    expect(response.status).toBe(422);
    expect(await response.json()).toEqual({ error: "unknown_price" });
    expect(store.licensesById.size).toBe(0);

    const event = await store.getPaymentEvent(
      "lemonsqueezy",
      "order_created:order-1",
    );

    expect(event).toMatchObject({
      processingState: "failed",
      error: "unknown_price",
    });
  });

  test("order_refunded marks the license refunded", async () => {
    store.addPlan({
      id: "personal_3",
      provider: "lemonsqueezy",
      externalPriceId: "variant-3",
      maxMachines: 3,
    });
    const created = await webhookRoute.POST(
      webhookRequest(orderCreatedPayload("order-1", "variant-3")),
    );
    const createdBody = (await created.json()) as { licenseId: string };
    const refunded = await webhookRoute.POST(
      webhookRequest({
        meta: { event_name: "order_refunded" },
        data: { id: "order-1", attributes: {} },
      }),
    );

    expect(refunded.status).toBe(200);

    const license = await store.getLicenseById(createdBody.licenseId);

    expect(license).toMatchObject({ status: "refunded", active: false });
  });

  test("order_chargeback marks the license chargeback", async () => {
    store.addPlan({
      id: "personal_3",
      provider: "lemonsqueezy",
      externalPriceId: "variant-3",
      maxMachines: 3,
    });
    const created = await webhookRoute.POST(
      webhookRequest(orderCreatedPayload("order-1", "variant-3")),
    );
    const createdBody = (await created.json()) as { licenseId: string };
    const chargeback = await webhookRoute.POST(
      webhookRequest({
        meta: { event_name: "order_chargeback" },
        data: { id: "order-1", attributes: {} },
      }),
    );

    expect(chargeback.status).toBe(200);

    const license = await store.getLicenseById(createdBody.licenseId);

    expect(license).toMatchObject({ status: "chargeback", active: false });
  });
});
