import { beforeAll, describe, expect, test } from "bun:test";
import {
  activateLicense,
  type LicenseAccess,
  type LicenseRecord,
  type LicenseStore,
  type MachineInput,
} from "@/lib/license";
import { FakeStoreV2 } from "./fakes";

beforeAll(() => {
  process.env.LICENSE_KEY_LOOKUP_PEPPER ??= "license-test-pepper";
});

class FakeLicenseStore implements LicenseStore {
  private readonly machines = new Map<string, MachineInput>();

  constructor(private readonly license: LicenseRecord | null) {}

  async runExclusive<T>(
    _key: string,
    operation: (access: LicenseAccess) => Promise<T>,
  ): Promise<T> {
    return operation(this);
  }

  async getLicenseByKey(_key: string): Promise<LicenseRecord | null> {
    return this.license;
  }

  async getMachine(licenseId: string, hardwareUuid: string) {
    const machine = this.machines.get(`${licenseId}:${hardwareUuid}`);
    return machine ? { licenseId, hardwareUuid } : null;
  }

  async countMachines(licenseId: string): Promise<number> {
    return [...this.machines.values()].filter(
      (machine) => machine.licenseId === licenseId,
    ).length;
  }

  async countActiveSeats(licenseId: string): Promise<number> {
    return this.countMachines(licenseId);
  }

  async upsertMachine(input: MachineInput): Promise<void> {
    this.machines.set(`${input.licenseId}:${input.hardwareUuid}`, input);
  }
}

const activeLicense: LicenseRecord = {
  id: "license-1",
  label: "Personal",
  maxMachines: 1,
  customMaxMachines: null,
  active: true,
};

describe("license activation", () => {
  test("reactivating the same machine is idempotent", async () => {
    const store = new FakeLicenseStore(activeLicense);
    const input = {
      key: "EDITH-1111-2222-3333-4444",
      hardwareUuid: "mac-1",
      hostname: "Studio Mac",
    };

    const first = await activateLicense(store, input);
    const second = await activateLicense(store, input);

    expect(first).toEqual({
      ok: true,
      label: "Personal",
      name: null,
      machinesUsed: 1,
      maxMachines: 1,
    });
    expect(second).toEqual(first);
    expect(await store.countMachines(activeLicense.id)).toBe(1);
  });

  test("rejects a new machine at the seat limit", async () => {
    const store = new FakeLicenseStore(activeLicense);
    const key = "EDITH-1111-2222-3333-4444";

    await activateLicense(store, { key, hardwareUuid: "mac-1" });
    const result = await activateLicense(store, {
      key,
      hardwareUuid: "mac-2",
    });

    expect(result).toEqual({
      ok: false,
      error: "license_limit_reached",
    });
    expect(await store.countMachines(activeLicense.id)).toBe(1);
  });

  test("rejects an inactive license", async () => {
    const store = new FakeLicenseStore({
      ...activeLicense,
      active: false,
    });

    const result = await activateLicense(store, {
      key: "EDITH-1111-2222-3333-4444",
      hardwareUuid: "mac-1",
    });

    expect(result).toEqual({ ok: false, error: "invalid_license" });
    expect(await store.countMachines(activeLicense.id)).toBe(0);
  });

  test("v2 devices plus v1 machines count against the combined allowance", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({
      key: "EDITH-1111-2222-3333-4444",
      maxMachines: 2,
    });
    await store.insertDevice({
      id: "device-1",
      licenseId: license.id,
      publicKey: "pk",
      publicKeyThumbprint: "thumb",
      hardwareUuidDigest: null,
      deviceName: null,
      appVersion: "2.0.0",
    });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "mac-1",
      hostname: null,
    });

    const result = await activateLicense(store, {
      key: license.key,
      hardwareUuid: "mac-2",
    });

    expect(result).toEqual({ ok: false, error: "license_limit_reached" });
    expect(await store.countActiveSeats(license.id)).toBe(2);
  });

  test("a custom allowance overrides the plan snapshot for v1 activation", async () => {
    const store = new FakeStoreV2();
    const license = store.addLicense({
      key: "EDITH-1111-2222-3333-4444",
      maxMachines: 1,
      customMaxMachines: 2,
    });
    await store.upsertMachine({
      licenseId: license.id,
      hardwareUuid: "mac-1",
      hostname: null,
    });

    const result = await activateLicense(store, {
      key: license.key,
      hardwareUuid: "mac-2",
    });

    expect(result).toEqual({
      ok: true,
      label: null,
      name: null,
      machinesUsed: 2,
      maxMachines: 2,
    });
  });
});
