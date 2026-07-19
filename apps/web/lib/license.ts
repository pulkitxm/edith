import { createHash } from "node:crypto";
import {
  challengeMessage,
  nonceDigest,
  publicKeyThumbprint,
  validateDevicePublicKey,
  verifyChallengeSignature,
} from "@/lib/device-auth";
import { keyLookupDigest, normalizeLicenseKey } from "@/lib/license-key";
import { effectiveAllowance } from "@/lib/plans";
import {
  generateRefreshCredential,
  refreshCredentialDigest,
  verifyRefreshCredential,
} from "@/lib/refresh-credential";

export type LicenseRecord = {
  id: string;
  label: string | null;
  name?: string | null;
  maxMachines: number;
  customMaxMachines: number | null;
  active: boolean;
  status?: string;
};

export type MachineRecord = {
  licenseId: string;
  hardwareUuid: string;
};

export type MachineInput = {
  licenseId: string;
  hardwareUuid: string;
  hostname: string | null;
};

export interface LicenseAccess {
  getLicenseByKey(key: string): Promise<LicenseRecord | null>;
  getMachine(
    licenseId: string,
    hardwareUuid: string,
  ): Promise<MachineRecord | null>;
  countMachines(licenseId: string): Promise<number>;
  countActiveSeats(licenseId: string): Promise<number>;
  upsertMachine(input: MachineInput): Promise<void>;
}

export interface LicenseStore extends LicenseAccess {
  runExclusive<T>(
    key: string,
    operation: (access: LicenseAccess) => Promise<T>,
  ): Promise<T>;
}

export type LicenseV2Record = {
  id: string;
  label: string | null;
  planId: string | null;
  status: string;
  active: boolean;
  maxMachines: number;
  customMaxMachines: number | null;
  keyLast4: string | null;
};

export type DeviceRecord = {
  id: string;
  licenseId: string;
  publicKey: string;
  publicKeyThumbprint: string;
  status: string;
  credentialGeneration: number;
};

export type DeviceInput = {
  id: string;
  licenseId: string;
  publicKey: string;
  publicKeyThumbprint: string;
  hardwareUuidDigest: string | null;
  deviceName: string | null;
  appVersion: string | null;
};

export type ChallengeRecord = {
  id: string;
  purpose: string;
  nonceDigest: string;
  licenseId: string | null;
  deviceId: string | null;
  expiresAt: Date;
};

export type ChallengeInput = {
  id: string;
  purpose: string;
  nonceDigest: string;
  licenseId: string | null;
  deviceId: string | null;
  expiresAt: Date;
};

export type CredentialRecord = {
  id: string;
  deviceId: string;
  tokenDigest: string;
  generation: number;
  expiresAt: Date | null;
  revokedAt: Date | null;
};

export type CredentialInput = {
  deviceId: string;
  tokenDigest: string;
  generation: number;
  issuedAt: Date;
};

export type NewLicenseInput = {
  key: string;
  keyDigest: string;
  keyLast4: string;
  label: string | null;
  planId: string;
  maxMachines: number;
};

export type PlanPriceRecord = {
  id: string;
  maxMachines: number;
};

export type PaymentEventRecord = {
  id: string;
  provider: string;
  providerEventId: string;
  eventType: string;
  processingState: string;
  licenseId: string | null;
  error: string | null;
};

export type PaymentEventInput = {
  provider: string;
  providerEventId: string;
  eventType: string;
  orderId: string | null;
  customerId: string | null;
  priceId: string | null;
  processingState: string;
};

export type PaymentEventPatch = {
  processingState: string;
  licenseId?: string | null;
  error?: string | null;
  processedAt?: Date;
};

export type SecurityEventInput = {
  eventType: string;
  licenseId?: string | null;
  deviceId?: string | null;
  actor: string;
  previousStatus?: string | null;
  nextStatus?: string | null;
  detail?: string | null;
};

export function productHardwareDigest(rawUuid: string): string {
  return createHash("sha256").update(`edith:${rawUuid}`, "utf8").digest("hex");
}

