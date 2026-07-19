CREATE TABLE "plans" (
  "id" text PRIMARY KEY,
  "name" text NOT NULL,
  "provider" text NOT NULL,
  "external_product_id" text,
  "external_price_id" text,
  "max_machines" integer NOT NULL CHECK ("max_machines" > 0),
  "billing_model" text NOT NULL,
  "active" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz DEFAULT now(),
  "updated_at" timestamptz DEFAULT now()
);

ALTER TABLE "licenses"
  ADD COLUMN "key_digest" text UNIQUE,
  ADD COLUMN "key_last4" text,
  ADD COLUMN "plan_id" text REFERENCES "plans"("id"),
  ADD COLUMN "custom_max_machines" integer,
  ADD COLUMN "pending_max_machines" integer,
  ADD COLUMN "pending_effective_at" timestamptz,
  ADD COLUMN "status" text NOT NULL DEFAULT 'active',
  ADD COLUMN "status_reason" text,
  ADD COLUMN "policy_version" integer NOT NULL DEFAULT 2,
  ADD COLUMN "updated_at" timestamptz DEFAULT now(),
  ADD CONSTRAINT "licenses_max_machines_positive" CHECK ("max_machines" > 0),
  ADD CONSTRAINT "licenses_custom_max_machines_positive"
    CHECK ("custom_max_machines" IS NULL OR "custom_max_machines" > 0),
  ADD CONSTRAINT "licenses_pending_max_machines_positive"
    CHECK ("pending_max_machines" IS NULL OR "pending_max_machines" > 0);

CREATE TABLE "devices" (
  "id" text PRIMARY KEY,
  "license_id" uuid NOT NULL REFERENCES "licenses"("id"),
  "public_key" text NOT NULL,
  "public_key_thumbprint" text NOT NULL,
  "hardware_uuid_digest" text,
  "device_name" text,
  "status" text NOT NULL DEFAULT 'active',
  "first_activated_at" timestamptz DEFAULT now(),
  "last_verified_at" timestamptz DEFAULT now(),
  "deactivated_at" timestamptz,
  "credential_generation" integer NOT NULL DEFAULT 0,
  "last_app_version" text
);

CREATE TABLE "payment_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "provider" text NOT NULL,
  "provider_event_id" text NOT NULL UNIQUE,
  "event_type" text NOT NULL,
  "order_id" text,
  "customer_id" text,
  "price_id" text,
  "processing_state" text NOT NULL DEFAULT 'received',
  "license_id" uuid REFERENCES "licenses"("id"),
  "error" text,
  "received_at" timestamptz DEFAULT now(),
  "processed_at" timestamptz
);

CREATE TABLE "device_credentials" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "device_id" text NOT NULL REFERENCES "devices"("id"),
  "token_digest" text NOT NULL,
  "generation" integer NOT NULL,
  "issued_at" timestamptz DEFAULT now(),
  "expires_at" timestamptz,
  "revoked_at" timestamptz,
  "revocation_reason" text
);

CREATE TABLE "activation_challenges" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "purpose" text NOT NULL,
  "nonce_digest" text NOT NULL,
  "license_id" uuid,
  "device_id" text,
  "expires_at" timestamptz NOT NULL,
  "consumed_at" timestamptz,
  "attempts" integer NOT NULL DEFAULT 0,
  "created_at" timestamptz DEFAULT now()
);

CREATE TABLE "security_events" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "event_type" text NOT NULL,
  "license_id" uuid,
  "device_id" text,
  "actor" text NOT NULL,
  "previous_status" text,
  "next_status" text,
  "detail" text,
  "created_at" timestamptz DEFAULT now()
);

INSERT INTO "plans" ("id", "name", "provider", "external_product_id", "external_price_id", "max_machines", "billing_model") VALUES
  ('individual_1', 'Individual', 'lemonsqueezy', 'product_individual_1', 'price_individual_1', 1, 'one_time'),
  ('personal_3', 'Personal', 'lemonsqueezy', 'product_personal_3', 'price_personal_3', 3, 'one_time'),
  ('power_5', 'Power', 'lemonsqueezy', 'product_power_5', 'price_power_5', 5, 'one_time');

UPDATE "licenses" SET "status" = 'revoked', "status_reason" = 'v1_migration' WHERE NOT "active";
UPDATE "licenses" SET "key_last4" = right("key", 4);
