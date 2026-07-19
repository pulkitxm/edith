import { randomUUID } from "node:crypto";
import { and, countDistinct, eq, gt, isNull, or, sql } from "drizzle-orm";
import { drizzle, type PostgresJsDatabase } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import type { LicenseAccessV2, LicenseStoreV2 } from "@/lib/license";
import * as schema from "@/lib/schema";
import {
  activationChallenges,
  deviceCredentials,
  devices,
  licenses,
  machines,
  paymentEvents,
  plans,
  securityEvents,
} from "@/lib/schema";

type Database = PostgresJsDatabase<typeof schema>;
type PostgresClient = ReturnType<typeof postgres>;
type DatabaseState = {
  client: PostgresClient;
  database: Database;
};

let databaseState: DatabaseState | undefined;

function getDatabaseState(): DatabaseState {
  if (databaseState) {
    return databaseState;
  }

  const databaseUrl = process.env.DATABASE_URL;

  if (!databaseUrl) {
    throw new Error("DATABASE_URL is required");
  }

  const url = new URL(databaseUrl);
  url.searchParams.delete("channel_binding");
  const client = postgres(url.toString(), { prepare: false });
  const database = drizzle(client, { schema });
  databaseState = { client, database };
  return databaseState;
}

export function getDb(): Database {
  return getDatabaseState().database;
}

export async function closeDatabase(): Promise<void> {
  if (!databaseState) {
    return;
  }

  await databaseState.client.end({ timeout: 5 });
  databaseState = undefined;
}

const licenseV2Columns = {
  id: licenses.id,
  label: licenses.label,
  planId: licenses.planId,
  status: licenses.status,
  active: licenses.active,
  maxMachines: licenses.maxMachines,
  customMaxMachines: licenses.customMaxMachines,
  keyLast4: licenses.keyLast4,
};

const deviceColumns = {
  id: devices.id,
  licenseId: devices.licenseId,
  publicKey: devices.publicKey,
  publicKeyThumbprint: devices.publicKeyThumbprint,
  status: devices.status,
  credentialGeneration: devices.credentialGeneration,
};

const paymentEventColumns = {
  id: paymentEvents.id,
  provider: paymentEvents.provider,
  providerEventId: paymentEvents.providerEventId,
  eventType: paymentEvents.eventType,
  processingState: paymentEvents.processingState,
  licenseId: paymentEvents.licenseId,
  error: paymentEvents.error,
};

