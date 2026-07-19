import { licenseStore } from "@/lib/db";
import { apiJson } from "@/lib/http";
import {
  type DeviceFailure,
  type DeviceSessionSuccess,
  migrateMachineV2,
} from "@/lib/license";
import { keyLookupDigest } from "@/lib/license-key";
import {
  authFailureResponse,
  deviceSessionJson,
  ipGuard,
  readJsonBody,
  subjectGuard,
} from "@/lib/v2-api";
import { migrateV2BodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v2/devices/migrate";

export async function POST(request: Request): Promise<Response> {
  const guard = await ipGuard(request.headers, route);

  if (guard) {
    return guard;
  }

  const parsed = migrateV2BodySchema.safeParse(await readJsonBody(request));

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  let result: DeviceSessionSuccess | DeviceFailure;

  try {
    const keyed = await subjectGuard(
      keyLookupDigest(parsed.data.licenseKey),
      route,
    );

    if (keyed) {
      return keyed;
    }

    result = await migrateMachineV2(licenseStore, parsed.data);
  } catch {
    return apiJson({ error: "internal" }, 500);
  }

  if (!result.ok) {
    if (result.error === "invalid_credentials") {
      return authFailureResponse(request.headers, route);
    }

    return apiJson(
      {
        error: "machine_limit_reached",
        machinesUsed: result.machinesUsed,
        maxMachines: result.maxMachines,
      },
      403,
    );
  }

  try {
    return deviceSessionJson(parsed.data.deviceId, result);
  } catch {
    return apiJson({ error: "internal" }, 500);
  }
}