export interface LicenseAccessV2 extends LicenseAccess {
  getLicenseByKeyDigest(
    digest: string,
    key: string,
  ): Promise<LicenseV2Record | null>;
  getLicenseById(licenseId: string): Promise<LicenseV2Record | null>;
  updateLicenseStatus(
    licenseId: string,
    status: string,
    reason: string | null,
  ): Promise<void>;
  getDevice(deviceId: string): Promise<DeviceRecord | null>;
  insertDevice(input: DeviceInput): Promise<void>;
  updateDeviceStatus(
    deviceId: string,
    status: string,
    now: Date,
  ): Promise<void>;
  touchDeviceVerification(
    deviceId: string,
    appVersion: string | null,
    now: Date,
  ): Promise<void>;
  deleteMachine(licenseId: string, hardwareUuid: string): Promise<void>;
  setDeviceHardwareDigest(deviceId: string, digest: string): Promise<void>;
  listMachines(licenseId: string): Promise<MachineRecord[]>;
  reclaimSeatsByHardwareDigest(
    licenseId: string,
    hardwareUuidDigest: string,
    exceptDeviceId: string,
    now: Date,
  ): Promise<void>;
  insertChallenge(input: ChallengeInput): Promise<void>;
  consumeChallenge(
    challengeId: string,
    now: Date,
  ): Promise<ChallengeRecord | null>;
  insertCredential(input: CredentialInput): Promise<void>;
  getActiveCredentials(deviceId: string, now: Date): Promise<CredentialRecord[]>;
  revokeCredentials(deviceId: string, reason: string, now: Date): Promise<void>;
  rotateCredential(
    deviceId: string,
    tokenDigest: string,
    generation: number,
    now: Date,
  ): Promise<void>;
  insertLicense(input: NewLicenseInput): Promise<{ id: string }>;
  getPlanByPriceId(
    provider: string,
    priceId: string,
  ): Promise<PlanPriceRecord | null>;
  getLicenseIdByOrderId(
    provider: string,
    orderId: string,
  ): Promise<string | null>;
  getPaymentEvent(
    provider: string,
    providerEventId: string,
  ): Promise<PaymentEventRecord | null>;
  insertPaymentEvent(input: PaymentEventInput): Promise<PaymentEventRecord>;
  updatePaymentEvent(id: string, patch: PaymentEventPatch): Promise<void>;
  insertSecurityEvent(input: SecurityEventInput): Promise<void>;
}

export interface LicenseStoreV2 extends LicenseAccessV2 {
  runExclusive<T>(
    key: string,
    operation: (access: LicenseAccessV2) => Promise<T>,
  ): Promise<T>;
}

export type ActivationInput = {
  key: string;
  hardwareUuid: string;
  hostname?: string;
};

export type ActivationResult =
  | {
      ok: true;
      label: string | null;
      name: string | null;
      machinesUsed: number;
      maxMachines: number;
    }
  | {
      ok: false;
      error: "invalid_license" | "license_limit_reached";
    };

function isUsableLicense(
  license: LicenseRecord | null,
): license is LicenseRecord {
  return (
    license !== null &&
    license.active &&
    (license.status ?? "active") === "active"
  );
}

export async function activateLicense(
  store: LicenseStore,
  input: ActivationInput,
): Promise<ActivationResult> {
  return store.runExclusive(input.key, async (access) => {
    const license = await access.getLicenseByKey(input.key);

    if (!isUsableLicense(license)) {
      return { ok: false, error: "invalid_license" };
    }

    const existingMachine = await access.getMachine(
      license.id,
      input.hardwareUuid,
    );

    const maxMachines = effectiveAllowance(license);

    if (!existingMachine) {
      const machinesUsed = await access.countActiveSeats(license.id);

      if (machinesUsed >= maxMachines) {
        return { ok: false, error: "license_limit_reached" };
      }
    }

    await access.upsertMachine({
      licenseId: license.id,
      hardwareUuid: input.hardwareUuid,
      hostname: input.hostname ?? null,
    });

    const machinesUsed = await access.countActiveSeats(license.id);

    return {
      ok: true,
      label: license.label,
      name: license.name ?? null,
      machinesUsed,
      maxMachines,
    };
  });
}