function createAccess(database: Database): LicenseAccessV2 {
  return {
    async getLicenseByKey(key) {
      const [license] = await database
        .select({
          id: licenses.id,
          label: licenses.label,
          maxMachines: licenses.maxMachines,
          active: licenses.active,
          status: licenses.status,
        })
        .from(licenses)
        .where(eq(licenses.key, key))
        .limit(1);

      return license ?? null;
    },
    async getLicenseByKeyDigest(digest, key) {
      const [license] = await database
        .select(licenseV2Columns)
        .from(licenses)
        .where(or(eq(licenses.keyDigest, digest), eq(licenses.key, key)))
        .limit(1);

      return license ?? null;
    },
    async getLicenseById(licenseId) {
      const [license] = await database
        .select(licenseV2Columns)
        .from(licenses)
        .where(eq(licenses.id, licenseId))
        .limit(1);

      return license ?? null;
    },
    async updateLicenseStatus(licenseId, status, reason) {
      await database
        .update(licenses)
        .set({
          status,
          statusReason: reason,
          active: status === "active",
          updatedAt: new Date(),
        })
        .where(eq(licenses.id, licenseId));
    },
    async getMachine(licenseId, hardwareUuid) {
      const [machine] = await database
        .select({
          licenseId: machines.licenseId,
          hardwareUuid: machines.hardwareUuid,
        })
        .from(machines)
        .where(
          sql`${machines.licenseId} = ${licenseId} and ${machines.hardwareUuid} = ${hardwareUuid}`,
        )
        .limit(1);

      return machine ?? null;
    },
    async countMachines(licenseId) {
      const [result] = await database
        .select({ value: countDistinct(machines.hardwareUuid) })
        .from(machines)
        .where(eq(machines.licenseId, licenseId));

      return result?.value ?? 0;
    },
    async upsertMachine(input) {
      const now = new Date();

      await database
        .insert(machines)
        .values({
          id: randomUUID(),
          licenseId: input.licenseId,
          hardwareUuid: input.hardwareUuid,
          hostname: input.hostname,
          lastSeen: now,
        })
        .onConflictDoUpdate({
          target: [machines.licenseId, machines.hardwareUuid],
          set: {
            hostname: input.hostname,
            lastSeen: now,
          },
        });
    },
    async deleteMachine(licenseId, hardwareUuid) {
      await database
        .delete(machines)
        .where(
          and(
            eq(machines.licenseId, licenseId),
            eq(machines.hardwareUuid, hardwareUuid),
          ),
        );
    },
    async getDevice(deviceId) {
      const [device] = await database
        .select(deviceColumns)
        .from(devices)
        .where(eq(devices.id, deviceId))
        .limit(1);

      return device ?? null;
    },
    async insertDevice(input) {
      await database.insert(devices).values({
        id: input.id,
        licenseId: input.licenseId,
        publicKey: input.publicKey,
        publicKeyThumbprint: input.publicKeyThumbprint,
        hardwareUuidDigest: input.hardwareUuidDigest,
        deviceName: input.deviceName,
        lastAppVersion: input.appVersion,
      });
    },
    async updateDeviceStatus(deviceId, status, now) {
      await database
        .update(devices)
        .set({
          status,
          deactivatedAt: status === "active" ? null : now,
        })
        .where(eq(devices.id, deviceId));
    },
    async touchDeviceVerification(deviceId, appVersion, now) {
      await database
        .update(devices)
        .set({
          lastVerifiedAt: now,
          lastAppVersion: appVersion,
        })
        .where(eq(devices.id, deviceId));
    },
    async countActiveSeats(licenseId) {
      const [deviceCount] = await database
        .select({ value: countDistinct(devices.id) })
        .from(devices)
        .where(
          and(eq(devices.licenseId, licenseId), eq(devices.status, "active")),
        );
      const [machineCount] = await database
        .select({ value: countDistinct(machines.hardwareUuid) })
        .from(machines)
        .where(eq(machines.licenseId, licenseId));

      return (deviceCount?.value ?? 0) + (machineCount?.value ?? 0);
    },
    async insertChallenge(input) {
      await database.insert(activationChallenges).values({
        id: input.id,
        purpose: input.purpose,
        nonceDigest: input.nonceDigest,
        licenseId: input.licenseId,
        deviceId: input.deviceId,
        expiresAt: input.expiresAt,
      });
    },
    async consumeChallenge(challengeId, now) {
      const [challenge] = await database
        .update(activationChallenges)
        .set({ consumedAt: now })
        .where(
          and(
            eq(activationChallenges.id, challengeId),
            isNull(activationChallenges.consumedAt),
          ),
        )
        .returning({
          id: activationChallenges.id,
          purpose: activationChallenges.purpose,
          nonceDigest: activationChallenges.nonceDigest,
          licenseId: activationChallenges.licenseId,
          deviceId: activationChallenges.deviceId,
          expiresAt: activationChallenges.expiresAt,
        });

      return challenge ?? null;
    },
    async insertCredential(input) {
      await database.insert(deviceCredentials).values({
        id: randomUUID(),
        deviceId: input.deviceId,
        tokenDigest: input.tokenDigest,
        generation: input.generation,
        issuedAt: input.issuedAt,
      });
      await database
        .update(devices)
        .set({ credentialGeneration: input.generation })
        .where(eq(devices.id, input.deviceId));
    },
    async getActiveCredentials(deviceId, now) {
      return database
        .select({
          id: deviceCredentials.id,
          deviceId: deviceCredentials.deviceId,
          tokenDigest: deviceCredentials.tokenDigest,
          generation: deviceCredentials.generation,
          expiresAt: deviceCredentials.expiresAt,
          revokedAt: deviceCredentials.revokedAt,
        })
        .from(deviceCredentials)
        .where(
          and(
            eq(deviceCredentials.deviceId, deviceId),
            isNull(deviceCredentials.revokedAt),
            or(
              isNull(deviceCredentials.expiresAt),
              gt(deviceCredentials.expiresAt, now),
            ),
          ),
        );
    },
    async revokeCredentials(deviceId, reason, now) {
      await database
        .update(deviceCredentials)
        .set({ revokedAt: now, revocationReason: reason })
        .where(
          and(
            eq(deviceCredentials.deviceId, deviceId),
            isNull(deviceCredentials.revokedAt),
          ),
        );
    },
    async rotateCredential(deviceId, tokenDigest, generation, now) {
      const overlapEnd = new Date(now.getTime() + 60_000);
      await database
        .update(deviceCredentials)
        .set({ expiresAt: overlapEnd })
        .where(
          and(
            eq(deviceCredentials.deviceId, deviceId),
            isNull(deviceCredentials.revokedAt),
            or(
              isNull(deviceCredentials.expiresAt),
              gt(deviceCredentials.expiresAt, overlapEnd),
            ),
          ),
        );
      await database.insert(deviceCredentials).values({
        id: randomUUID(),
        deviceId,
        tokenDigest,
        generation,
        issuedAt: now,
      });
      await database
        .update(devices)
        .set({ credentialGeneration: generation })
        .where(eq(devices.id, deviceId));
    },
    async insertLicense(input) {
      const [license] = await database
        .insert(licenses)
        .values({
          key: input.key,
          keyDigest: input.keyDigest,
          keyLast4: input.keyLast4,
          label: input.label,
          planId: input.planId,
          maxMachines: input.maxMachines,
        })
        .returning({ id: licenses.id });

      if (!license) {
        throw new Error("License insert returned no row");
      }

      return license;
    },
    async getPlanByPriceId(provider, priceId) {
      const [plan] = await database
        .select({ id: plans.id, maxMachines: plans.maxMachines })
        .from(plans)
        .where(
          and(
            eq(plans.provider, provider),
            eq(plans.externalPriceId, priceId),
            eq(plans.active, true),
          ),
        )
        .limit(1);

      return plan ?? null;
    },
    async getLicenseIdByOrderId(provider, orderId) {
      const [event] = await database
        .select({ licenseId: paymentEvents.licenseId })
        .from(paymentEvents)
        .where(
          and(
            eq(paymentEvents.provider, provider),
            eq(paymentEvents.orderId, orderId),
            sql`${paymentEvents.licenseId} is not null`,
          ),
        )
        .limit(1);

      return event?.licenseId ?? null;
    },
    async getPaymentEvent(provider, providerEventId) {
      const [event] = await database
        .select(paymentEventColumns)
        .from(paymentEvents)
        .where(
          and(
            eq(paymentEvents.provider, provider),
            eq(paymentEvents.providerEventId, providerEventId),
          ),
        )
        .limit(1);

      return event ?? null;
    },
    async insertPaymentEvent(input) {
      const [event] = await database
        .insert(paymentEvents)
        .values({
          provider: input.provider,
          providerEventId: input.providerEventId,
          eventType: input.eventType,
          orderId: input.orderId,
          customerId: input.customerId,
          priceId: input.priceId,
          processingState: input.processingState,
        })
        .returning(paymentEventColumns);

      if (!event) {
        throw new Error("Payment event insert returned no row");
      }

      return event;
    },
    async updatePaymentEvent(id, patch) {
      await database
        .update(paymentEvents)
        .set({
          processingState: patch.processingState,
          licenseId: patch.licenseId,
          error: patch.error,
          processedAt: patch.processedAt,
        })
        .where(eq(paymentEvents.id, id));
    },
    async insertSecurityEvent(input) {
      await database.insert(securityEvents).values({
        eventType: input.eventType,
        licenseId: input.licenseId ?? null,
        deviceId: input.deviceId ?? null,
        actor: input.actor,
        previousStatus: input.previousStatus ?? null,
        nextStatus: input.nextStatus ?? null,
        detail: input.detail ?? null,
      });
    },
  };
}

