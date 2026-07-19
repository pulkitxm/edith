import { generateKeyPairSync, randomUUID, sign } from "node:crypto";
import {
  challengeMessage,
  createChallengeNonce,
  nonceDigest,
} from "@/lib/device-auth";
import { keyLookupDigest } from "@/lib/license-key";
import type {
  ChallengeInput,
  ChallengeRecord,
  CredentialRecord,
  DeviceInput,
  DeviceRecord,
  LicenseAccessV2,
  LicenseStoreV2,
  LicenseV2Record,
  MachineInput,
  NewLicenseInput,
  PaymentEventRecord,
  SecurityEventInput,
} from "@/lib/license";

export type StoredLicense = LicenseV2Record & {
  key: string;
  keyDigest: string;
};
export type StoredDevice = DeviceRecord & { deactivatedAt: Date | null };
export type StoredChallenge = ChallengeRecord & { consumedAt: Date | null };
export type StoredCredential = CredentialRecord & {
  revocationReason: string | null;
};
export type StoredPaymentEvent = PaymentEventRecord & {
  orderId: string | null;
};
export type StoredPlan = {
  id: string;
  provider: string;
  externalPriceId: string;
  maxMachines: number;
};

export class FakeStoreV2 implements LicenseStoreV2 {
  readonly licensesById = new Map<string, StoredLicense>();
  readonly machines = new Map<string, MachineInput>();
  readonly devices = new Map<string, StoredDevice>();
  readonly challenges = new Map<string, StoredChallenge>();
  readonly credentials: StoredCredential[] = [];
  readonly securityEvents: SecurityEventInput[] = [];
  readonly paymentEvents = new Map<string, StoredPaymentEvent>();
  readonly plans = new Map<string, StoredPlan>();

  reset(): void {
    this.licensesById.clear();
    this.machines.clear();
    this.devices.clear();
    this.challenges.clear();
    this.credentials.length = 0;
    this.securityEvents.length = 0;
    this.paymentEvents.clear();
    this.plans.clear();
  }

  addLicense(input: {
    key: string;
    maxMachines: number;
    planId?: string;
    customMaxMachines?: number;
    status?: string;
  }): StoredLicense {
    const license: StoredLicense = {
      id: randomUUID(),
      key: input.key,
      keyDigest: keyLookupDigest(input.key),
      label: null,
      planId: input.planId ?? "personal_3",
      status: input.status ?? "active",
      active: (input.status ?? "active") === "active",
      maxMachines: input.maxMachines,
      customMaxMachines: input.customMaxMachines ?? null,
      keyLast4: input.key.slice(-4),
    };
    this.licensesById.set(license.id, license);
    return license;
  }

  addPlan(input: StoredPlan): void {
    this.plans.set(input.id, input);
  }

  async runExclusive<T>(
    _key: string,
    operation: (access: LicenseAccessV2) => Promise<T>,
  ): Promise<T> {
    return operation(this);
  }

  async getLicenseByKey(key: string) {
    const license = [...this.licensesById.values()].find(
      (record) => record.key === key,
    );
    return license ?? null;
  }

  async getLicenseByKeyDigest(digest: string, key: string) {
    const license = [...this.licensesById.values()].find(
      (record) => record.keyDigest === digest || record.key === key,
    );
    return license ?? null;
  }

  async getLicenseById(licenseId: string) {
    return this.licensesById.get(licenseId) ?? null;
  }

  async updateLicenseStatus(
    licenseId: string,
    status: string,
    reason: string | null,
  ) {
    const license = this.licensesById.get(licenseId);

    if (license) {
      license.status = status;
      license.active = status === "active";
      void reason;
    }
  }

  async insertLicense(input: NewLicenseInput) {
    const license: StoredLicense = {
      id: randomUUID(),
      key: input.key,
      keyDigest: input.keyDigest,
      label: input.label,
      planId: input.planId,
      status: "active",
      active: true,
      maxMachines: input.maxMachines,
      customMaxMachines: null,
      keyLast4: input.keyLast4,
    };
    this.licensesById.set(license.id, license);
    return { id: license.id };
  }

  async getPlanByPriceId(provider: string, priceId: string) {
    const plan = [...this.plans.values()].find(
      (record) =>
        record.provider === provider && record.externalPriceId === priceId,
    );
    return plan ? { id: plan.id, maxMachines: plan.maxMachines } : null;
  }

  async getLicenseIdByOrderId(provider: string, orderId: string) {
    void provider;
    const event = [...this.paymentEvents.values()].find(
      (record) => record.orderId === orderId && record.licenseId !== null,
    );
    return event?.licenseId ?? null;
  }

  async getMachine(licenseId: string, hardwareUuid: string) {
    const machine = this.machines.get(`${licenseId}:${hardwareUuid}`);
    return machine ? { licenseId, hardwareUuid } : null;
  }

  async countMachines(licenseId: string) {
    return [...this.machines.values()].filter(
      (machine) => machine.licenseId === licenseId,
    ).length;
  }

  async upsertMachine(input: MachineInput) {
    this.machines.set(`${input.licenseId}:${input.hardwareUuid}`, input);
  }

  async deleteMachine(licenseId: string, hardwareUuid: string) {
    this.machines.delete(`${licenseId}:${hardwareUuid}`);
  }

  async getDevice(deviceId: string) {
    return this.devices.get(deviceId) ?? null;
  }

