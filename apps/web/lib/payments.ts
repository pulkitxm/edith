import { createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import {
  displaySuffix,
  generateLicenseKey,
  keyLookupDigest,
} from "@/lib/license-key";
import type {
  LicenseAccessV2,
  LicenseStoreV2,
  PaymentEventRecord,
} from "@/lib/license";
import { readCeilings, validatePlanAllowance } from "@/lib/plans";

const PROVIDER = "lemonsqueezy";

export function verifyWebhookSignature(
  rawBody: string,
  signature: string | null,
): boolean {
  const secret = process.env.PAYMENT_WEBHOOK_SECRET;

  if (!secret || !signature || !/^[0-9a-f]{64}$/i.test(signature)) {
    return false;
  }

  const expected = createHmac("sha256", secret)
    .update(rawBody, "utf8")
    .digest();
  const provided = Buffer.from(signature, "hex");
  return (
    expected.length === provided.length && timingSafeEqual(expected, provided)
  );
}

const externalIdSchema = z
  .union([z.string().min(1).max(255), z.number().int()])
  .transform(String);

export const webhookEnvelopeSchema = z
  .object({
    meta: z.object({ event_name: z.string().min(1).max(100) }).passthrough(),
    data: z
      .object({
        id: externalIdSchema,
        attributes: z
          .object({
            customer_id: externalIdSchema.optional(),
            first_order_item: z
              .object({ variant_id: externalIdSchema })
              .passthrough()
              .optional(),
          })
          .passthrough(),
      })
      .passthrough(),
  })
  .passthrough();

export type WebhookResult = {
  status: number;
  body: Record<string, unknown>;
};

function replayResult(event: PaymentEventRecord): WebhookResult {
  if (event.processingState === "failed") {
    return {
      status: 422,
      body: { error: event.error ?? "failed", replayed: true },
    };
  }

  return {
    status: 200,
    body: { ok: true, licenseId: event.licenseId, replayed: true },
  };
}

function isUniqueViolation(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code: unknown }).code === "23505"
  );
}

type ParsedEnvelope = z.infer<typeof webhookEnvelopeSchema>;

async function handleEvent(
  access: LicenseAccessV2,
  providerEventId: string,
  envelope: ParsedEnvelope,
): Promise<WebhookResult> {
  const eventName = envelope.meta.event_name;
  const attributes = envelope.data.attributes;
  const priceId = attributes.first_order_item?.variant_id ?? null;
  const now = new Date();
  const event = await access.insertPaymentEvent({
    provider: PROVIDER,
    providerEventId,
    eventType: eventName,
    orderId: envelope.data.id,
    customerId: attributes.customer_id ?? null,
    priceId,
    processingState: "received",
  });

  if (eventName === "order_created") {
    const plan = priceId
      ? await access.getPlanByPriceId(PROVIDER, priceId)
      : null;

    if (!plan) {
      await access.updatePaymentEvent(event.id, {
        processingState: "failed",
        error: "unknown_price",
        processedAt: now,
      });
      return { status: 422, body: { error: "unknown_price" } };
    }

    validatePlanAllowance(plan.id, plan.maxMachines, readCeilings());
    const key = generateLicenseKey();
    const { id: licenseId } = await access.insertLicense({
      key,
      keyDigest: keyLookupDigest(key),
      keyLast4: displaySuffix(key),
      label: null,
      planId: plan.id,
      maxMachines: plan.maxMachines,
    });
    await access.updatePaymentEvent(event.id, {
      processingState: "processed",
      licenseId,
      processedAt: now,
    });
    await access.insertSecurityEvent({
      eventType: "license_created",
      licenseId,
      actor: "webhook",
      nextStatus: "active",
      detail: eventName,
    });
    return {
      status: 200,
      body: {
        ok: true,
        licenseId,
        licenseKey: key,
        planId: plan.id,
        maxMachines: plan.maxMachines,
      },
    };
  }

  if (eventName === "order_refunded" || eventName === "order_chargeback") {
    const nextStatus =
      eventName === "order_refunded" ? "refunded" : "chargeback";
    const licenseId = await access.getLicenseIdByOrderId(
      PROVIDER,
      envelope.data.id,
    );

    if (!licenseId) {
      await access.updatePaymentEvent(event.id, {
        processingState: "failed",
        error: "license_not_found",
        processedAt: now,
      });
      return { status: 422, body: { error: "license_not_found" } };
    }

    const license = await access.getLicenseById(licenseId);
    await access.updateLicenseStatus(licenseId, nextStatus, eventName);
    await access.insertSecurityEvent({
      eventType: "license_status_changed",
      licenseId,
      actor: "webhook",
      previousStatus: license?.status ?? null,
      nextStatus,
      detail: eventName,
    });
    await access.updatePaymentEvent(event.id, {
      processingState: "processed",
      licenseId,
      processedAt: now,
    });
    return { status: 200, body: { ok: true, licenseId } };
  }

  await access.updatePaymentEvent(event.id, {
    processingState: "ignored",
    processedAt: now,
  });
  return { status: 200, body: { ok: true, ignored: true } };
}

export async function processLemonSqueezyWebhook(
  store: LicenseStoreV2,
  payload: unknown,
): Promise<WebhookResult> {
  const parsed = webhookEnvelopeSchema.safeParse(payload);

  if (!parsed.success) {
    return { status: 400, body: { error: "invalid_request" } };
  }

  const providerEventId = `${parsed.data.meta.event_name}:${parsed.data.data.id}`;
  const existing = await store.getPaymentEvent(PROVIDER, providerEventId);

  if (existing) {
    return replayResult(existing);
  }

  try {
    return await store.runExclusive(providerEventId, (access) =>
      handleEvent(access, providerEventId, parsed.data),
    );
  } catch (error) {
    if (isUniqueViolation(error)) {
      const replay = await store.getPaymentEvent(PROVIDER, providerEventId);

      if (replay) {
        return replayResult(replay);
      }
    }

    throw error;
  }
}
