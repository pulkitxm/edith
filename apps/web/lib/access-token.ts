import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";

const payloadSchema = z
  .object({
    v: z.literal(1),
    deviceId: z.string().min(1),
    licenseId: z.string().min(1),
    scope: z.array(z.enum(["download", "appcast"])),
    iat: z.number().int(),
    exp: z.number().int(),
  })
  .strict();

export type AccessTokenPayload = z.infer<typeof payloadSchema>;

function getSecret(): string {
  const secret = process.env.LICENSE_ACCESS_TOKEN_SECRET;

  if (!secret || secret.length < 16) {
    throw new Error(
      "LICENSE_ACCESS_TOKEN_SECRET must be at least 16 characters",
    );
  }

  return secret;
}

function tokenTtlSeconds(): number {
  const raw = process.env.LICENSE_ACCESS_TOKEN_TTL_MINUTES;
  const minutes = raw ? Number.parseInt(raw, 10) : 14 * 60;

  if (!Number.isInteger(minutes) || minutes < 1) {
    throw new Error(
      "LICENSE_ACCESS_TOKEN_TTL_MINUTES must be a positive integer",
    );
  }

  return minutes * 60;
}

function signPayload(payloadSegment: string): string {
  return createHmac("sha256", getSecret())
    .update(payloadSegment, "utf8")
    .digest("base64url");
}

export function signAccessToken(input: {
  deviceId: string;
  licenseId: string;
  now?: number;
}): { token: string; expiresAt: number } {
  const now = input.now ?? Math.floor(Date.now() / 1000);
  const expiresAt = now + tokenTtlSeconds();
  const payload: AccessTokenPayload = {
    v: 1,
    deviceId: input.deviceId,
    licenseId: input.licenseId,
    scope: ["download", "appcast"],
    iat: now,
    exp: expiresAt,
  };
  const payloadSegment = Buffer.from(
    JSON.stringify(payload),
    "utf8",
  ).toString("base64url");
  return { token: `${payloadSegment}.${signPayload(payloadSegment)}`, expiresAt };
}

export function verifyAccessToken(
  token: string,
  now = Math.floor(Date.now() / 1000),
): AccessTokenPayload | null {
  const segments = token.split(".");

  if (segments.length !== 2) {
    return null;
  }

  const [payloadSegment, signatureSegment] = segments;
  const expected = Buffer.from(signPayload(payloadSegment), "utf8");
  const provided = Buffer.from(signatureSegment, "utf8");

  if (
    expected.length !== provided.length ||
    !timingSafeEqual(expected, provided)
  ) {
    return null;
  }

  let parsedJson: unknown;

  try {
    parsedJson = JSON.parse(
      Buffer.from(payloadSegment, "base64url").toString("utf8"),
    );
  } catch {
    return null;
  }

  const parsed = payloadSchema.safeParse(parsedJson);

  if (!parsed.success || parsed.data.exp <= now) {
    return null;
  }

  return parsed.data;
}
