import { z } from "zod";

const WINDOW_MS = 60_000;
const MAX_REQUESTS = 20;
const MAX_KEYED_REQUESTS = 30;
const FAILURE_WINDOW_MS = 600_000;
const MAX_FAILURES = 5;
const MAX_BACKOFF_SECONDS = 3_600;
const forwardedIpSchema = z.string().trim().min(1).max(200);

export type RateLimitResult = {
  allowed: boolean;
  retryAfterSeconds: number;
};

type WindowCounter = {
  count: number;
  windowEndsAt: number;
};

const memoryCounters = new Map<string, WindowCounter>();

export function getClientIp(headers: Headers): string {
  const forwarded = headers.get("x-forwarded-for")?.split(",")[0];
  const realIp = headers.get("x-real-ip");
  const parsed = forwardedIpSchema.safeParse(forwarded ?? realIp ?? "unknown");
  return parsed.success ? parsed.data : "unknown";
}

function upstashConfig(): { url: string; token: string } | null {
  const url = process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? { url, token } : null;
}

async function runUpstashPipeline(
  config: { url: string; token: string },
  commands: string[][],
): Promise<{ result: unknown }[]> {
  const response = await fetch(`${config.url}/pipeline`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${config.token}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(commands),
  });

  if (!response.ok) {
    throw new Error("Rate limit backend request failed");
  }

  return (await response.json()) as { result: unknown }[];
}

function windowBounds(windowMs: number, now: number) {
  const windowIndex = Math.floor(now / windowMs);
  return { windowIndex, windowEndsAt: (windowIndex + 1) * windowMs };
}

function pruneMemoryCounters(now: number): void {
  if (memoryCounters.size < 10_000) {
    return;
  }

  for (const [key, counter] of memoryCounters) {
    if (counter.windowEndsAt <= now) {
      memoryCounters.delete(key);
    }
  }
}

async function incrementCounter(
  bucket: string,
  windowMs: number,
  now: number,
): Promise<WindowCounter> {
  const { windowIndex, windowEndsAt } = windowBounds(windowMs, now);
  const key = `ratelimit:${bucket}:${windowIndex}`;
  const config = upstashConfig();

  if (config) {
    const results = await runUpstashPipeline(config, [
      ["INCR", key],
      ["EXPIRE", key, String(Math.ceil(windowMs / 1_000))],
    ]);
    return { count: Number(results[0]?.result ?? 0), windowEndsAt };
  }

  pruneMemoryCounters(now);
  const existing = memoryCounters.get(key);
  const count = existing && existing.windowEndsAt === windowEndsAt
    ? existing.count + 1
    : 1;
  memoryCounters.set(key, { count, windowEndsAt });
  return { count, windowEndsAt };
}

async function readCounter(
  bucket: string,
  windowMs: number,
  now: number,
): Promise<WindowCounter> {
  const { windowIndex, windowEndsAt } = windowBounds(windowMs, now);
  const key = `ratelimit:${bucket}:${windowIndex}`;
  const config = upstashConfig();

  if (config) {
    const results = await runUpstashPipeline(config, [["GET", key]]);
    return { count: Number(results[0]?.result ?? 0), windowEndsAt };
  }

  const existing = memoryCounters.get(key);
  return {
    count: existing && existing.windowEndsAt === windowEndsAt
      ? existing.count
      : 0,
    windowEndsAt,
  };
}

async function checkBucket(
  bucket: string,
  maxRequests: number,
  now: number,
): Promise<RateLimitResult> {
  const { count, windowEndsAt } = await incrementCounter(
    bucket,
    WINDOW_MS,
    now,
  );

  if (count > maxRequests) {
    return {
      allowed: false,
      retryAfterSeconds: Math.max(1, Math.ceil((windowEndsAt - now) / 1_000)),
    };
  }

  return { allowed: true, retryAfterSeconds: 0 };
}

export async function checkRateLimit(
  ip: string,
  route: string,
  now = Date.now(),
): Promise<RateLimitResult> {
  return checkBucket(`ip:${ip}:${route}`, MAX_REQUESTS, now);
}

export async function checkKeyedRateLimit(
  subject: string,
  route: string,
  now = Date.now(),
): Promise<RateLimitResult> {
  return checkBucket(`subject:${subject}:${route}`, MAX_KEYED_REQUESTS, now);
}

export async function registerAuthFailure(
  subject: string,
  route: string,
  now = Date.now(),
): Promise<void> {
  await incrementCounter(`failures:${subject}:${route}`, FAILURE_WINDOW_MS, now);
}

export async function checkAuthFailures(
  subject: string,
  route: string,
  now = Date.now(),
): Promise<RateLimitResult> {
  const { count } = await readCounter(
    `failures:${subject}:${route}`,
    FAILURE_WINDOW_MS,
    now,
  );

  if (count < MAX_FAILURES) {
    return { allowed: true, retryAfterSeconds: 0 };
  }

  return {
    allowed: false,
    retryAfterSeconds: Math.min(
      MAX_BACKOFF_SECONDS,
      60 * 2 ** (count - MAX_FAILURES),
    ),
  };
}
