import { licenseStore } from "@/lib/db";
import { apiJson } from "@/lib/http";
import { activateLicense, type ActivationResult } from "@/lib/license";
import { checkRateLimit, getClientIp } from "@/lib/ratelimit";
import { signReceipt } from "@/lib/receipt";
import { activationBodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const rateLimit = await checkRateLimit(
    getClientIp(request.headers),
    "/api/v1/activate",
  );

  if (!rateLimit.allowed) {
    return apiJson({ error: "rate_limited" }, 429, {
      "retry-after": String(rateLimit.retryAfterSeconds),
    });
  }

  let body: unknown;

  try {
    body = await request.json();
  } catch {
    return apiJson({ error: "invalid_request" }, 400);
  }

  const parsed = activationBodySchema.safeParse(body);

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  let result: ActivationResult;

  try {
    result = await activateLicense(licenseStore, parsed.data);
  } catch {
    return apiJson({ error: "internal" }, 500);
  }

  if (!result.ok) {
    return apiJson({ error: result.error }, 403);
  }

  try {
    const receipt = signReceipt({
      machine: parsed.data.hardwareUuid,
      label: result.label ?? "",
      keyLast4: parsed.data.key.slice(-4),
      now: Math.floor(Date.now() / 1000),
    });
    return apiJson({ ...result, receipt });
  } catch {
    return apiJson({ error: "internal" }, 500);
  }
}
