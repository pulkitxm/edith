import { z } from "zod";

export const licenseKeySchema = z
  .string()
  .regex(/^EDITH-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}$/);

export const hardwareUuidSchema = z.string().trim().min(1).max(255);

export const activationBodySchema = z
  .object({
    key: licenseKeySchema,
    hardwareUuid: hardwareUuidSchema,
    hostname: z.string().trim().min(1).max(255).optional(),
  })
  .strict();

export const verificationBodySchema = z
  .object({
    key: licenseKeySchema,
    hardwareUuid: hardwareUuidSchema,
  })
  .strict();

const base64UrlSchema = z
  .string()
  .min(1)
  .max(2048)
  .regex(/^[A-Za-z0-9_-]+$/);

export const deviceIdSchema = z.string().trim().min(1).max(255);

const challengeIdSchema = z.string().uuid();
const appVersionSchema = z.string().trim().min(1).max(64);
const deviceNameSchema = z.string().trim().min(1).max(255);

export const activationChallengeBodySchema = z
  .object({
    licenseKey: licenseKeySchema,
    deviceId: deviceIdSchema,
    devicePublicKey: base64UrlSchema,
    purpose: z.enum(["activate", "migrate"]).optional(),
  })
  .strict();

export const activationV2BodySchema = z
  .object({
    licenseKey: licenseKeySchema,
    challengeId: challengeIdSchema,
    nonce: base64UrlSchema,
    deviceId: deviceIdSchema,
    devicePublicKey: base64UrlSchema,
    signature: base64UrlSchema,
    appVersion: appVersionSchema,
    deviceName: deviceNameSchema.optional(),
  })
  .strict();

export const migrateV2BodySchema = activationV2BodySchema
  .extend({ hardwareUuid: hardwareUuidSchema })
  .strict();

export const refreshChallengeBodySchema = z
  .object({
    deviceId: deviceIdSchema,
    refreshCredential: z
      .string()
      .max(128)
      .regex(/^edithrc_[A-Za-z0-9_-]+$/),
    purpose: z.enum(["refresh", "deactivate"]).optional(),
  })
  .strict();

export const refreshV2BodySchema = z
  .object({
    deviceId: deviceIdSchema,
    challengeId: challengeIdSchema,
    nonce: base64UrlSchema,
    signature: base64UrlSchema,
    appVersion: appVersionSchema,
  })
  .strict();

export const deactivateV2BodySchema = z
  .object({
    deviceId: deviceIdSchema,
    challengeId: challengeIdSchema,
    nonce: base64UrlSchema,
    signature: base64UrlSchema,
  })
  .strict();

export function parseBearerToken(headers: Headers): string | null {
  const header = headers.get("authorization");

  if (!header) {
    return null;
  }

  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  return match ? match[1] : null;
}

const licenseHeadersSchema = z.object({
  key: licenseKeySchema,
  hardwareUuid: hardwareUuidSchema,
});

export function parseLicenseHeaders(
  headers: Headers,
): z.SafeParseReturnType<
  z.input<typeof licenseHeadersSchema>,
  z.output<typeof licenseHeadersSchema>
> {
  return licenseHeadersSchema.safeParse({
    key: headers.get("x-edith-license"),
    hardwareUuid: headers.get("x-edith-machine"),
  });
}