export async function verifyLicense(
  store: LicenseAccess,
  key: string,
  hardwareUuid: string,
): Promise<boolean> {
  return (await getVerifiedLicense(store, key, hardwareUuid)) !== null;
}

export async function getVerifiedLicense(
  store: LicenseAccess,
  key: string,
  hardwareUuid: string,
): Promise<LicenseRecord | null> {
  const license = await store.getLicenseByKey(key);

  if (!isUsableLicense(license)) {
    return null;
  }

  const machine = await store.getMachine(license.id, hardwareUuid);
  return machine ? license : null;
}

export type DeviceSessionSuccess = {
  ok: true;
  licenseId: string;
  planId: string | null;
  machinesUsed: number;
  maxMachines: number;
  deviceKeyThumbprint: string;
  refreshCredential: string;
};

export type DeviceFailure =
  | { ok: false; error: "invalid_credentials" }
  | {
      ok: false;
      error: "machine_limit_reached";
      machinesUsed: number;
      maxMachines: number;
    };

export type ActivateDeviceV2Input = {
  licenseKey: string;
  challengeId: string;
  nonce: string;
  deviceId: string;
  devicePublicKey: string;
  signature: string;
  appVersion: string;
  deviceName?: string;
  hardwareUuidDigest?: string;
};

export type MigrateMachineV2Input = ActivateDeviceV2Input & {
  hardwareUuid: string;
};

export type RefreshDeviceV2Input = {
  deviceId: string;
  challengeId: string;
  nonce: string;
  signature: string;
  appVersion: string;
};

export type DeactivateDeviceV2Input = {
  deviceId: string;
  challengeId: string;
  nonce: string;
  signature: string;
};

const invalidCredentials: DeviceFailure = {
  ok: false,
  error: "invalid_credentials",
};

function isActiveV2License(
  license: LicenseV2Record | null,
): license is LicenseV2Record {
  return license !== null && license.active && license.status === "active";
}

async function consumeVerifiedChallenge(
  access: LicenseAccessV2,
  input: { challengeId: string; nonce: string; signature: string },
  purpose: string,
  publicKey: string,
  now: Date,
): Promise<ChallengeRecord | null> {
  const challenge = await access.consumeChallenge(input.challengeId, now);

  if (
    !challenge ||
    challenge.purpose !== purpose ||
    challenge.expiresAt.getTime() <= now.getTime() ||
    nonceDigest(input.nonce) !== challenge.nonceDigest
  ) {
    return null;
  }

  const message = challengeMessage(purpose, challenge.id, input.nonce);

  if (!verifyChallengeSignature(publicKey, message, input.signature)) {
    return null;
  }

  return challenge;
}

async function issueCredential(
  access: LicenseAccessV2,
  device: { id: string; credentialGeneration: number },
  now: Date,
): Promise<string> {
  const credential = generateRefreshCredential();
  const generation = device.credentialGeneration + 1;

  if (device.credentialGeneration === 0) {
    await access.insertCredential({
      deviceId: device.id,
      tokenDigest: refreshCredentialDigest(credential),
      generation,
      issuedAt: now,
    });
  } else {
    await access.rotateCredential(
      device.id,
      refreshCredentialDigest(credential),
      generation,
      now,
    );
  }

  return credential;
}

async function sessionSuccess(
  access: LicenseAccessV2,
  license: LicenseV2Record,
  thumbprint: string,
  refreshCredential: string,
): Promise<DeviceSessionSuccess> {
  return {
    ok: true,
    licenseId: license.id,
    planId: license.planId,
    machinesUsed: await access.countActiveSeats(license.id),
    maxMachines: effectiveAllowance(license),
    deviceKeyThumbprint: thumbprint,
    refreshCredential,
  };
}