export const licenseStore: LicenseStoreV2 = {
  async getLicenseByKey(key) {
    return createAccess(getDb()).getLicenseByKey(key);
  },
  async getLicenseByKeyDigest(digest, key) {
    return createAccess(getDb()).getLicenseByKeyDigest(digest, key);
  },
  async getLicenseById(licenseId) {
    return createAccess(getDb()).getLicenseById(licenseId);
  },
  async updateLicenseStatus(licenseId, status, reason) {
    return createAccess(getDb()).updateLicenseStatus(licenseId, status, reason);
  },
  async getMachine(licenseId, hardwareUuid) {
    return createAccess(getDb()).getMachine(licenseId, hardwareUuid);
  },
  async countMachines(licenseId) {
    return createAccess(getDb()).countMachines(licenseId);
  },
  async upsertMachine(input) {
    return createAccess(getDb()).upsertMachine(input);
  },
  async deleteMachine(licenseId, hardwareUuid) {
    return createAccess(getDb()).deleteMachine(licenseId, hardwareUuid);
  },
  async getDevice(deviceId) {
    return createAccess(getDb()).getDevice(deviceId);
  },
  async insertDevice(input) {
    return createAccess(getDb()).insertDevice(input);
  },
  async updateDeviceStatus(deviceId, status, now) {
    return createAccess(getDb()).updateDeviceStatus(deviceId, status, now);
  },
  async touchDeviceVerification(deviceId, appVersion, now) {
    return createAccess(getDb()).touchDeviceVerification(
      deviceId,
      appVersion,
      now,
    );
  },
  async countActiveSeats(licenseId) {
    return createAccess(getDb()).countActiveSeats(licenseId);
  },
  async insertChallenge(input) {
    return createAccess(getDb()).insertChallenge(input);
  },
  async consumeChallenge(challengeId, now) {
    return createAccess(getDb()).consumeChallenge(challengeId, now);
  },
  async insertCredential(input) {
    return createAccess(getDb()).insertCredential(input);
  },
  async getActiveCredentials(deviceId, now) {
    return createAccess(getDb()).getActiveCredentials(deviceId, now);
  },
  async revokeCredentials(deviceId, reason, now) {
    return createAccess(getDb()).revokeCredentials(deviceId, reason, now);
  },
  async rotateCredential(deviceId, tokenDigest, generation, now) {
    return createAccess(getDb()).rotateCredential(
      deviceId,
      tokenDigest,
      generation,
      now,
    );
  },
  async insertLicense(input) {
    return createAccess(getDb()).insertLicense(input);
  },
  async getPlanByPriceId(provider, priceId) {
    return createAccess(getDb()).getPlanByPriceId(provider, priceId);
  },
  async getLicenseIdByOrderId(provider, orderId) {
    return createAccess(getDb()).getLicenseIdByOrderId(provider, orderId);
  },
  async getPaymentEvent(provider, providerEventId) {
    return createAccess(getDb()).getPaymentEvent(provider, providerEventId);
  },
  async insertPaymentEvent(input) {
    return createAccess(getDb()).insertPaymentEvent(input);
  },
  async updatePaymentEvent(id, patch) {
    return createAccess(getDb()).updatePaymentEvent(id, patch);
  },
  async insertSecurityEvent(input) {
    return createAccess(getDb()).insertSecurityEvent(input);
  },
  async runExclusive(key, operation) {
    return getDb().transaction(async (transaction) => {
      await transaction.execute(
        sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`,
      );
      const access = createAccess(transaction as Database);
      return operation(access);
    });
  },
};