  async insertDevice(input: DeviceInput) {
    this.devices.set(input.id, {
      id: input.id,
      licenseId: input.licenseId,
      publicKey: input.publicKey,
      publicKeyThumbprint: input.publicKeyThumbprint,
      status: "active",
      credentialGeneration: 0,
      deactivatedAt: null,
    });
  }

  async updateDeviceStatus(deviceId: string, status: string, now: Date) {
    const device = this.devices.get(deviceId);

    if (device) {
      device.status = status;
      device.deactivatedAt = status === "active" ? null : now;
    }
  }

  async touchDeviceVerification(
    _deviceId: string,
    _appVersion: string | null,
    _now: Date,
  ) {}

  async countActiveSeats(licenseId: string) {
    const activeDevices = [...this.devices.values()].filter(
      (device) => device.licenseId === licenseId && device.status === "active",
    ).length;
    return activeDevices + (await this.countMachines(licenseId));
  }

  async insertChallenge(input: ChallengeInput) {
    this.challenges.set(input.id, { ...input, consumedAt: null });
  }

  async consumeChallenge(challengeId: string, now: Date) {
    const challenge = this.challenges.get(challengeId);

    if (!challenge || challenge.consumedAt) {
      return null;
    }

    challenge.consumedAt = now;
    return challenge;
  }

  async insertCredential(input: {
    deviceId: string;
    tokenDigest: string;
    generation: number;
    issuedAt: Date;
  }) {
    this.credentials.push({
      id: randomUUID(),
      deviceId: input.deviceId,
      tokenDigest: input.tokenDigest,
      generation: input.generation,
      expiresAt: null,
      revokedAt: null,
      revocationReason: null,
    });
    const device = this.devices.get(input.deviceId);

    if (device) {
      device.credentialGeneration = input.generation;
    }
  }

  async getActiveCredentials(deviceId: string, now: Date) {
    return this.credentials.filter(
      (credential) =>
        credential.deviceId === deviceId &&
        credential.revokedAt === null &&
        (credential.expiresAt === null ||
          credential.expiresAt.getTime() > now.getTime()),
    );
  }

  async revokeCredentials(deviceId: string, reason: string, now: Date) {
    for (const credential of this.credentials) {
      if (credential.deviceId === deviceId && credential.revokedAt === null) {
        credential.revokedAt = now;
        credential.revocationReason = reason;
      }
    }
  }

  async rotateCredential(
    deviceId: string,
    tokenDigest: string,
    generation: number,
    now: Date,
  ) {
    const overlapEnd = new Date(now.getTime() + 60_000);

    for (const credential of this.credentials) {
      if (
        credential.deviceId === deviceId &&
        credential.revokedAt === null &&
        (credential.expiresAt === null ||
          credential.expiresAt.getTime() > overlapEnd.getTime())
      ) {
        credential.expiresAt = overlapEnd;
      }
    }

    await this.insertCredential({
      deviceId,
      tokenDigest,
      generation,
      issuedAt: now,
    });
  }

  async getPaymentEvent(provider: string, providerEventId: string) {
    return this.paymentEvents.get(`${provider}:${providerEventId}`) ?? null;
  }

  async insertPaymentEvent(input: {
    provider: string;
    providerEventId: string;
    eventType: string;
    orderId: string | null;
    customerId: string | null;
    priceId: string | null;
    processingState: string;
  }) {
    const mapKey = `${input.provider}:${input.providerEventId}`;

    if (this.paymentEvents.has(mapKey)) {
      throw Object.assign(new Error("duplicate provider event"), {
        code: "23505",
      });
    }

    const event: StoredPaymentEvent = {
      id: randomUUID(),
      provider: input.provider,
      providerEventId: input.providerEventId,
      eventType: input.eventType,
      processingState: input.processingState,
      licenseId: null,
      error: null,
      orderId: input.orderId,
    };
    this.paymentEvents.set(mapKey, event);
    return event;
  }

  async updatePaymentEvent(
    id: string,
    patch: {
      processingState: string;
      licenseId?: string | null;
      error?: string | null;
    },
  ) {
    for (const event of this.paymentEvents.values()) {
      if (event.id === id) {
        event.processingState = patch.processingState;
        event.licenseId = patch.licenseId ?? event.licenseId;
        event.error = patch.error ?? event.error;
      }
    }
  }

  async insertSecurityEvent(input: SecurityEventInput) {
    this.securityEvents.push(input);
  }
}

export function makeDeviceKey() {
  const { privateKey, publicKey } = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  });
  return {
    privateKey,
    encodedPublicKey: Buffer.from(
      publicKey.export({ format: "der", type: "spki" }),
    ).toString("base64url"),
  };
}

export async function issueChallenge(
  store: FakeStoreV2,
  purpose: string,
  binding: { licenseId?: string; deviceId?: string },
  expiresAt = new Date(Date.now() + 300_000),
) {
  const challengeId = randomUUID();
  const nonce = createChallengeNonce();
  await store.insertChallenge({
    id: challengeId,
    purpose,
    nonceDigest: nonceDigest(nonce),
    licenseId: binding.licenseId ?? null,
    deviceId: binding.deviceId ?? null,
    expiresAt,
  });
  return { challengeId, nonce };
}

export function signChallenge(
  privateKey: ReturnType<typeof makeDeviceKey>["privateKey"],
  purpose: string,
  challengeId: string,
  nonce: string,
): string {
  return sign(
    "sha256",
    Buffer.from(challengeMessage(purpose, challengeId, nonce), "utf8"),
    privateKey,
  ).toString("base64url");
}