export async function activateDeviceV2(
  store: LicenseStoreV2,
  input: ActivateDeviceV2Input,
  now = new Date(),
): Promise<DeviceSessionSuccess | DeviceFailure> {
  if (!validateDevicePublicKey(input.devicePublicKey)) {
    return invalidCredentials;
  }

  const key = normalizeLicenseKey(input.licenseKey);
  const digest = keyLookupDigest(key);
  return store.runExclusive(digest, async (access) => {
    const license = await access.getLicenseByKeyDigest(digest, key);

    if (!isActiveV2License(license)) {
      return invalidCredentials;
    }

    const challenge = await consumeVerifiedChallenge(
      access,
      input,
      "activate",
      input.devicePublicKey,
      now,
    );

    if (
      !challenge ||
      challenge.deviceId !== input.deviceId ||
      (challenge.licenseId ?? license.id) !== license.id
    ) {
      return invalidCredentials;
    }

    const thumbprint = publicKeyThumbprint(input.devicePublicKey);
    const existing = await access.getDevice(input.deviceId);

    if (existing) {
      if (
        existing.licenseId !== license.id ||
        existing.publicKeyThumbprint !== thumbprint
      ) {
        return invalidCredentials;
      }

      if (existing.status === "active") {
        const credential = await issueCredential(access, existing, now);
        await access.touchDeviceVerification(
          existing.id,
          input.appVersion,
          now,
        );
        return sessionSuccess(access, license, thumbprint, credential);
      }

      if (input.hardwareUuidDigest) {
        await access.reclaimSeatsByHardwareDigest(
          license.id,
          input.hardwareUuidDigest,
          input.deviceId,
          now,
        );
      }

      const machinesUsed = await access.countActiveSeats(license.id);
      const maxMachines = effectiveAllowance(license);

      if (machinesUsed >= maxMachines) {
        return {
          ok: false,
          error: "machine_limit_reached",
          machinesUsed,
          maxMachines,
        };
      }

      await access.updateDeviceStatus(existing.id, "active", now);
      if (input.hardwareUuidDigest) {
        await access.setDeviceHardwareDigest(
          existing.id,
          input.hardwareUuidDigest,
        );
      }
      const credential = await issueCredential(access, existing, now);
      await access.touchDeviceVerification(existing.id, input.appVersion, now);
      await access.insertSecurityEvent({
        eventType: "device_reactivated",
        licenseId: license.id,
        deviceId: existing.id,
        actor: "customer",
      });
      return sessionSuccess(access, license, thumbprint, credential);
    }

    if (input.hardwareUuidDigest) {
      await access.reclaimSeatsByHardwareDigest(
        license.id,
        input.hardwareUuidDigest,
        input.deviceId,
        now,
      );
    }

    const machinesUsed = await access.countActiveSeats(license.id);
    const maxMachines = effectiveAllowance(license);

    if (machinesUsed >= maxMachines) {
      return {
        ok: false,
        error: "machine_limit_reached",
        machinesUsed,
        maxMachines,
      };
    }

    await access.insertDevice({
      id: input.deviceId,
      licenseId: license.id,
      publicKey: input.devicePublicKey,
      publicKeyThumbprint: thumbprint,
      hardwareUuidDigest: input.hardwareUuidDigest ?? null,
      deviceName: input.deviceName ?? null,
      appVersion: input.appVersion,
    });
    const credential = await issueCredential(
      access,
      { id: input.deviceId, credentialGeneration: 0 },
      now,
    );
    await access.insertSecurityEvent({
      eventType: "device_activated",
      licenseId: license.id,
      deviceId: input.deviceId,
      actor: "customer",
    });
    return sessionSuccess(access, license, thumbprint, credential);
  });
}

