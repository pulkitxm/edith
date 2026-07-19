import { licenseStore } from "@/lib/db";
import { apiJson } from "@/lib/http";
import { getVerifiedLicense, type LicenseRecord } from "@/lib/license";
import { checkRateLimit, getClientIp } from "@/lib/ratelimit";
import { signReceipt } from "@/lib/receipt";
import { verificationBodySchema } from "@/lib/validation";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const rateLimit = await checkRateLimit(
    getClientIp(request.headers),
    "/api/v1/verify",
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

  const parsed = verificationBodySchema.safeParse(body);

  if (!parsed.success) {
    return apiJson({ error: "invalid_request" }, 400);
  }

  let license: LicenseRecord | null;

  try {
    license = await getVerifiedLicense(
      licenseStore,
      parsed.data.key,
      parsed.data.hardwareUuid,
    );
  } catch {
    return apiJson({ error: "internal" }, 500);
  }

  if (!license) {
    return apiJson({ ok: false });
  }

  try {
    const receipt = signReceipt({
      machine: parsed.data.hardwareUuid,
      label: license.label ?? "",
      keyLast4: parsed.data.key.slice(-4),
      now: Math.floor(Date.now() / 1000),
    });
    return apiJson({ ok: true, receipt });
  } catch {
    return apiJson({ error: "internal" }, 500);
  }
}
