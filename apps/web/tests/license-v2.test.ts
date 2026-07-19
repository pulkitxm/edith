import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  activateDeviceV2,
  deactivateDeviceV2,
  migrateMachineV2,
  refreshDeviceV2,
  verifyDeviceRefreshCredential,
} from "@/lib/license";
import {
  FakeStoreV2,
  issueChallenge,
  makeDeviceKey,
  signChallenge,
  type StoredLicense,
} from "./fakes";

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

async function activate(
  store: FakeStoreV2,
  license: StoredLicense,
  deviceId: string,
  keyPair = makeDeviceKey(),
) {
  const { challengeId, nonce } = await issueChallenge(store, "activate", {
    licenseId: license.id,
  });
  const result = await activateDeviceV2(store, {
    licenseKey: license.key,
    challengeId,
    nonce,
    deviceId,
    devicePublicKey: keyPair.encodedPublicKey,
    signature: signChallenge(keyPair.privateKey, "activate", challengeId, nonce),
    appVersion: "2.0.0",
  });
  return { result, keyPair };
}

const licenseKey = "EDITH-1111-2222-3333-4444";

describe("v2 activation", () => {
  test.each([1, 3, 5])(
    "fills every seat at allowance %i then rejects the next device",
    async (allowance) => {
      const store = new FakeStoreV2();
      const license = store.addLicense({
        key: licenseKey,
        maxMachines: allowance,
      });

      for (let seat = 1; seat <= allowance; seat += 1) {
        const { result } = await activate(store, license, `device-${seat}`);

        expect(result).toMatchObject({
          ok: true,
          planId: "personal_3",
          machinesUsed: seat,
          maxMachines: allowance,
        });
      }

      const { result } = await activate(store, license, "device-extra");

      expect(result).toEqual({
        ok: false,
        error: "machine_limit_reached",
        machinesUsed: allowance,
        maxMachines: allowance,
      });
    },
  );

  test("unknown key returns invalid_credentials, not seat details", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { result } = await activate(
      store,
      { ...license, key: "EDITH-0000-0000-0000-0000" },
      "device-1",
    );

    expect(result).toEqual({ ok: false, error: "invalid_credentials" });
  });

  test("re-activation of the same device is idempotent", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const first = await activate(store, license, "device-1");
    const second = await activate(store, license, "device-1", first.keyPair);

    expect(first.result.ok).toBe(true);
    expect(second.result).toMatchObject({
      ok: true,
      machinesUsed: 1,
      maxMachines: 1,
    });
    expect(await store.countActiveSeats(license.id)).toBe(1);
  });

  test("a consumed challenge cannot be replayed", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 3 });
    const keyPair = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(store, "activate", {
      licenseId: license.id,
    });
    const input = {
      licenseKey: license.key,
      challengeId,
      nonce,
      deviceId: "device-1",
      devicePublicKey: keyPair.encodedPublicKey,
      signature: signChallenge(keyPair.privateKey, "activate", challengeId, nonce),
      appVersion: "2.0.0",
    };

    expect((await activateDeviceV2(store, input)).ok).toBe(true);
    expect(await activateDeviceV2(store, { ...input, deviceId: "device-2" })).toEqual({
      ok: false,
      error: "invalid_credentials",
    });
  });

  test("an expired challenge fails", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 3 });
    const keyPair = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(
      store,
      "activate",
      { licenseId: license.id },
      new Date(Date.now() - 1_000),
    );

    const result = await activateDeviceV2(store, {
      licenseKey: license.key,
      challengeId,
      nonce,
      deviceId: "device-1",
      devicePublicKey: keyPair.encodedPublicKey,
      signature: signChallenge(keyPair.privateKey, "activate", challengeId, nonce),
      appVersion: "2.0.0",
    });

    expect(result).toEqual({ ok: false, error: "invalid_credentials" });
  });

  test("a signature from another key fails", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 3 });
    const device = makeDeviceKey();
    const attacker = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(store, "activate", {
      licenseId: license.id,
    });

    const result = await activateDeviceV2(store, {
      licenseKey: license.key,
      challengeId,
      nonce,
      deviceId: "device-1",
      devicePublicKey: device.encodedPublicKey,
      signature: signChallenge(
        attacker.privateKey,
        "activate",
        challengeId,
        nonce,
      ),
      appVersion: "2.0.0",
    });

    expect(result).toEqual({ ok: false, error: "invalid_credentials" });
    expect(await store.countActiveSeats(license.id)).toBe(0);
  });
});

