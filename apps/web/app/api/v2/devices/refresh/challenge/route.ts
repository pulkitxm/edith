import { randomUUID } from "node:crypto";
import { licenseStore } from "@/lib/db";
import { createChallengeNonce, nonceDigest } from "@/lib/device-auth";
import { apiJson } from "@/lib/http";
import { verifyDeviceRefreshCredential } from "@/lib/license";
import {
  authFailureResponse,
  ipGuard,
  readJsonBody,
  subjectGuard,
} from "@/lib/v2-api";
import { refreshChallengeBodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v2/devices/refresh/challenge";

export async function POST(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  const parsed = refreshChallengeBodySchema.safeParse(
    await readJsonBody(request),
  );

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  try {
    const keyed = await subjectGuard(parsed.data.deviceId, route);

    if (keyed) {
      return keyed;
    }

    const device = await licenseStore.getDevice(parsed.data.deviceId);
    const authorized =
      device !== null &&
      device.status === "active" &&
      (await verifyDeviceRefreshCredential(
        licenseStore,
        parsed.data.deviceId,
        parsed.data.refreshCredential,
      ));

    if (!authorized || !device) {
      return authFailureResponse(request.headers, route);
    }

    const challengeId = randomUUID();
    const nonce = createChallengeNonce();
    const expiresAt = new Date(Date.now() + 300_000);
    await licenseStore.insertChallenge({
      id: challengeId,
      purpose: parsed.data.purpose ?? "refresh",
      nonceDigest: nonceDigest(nonce),
      licenseId: device.licenseId,
      deviceId: device.id,
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