export async function migrateMachineV2(
  store: LicenseStoreV2,
  input: MigrateMachineV2Input,
  now = new Date(),
): Promise<DeviceSessionSuccess | DeviceFailure> {
  if (!validateDevicePublicKey(input.devicePublicKey)) {
    return invalidCredentials;
  }

  const key = normalizeLicenseKey(input.licenseKey);
  const digest = keyLookupDigest(key);
  return store.runExclusive(digest, async (access) => {
    const license = await access.getLicenseByKeyDigest(digest, key);

    if (!isActiveV2License(license)) {
      return invalidCredentials;
    }

    const machine = await access.getMachine(license.id, input.hardwareUuid);

    if (!machine) {
      return invalidCredentials;
    }

    const challenge = await consumeVerifiedChallenge(
      access,
      input,
      "migrate",
      input.devicePublicKey,
      now,
    );

    if (
      !challenge ||
      challenge.deviceId !== input.deviceId ||
      (challenge.licenseId ?? license.id) !== license.id
    ) {
      return invalidCredentials;
    }

    if (await access.getDevice(input.deviceId)) {
      return invalidCredentials;
    }

    const hardwareUuidDigest = productHardwareDigest(input.hardwareUuid);
    await access.reclaimSeatsByHardwareDigest(
      license.id,
      hardwareUuidDigest,
      input.deviceId,
      now,
    );

    const thumbprint = publicKeyThumbprint(input.devicePublicKey);
    await access.insertDevice({
      id: input.deviceId,
      licenseId: license.id,
      publicKey: input.devicePublicKey,
      publicKeyThumbprint: thumbprint,
      hardwareUuidDigest,
      deviceName: input.deviceName ?? null,
      appVersion: input.appVersion,
    });
    await access.deleteMachine(license.id, input.hardwareUuid);
    const credential = await issueCredential(
      access,
      { id: input.deviceId, credentialGeneration: 0 },
      now,
    );
    await access.insertSecurityEvent({
      eventType: "machine_migrated",
      licenseId: license.id,
      deviceId: input.deviceId,
      actor: "customer",
    });
    return sessionSuccess(access, license, thumbprint, credential);
  });
}

export async function refreshDeviceV2(
  store: LicenseStoreV2,
  input: RefreshDeviceV2Input,
  now = new Date(),
): Promise<DeviceSessionSuccess | DeviceFailure> {
  return store.runExclusive(input.deviceId, async (access) => {
    const device = await access.getDevice(input.deviceId);

    if (!device || device.status !== "active") {
      return invalidCredentials;
    }

    const license = await access.getLicenseById(device.licenseId);

    if (!isActiveV2License(license)) {
      return invalidCredentials;
    }

    const challenge = await consumeVerifiedChallenge(
      access,
      input,
      "refresh",
      device.publicKey,
      now,
    );

    if (!challenge || challenge.deviceId !== device.id) {
      return invalidCredentials;
    }

    const credential = await issueCredential(access, device, now);
    await access.touchDeviceVerification(device.id, input.appVersion, now);
    return sessionSuccess(
      access,
      license,
      device.publicKeyThumbprint,
      credential,
    );
  });
}

export async function deactivateDeviceV2(
  store: LicenseStoreV2,
  input: DeactivateDeviceV2Input,
  now = new Date(),
): Promise<{ ok: true } | DeviceFailure> {
  return store.runExclusive(input.deviceId, async (access) => {
    const device = await access.getDevice(input.deviceId);

    if (!device || device.status !== "active") {
      return invalidCredentials;
    }

    const challenge = await consumeVerifiedChallenge(
      access,
      input,
      "deactivate",
      device.publicKey,
      now,
    );

    if (!challenge || challenge.deviceId !== device.id) {
      return invalidCredentials;
    }

    await access.updateDeviceStatus(device.id, "deactivated", now);
    await access.revokeCredentials(device.id, "deactivated", now);
    await access.insertSecurityEvent({
      eventType: "device_deactivated",
      licenseId: device.licenseId,
      deviceId: device.id,
      actor: "customer",
    });
    return { ok: true };
  });
}

export async function verifyDeviceRefreshCredential(
  store: LicenseAccessV2,
  deviceId: string,
  credential: string,
  now = new Date(),
): Promise<boolean> {
  if (!credential.startsWith("edithrc_")) {
    return false;
  }

  const credentials = await store.getActiveCredentials(deviceId, now);
  return credentials.some((record) =>
    verifyRefreshCredential(credential, record.tokenDigest),
  );
}