describe("v2 refresh", () => {
  test("rotates the credential with a 60 second overlap", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { result, keyPair } = await activate(store, license, "device-1");

    expect(result.ok).toBe(true);

    const oldCredential = result.ok ? result.refreshCredential : "";
    const { challengeId, nonce } = await issueChallenge(store, "refresh", {
      deviceId: "device-1",
    });
    const now = new Date();
    const refreshed = await refreshDeviceV2(
      store,
      {
        deviceId: "device-1",
        challengeId,
        nonce,
        signature: signChallenge(keyPair.privateKey, "refresh", challengeId, nonce),
        appVersion: "2.0.1",
      },
      now,
    );

    expect(refreshed.ok).toBe(true);

    const newCredential = refreshed.ok ? refreshed.refreshCredential : "";

    expect(newCredential).not.toBe(oldCredential);
    expect(
      await verifyDeviceRefreshCredential(store, "device-1", newCredential, now),
    ).toBe(true);
    expect(
      await verifyDeviceRefreshCredential(
        store,
        "device-1",
        oldCredential,
        new Date(now.getTime() + 30_000),
      ),
    ).toBe(true);
    expect(
      await verifyDeviceRefreshCredential(
        store,
        "device-1",
        oldCredential,
        new Date(now.getTime() + 61_000),
      ),
    ).toBe(false);
  });

  test("a copied refresh credential without the private key fails", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const { result } = await activate(store, license, "device-1");

    expect(result.ok).toBe(true);

    const stolenCredential = result.ok ? result.refreshCredential : "";

    expect(
      await verifyDeviceRefreshCredential(store, "device-1", stolenCredential),
    ).toBe(true);

    const attacker = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(store, "refresh", {
      deviceId: "device-1",
    });
    const refreshed = await refreshDeviceV2(store, {
      deviceId: "device-1",
      challengeId,
      nonce,
      signature: signChallenge(attacker.privateKey, "refresh", challengeId, nonce),
      appVersion: "2.0.1",
    });

    expect(refreshed).toEqual({ ok: false, error: "invalid_credentials" });
  });
});

describe("v2 deactivation", () => {
  test("frees exactly one seat and revokes credentials", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const first = await activate(store, license, "device-1");

    expect(first.result.ok).toBe(true);
    expect((await activate(store, license, "device-2")).result).toMatchObject({
      ok: false,
      error: "machine_limit_reached",
    });

    const credential = first.result.ok ? first.result.refreshCredential : "";
    const { challengeId, nonce } = await issueChallenge(store, "deactivate", {
      deviceId: "device-1",
    });
    const deactivated = await deactivateDeviceV2(store, {
      deviceId: "device-1",
      challengeId,
      nonce,
      signature: signChallenge(
        first.keyPair.privateKey,
        "deactivate",
        challengeId,
        nonce,
      ),
    });

    expect(deactivated).toEqual({ ok: true });
    expect(await store.countActiveSeats(license.id)).toBe(0);
    expect(
      await verifyDeviceRefreshCredential(store, "device-1", credential),
    ).toBe(false);
    expect(
      store.securityEvents.some(
        (event) => event.eventType === "device_deactivated",
      ),
    ).toBe(true);

    const replacement = await activate(store, license, "device-2");

    expect(replacement.result).toMatchObject({
      ok: true,
      machinesUsed: 1,
      maxMachines: 1,
    });
  });
});

describe("v2 migration", () => {
  test("converts a v1 machine without consuming a seat", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "hw-1",
      hostname: "Studio Mac",
    });

    expect(await store.countActiveSeats(license.id)).toBe(1);

    const keyPair = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(store, "migrate", {
      licenseId: license.id,
    });
    const result = await migrateMachineV2(store, {
      licenseKey: license.key,
      hardwareUuid: "hw-1",
      challengeId,
      nonce,
      deviceId: "device-1",
      devicePublicKey: keyPair.encodedPublicKey,
      signature: signChallenge(keyPair.privateKey, "migrate", challengeId, nonce),
      appVersion: "2.0.0",
    });

    expect(result).toMatchObject({
      ok: true,
      machinesUsed: 1,
      maxMachines: 1,
    });
    expect(await store.getMachine(license.id, "hw-1")).toBeNull();
    expect(await store.getDevice("device-1")).not.toBeNull();
    expect(await store.countActiveSeats(license.id)).toBe(1);
  });

  test("requires an existing machine row", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({ key: licenseKey, maxMachines: 1 });
    const keyPair = makeDeviceKey();
    const { challengeId, nonce } = await issueChallenge(store, "migrate", {
      licenseId: license.id,
    });

    const result = await migrateMachineV2(store, {
      licenseKey: license.key,
      hardwareUuid: "hw-missing",
      challengeId,
      nonce,
      deviceId: "device-1",
      devicePublicKey: keyPair.encodedPublicKey,
      signature: signChallenge(keyPair.privateKey, "migrate", challengeId, nonce),
      appVersion: "2.0.0",
    });

    expect(result).toEqual({ ok: false, error: "invalid_credentials" });
  });
});
