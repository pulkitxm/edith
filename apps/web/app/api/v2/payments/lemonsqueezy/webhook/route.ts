import { licenseStore } from "@/lib/db";
import { apiJson } from "@/lib/http";
import {
  processLemonSqueezyWebhook,
  verifyWebhookSignature,
} from "@/lib/payments";
import { checkRateLimit, getClientIp } from "@/lib/ratelimit";
import { rateLimited } from "@/lib/v2-api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const route = "/api/v2/payments/lemonsqueezy/webhook";

export async function POST(request: Request): Promise<Response> {
  const limit = await checkRateLimit(getClientIp(request.headers), route);

  if (!limit.allowed) {
    return rateLimited(limit.retryAfterSeconds);
  }

  const rawBody = await request.text();

  if (!verifyWebhookSignature(rawBody, request.headers.get("x-signature"))) {
    return apiJson({ error: "invalid_signature" }, 401);
  }

  let payload: unknown;

  try {
    payload = JSON.parse(rawBody);
  } catch {
    return apiJson({ error: "invalid_request" }, 400);
  }

  try {
    const result = await processLemonSqueezyWebhook(licenseStore, payload);
    return apiJson(result.body, result.status);
  } catch {
    return apiJson({ error: "internal" }, 500);
  }
}
