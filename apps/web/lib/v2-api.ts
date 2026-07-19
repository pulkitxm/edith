import { randomUUID } from "node:crypto";
import { signAccessToken, verifyAccessToken } from "@/lib/access-token";
import { licenseStore } from "@/lib/db";
import { signEntitlement } from "@/lib/entitlement";
import { apiJson } from "@/lib/http";
import { type DeviceSessionSuccess, verifyLicense } from "@/lib/license";
import { parseBearerToken, parseLicenseHeaders } from "@/lib/validation";
import {
  checkAuthFailures,
  checkKeyedRateLimit,
  checkRateLimit,
  getClientIp,
  registerAuthFailure,
} from "@/lib/ratelimit";

export function rateLimited(retryAfterSeconds: number): Response {
  return apiJson({ error: "rate_limited" }, 429, {
    "retry-after": String(retryAfterSeconds),
  });
}

export async function ipGuard(
  headers: Headers,
  route: string,
): Promise<Response | null> {
  const ip = getClientIp(headers);
  const failures = await checkAuthFailures(ip, route);

  if (!failures.allowed) {
    return rateLimited(failures.retryAfterSeconds);
  }

  const limit = await checkRateLimit(ip, route);
  return limit.allowed ? null : rateLimited(limit.retryAfterSeconds);
}

export async function subjectGuard(
  subject: string,
  route: string,
): Promise<Response | null> {
  const limit = await checkKeyedRateLimit(subject, route);
  return limit.allowed ? null : rateLimited(limit.retryAfterSeconds);
}

export async function authFailureResponse(
  headers: Headers,
  route: string,
  body: Record<string, unknown> = { error: "invalid_credentials" },
): Promise<Response> {
  await registerAuthFailure(getClientIp(headers), route);
  return apiJson(body, 403);
}

export async function readJsonBody(request: Request): Promise<unknown> {
  try {
    return await request.json();
  } catch {
    return undefined;
  }
}

export async function isDownloadAuthorized(
  headers: Headers,
  scope: "download" | "appcast",
): Promise<boolean> {
  const bearer = parseBearerToken(headers);

  if (bearer) {
    const payload = verifyAccessToken(bearer);

    if (!payload || !payload.scope.includes(scope)) {
      return false;
    }

    const device = await licenseStore.getDevice(payload.deviceId);

    if (
      device === null ||
      device.status !== "active" ||
      device.licenseId !== payload.licenseId
    ) {
      return false;
    }

    const license = await licenseStore.getLicenseById(device.licenseId);
    return license !== null && license.active && license.status === "active";
  }

  const credentials = parseLicenseHeaders(headers);

  if (!credentials.success) {
    return false;
  }

  return verifyLicense(
    licenseStore,
    credentials.data.key,
    credentials.data.hardwareUuid,
  );
}

export function deviceSessionJson(
  deviceId: string,
  result: DeviceSessionSuccess,
): Response {
  const now = Math.floor(Date.now() / 1000);
  const entitlement = signEntitlement({
    receiptId: randomUUID(),
    licenseId: result.licenseId,
    deviceId,
    deviceKeyThumbprint: result.deviceKeyThumbprint,
    planId: result.planId ?? "custom",
    maxMachines: result.maxMachines,
    now,
  });
  const accessToken = signAccessToken({
    deviceId,
    licenseId: result.licenseId,
    now,
  });
  return apiJson({
    ok: true,
    planId: result.planId ?? "custom",
    machinesUsed: result.machinesUsed,
    maxMachines: result.maxMachines,
    entitlement,
    refreshCredential: result.refreshCredential,
    accessToken: accessToken.token,
    accessTokenExpiresAt: new Date(accessToken.expiresAt * 1000).toISOString(),
  });
}
