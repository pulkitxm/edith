import {
  boolean,
  integer,
  pgTable,
  text,
  timestamp,
  unique,
  uuid,
} from "drizzle-orm/pg-core";

export const plans = pgTable("plans", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  provider: text("provider").notNull(),
  externalProductId: text("external_product_id"),
  externalPriceId: text("external_price_id"),
  maxMachines: integer("max_machines").notNull(),
  billingModel: text("billing_model").notNull(),
  active: boolean("active").notNull().default(true),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
});

export const licenses = pgTable("licenses", {
  id: uuid("id").primaryKey().defaultRandom(),
  key: text("key").notNull().unique(),
  keyDigest: text("key_digest").unique(),
  keyLast4: text("key_last4"),
  label: text("label"),
  planId: text("plan_id").references(() => plans.id),
  maxMachines: integer("max_machines").notNull().default(1),
  customMaxMachines: integer("custom_max_machines"),
  pendingMaxMachines: integer("pending_max_machines"),
  pendingEffectiveAt: timestamp("pending_effective_at", { withTimezone: true }),
  active: boolean("active").notNull().default(true),
  status: text("status").notNull().default("active"),
  statusReason: text("status_reason"),
  policyVersion: integer("policy_version").notNull().default(2),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
});

export const machines = pgTable(
  "machines",
  {
    id: uuid("id").primaryKey(),
    licenseId: uuid("license_id")
      .notNull()
      .references(() => licenses.id),
    hardwareUuid: text("hardware_uuid").notNull(),
    hostname: text("hostname"),
    firstSeen: timestamp("first_seen", { withTimezone: true }).defaultNow(),
    lastSeen: timestamp("last_seen", { withTimezone: true }).defaultNow(),
  },
  (table) => [unique().on(table.licenseId, table.hardwareUuid)],
);

export const devices = pgTable("devices", {
  id: text("id").primaryKey(),
  licenseId: uuid("license_id")
    .notNull()
    .references(() => licenses.id),
  publicKey: text("public_key").notNull(),
  publicKeyThumbprint: text("public_key_thumbprint").notNull(),
  hardwareUuidDigest: text("hardware_uuid_digest"),
  deviceName: text("device_name"),
  status: text("status").notNull().default("active"),
  firstActivatedAt: timestamp("first_activated_at", {
    withTimezone: true,
  }).defaultNow(),
  lastVerifiedAt: timestamp("last_verified_at", {
    withTimezone: true,
  }).defaultNow(),
  deactivatedAt: timestamp("deactivated_at", { withTimezone: true }),
  credentialGeneration: integer("credential_generation").notNull().default(0),
  lastAppVersion: text("last_app_version"),
});

export const paymentEvents = pgTable("payment_events", {
  id: uuid("id").primaryKey().defaultRandom(),
  provider: text("provider").notNull(),
  providerEventId: text("provider_event_id").notNull().unique(),
  eventType: text("event_type").notNull(),
  orderId: text("order_id"),
  customerId: text("customer_id"),
  priceId: text("price_id"),
  processingState: text("processing_state").notNull().default("received"),
  licenseId: uuid("license_id").references(() => licenses.id),
  error: text("error"),
  receivedAt: timestamp("received_at", { withTimezone: true }).defaultNow(),
  processedAt: timestamp("processed_at", { withTimezone: true }),
});

export const deviceCredentials = pgTable("device_credentials", {
  id: uuid("id").primaryKey().defaultRandom(),
  deviceId: text("device_id")
    .notNull()
    .references(() => devices.id),
  tokenDigest: text("token_digest").notNull(),
  generation: integer("generation").notNull(),
  issuedAt: timestamp("issued_at", { withTimezone: true }).defaultNow(),
  expiresAt: timestamp("expires_at", { withTimezone: true }),
  revokedAt: timestamp("revoked_at", { withTimezone: true }),
  revocationReason: text("revocation_reason"),
});

export const activationChallenges = pgTable("activation_challenges", {
  id: uuid("id").primaryKey().defaultRandom(),
  purpose: text("purpose").notNull(),
  nonceDigest: text("nonce_digest").notNull(),
  licenseId: uuid("license_id"),
  deviceId: text("device_id"),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  consumedAt: timestamp("consumed_at", { withTimezone: true }),
  attempts: integer("attempts").notNull().default(0),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
});

export const securityEvents = pgTable("security_events", {
  id: uuid("id").primaryKey().defaultRandom(),
  eventType: text("event_type").notNull(),
  licenseId: uuid("license_id"),
  deviceId: text("device_id"),
  actor: text("actor").notNull(),
  previousStatus: text("previous_status"),
  nextStatus: text("next_status"),
  detail: text("detail"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
});
