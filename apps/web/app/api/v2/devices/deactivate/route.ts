import { licenseStore } from "@/lib/db";
import { apiJson } from "@/lib/http";
import { deactivateDeviceV2, type DeviceFailure } from "@/lib/license";
import {
  authFailureResponse,
  ipGuard,
  readJsonBody,
  subjectGuard,
} from "@/lib/v2-api";
import { deactivateV2BodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v2/devices/deactivate";

export async function POST(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  const parsed = deactivateV2BodySchema.safeParse(await readJsonBody(request));

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  let result: { ok: true } | DeviceFailure;

  try {
    const keyed = await subjectGuard(parsed.data.deviceId, route);

    if (keyed) {
      return keyed;
    }

    result = await deactivateDeviceV2(licenseStore, parsed.data);
  } catch {
    return apiJson({ error: "internal" }, 500);
  }

  if (!result.ok) {
    return authFailureResponse(request.headers, route);
  }

  return apiJson({ ok: true });
}
