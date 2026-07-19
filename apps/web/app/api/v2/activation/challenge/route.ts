import { randomUUID } from "node:crypto";
import { licenseStore } from "@/lib/db";
import {
  createChallengeNonce,
  nonceDigest,
  validateDevicePublicKey,
} from "@/lib/device-auth";
import { apiJson } from "@/lib/http";
import { keyLookupDigest } from "@/lib/license-key";
import {
  authFailureResponse,
  ipGuard,
  readJsonBody,
  subjectGuard,
} from "@/lib/v2-api";
import { activationChallengeBodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v2/activation/challenge";

export async function POST(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  const parsed = activationChallengeBodySchema.safeParse(
    await readJsonBody(request),
  );

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  try {
    const keyed = await subjectGuard(
      keyLookupDigest(parsed.data.licenseKey),
      route,
    );

    if (keyed) {
      return keyed;
    }

    if (!validateDevicePublicKey(parsed.data.devicePublicKey)) {
      return authFailureResponse(request.headers, route);
    }

    const challengeId = randomUUID();
    const nonce = createChallengeNonce();
    const expiresAt = new Date(Date.now() + 300_000);
    await licenseStore.insertChallenge({
      id: challengeId,
      purpose: parsed.data.purpose ?? "activate",
      nonceDigest: nonceDigest(nonce),
      licenseId: null,
      deviceId: parsed.data.deviceId,
      expiresAt,
    });
    return apiJson({
      challengeId,
      nonce,
      expiresAt: expiresAt.toISOString(),
    });
  } catch {
    return apiJson({ error: "internal" }, 500);
  }
}
