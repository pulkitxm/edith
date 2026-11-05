import { execFileSync } from "node:child_process";

export const githubRetryAttempts = 6;
const maximumDelayMs = 30_000;

export class TransientGitHubError extends Error {
  constructor(message, { retryAfterMs, cause } = {}) {
    super(message, { cause });
    this.name = "TransientGitHubError";
    this.retryAfterMs = retryAfterMs;
  }
}

export function isTransientStatus(status) {
  return status === 429 || (status >= 500 && status <= 599);
}

export function retryAfterMs(value, now = Date.now()) {
  if (value === null || value === undefined || value === "") return undefined;
  const text = String(value).trim();
  if (/^[0-9]+$/.test(text)) return Number(text) * 1000;
  const date = Date.parse(text);
  if (!Number.isFinite(date)) return undefined;
  return Math.max(0, date - now);
}

export function backoffDelay(
  attempt,
  { retryAfter, random = Math.random } = {},
) {
  const base = Math.min(1000 * 2 ** (attempt - 1), maximumDelayMs);
  const jittered = base + Math.floor(random() * base * 0.25);
  const delay = Math.max(jittered, retryAfter ?? 0);
  return Math.min(delay, maximumDelayMs);
}

function failureText(error) {
  return [error?.message, error?.stderr, error?.stdout]
    .map((part) => (part === undefined || part === null ? "" : String(part)))
    .join("\n");
}

export function isTransientFailure(error) {
  if (error instanceof TransientGitHubError) return true;
  if (error instanceof SyntaxError) return true;
  const text = failureText(error);
  if (/\bHTTP 4(?!29)[0-9]{2}\b/.test(text)) return false;
  return /\bHTTP (?:429|5[0-9]{2})\b|\b(?:429|5[0-9]{2}) (?:Too Many Requests|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)\b|unexpected end of JSON input|Unexpected end of JSON|Pukbot workflow failed|could not find the dispatched Pukbot workflow run|failed to inspect the Pukbot workflow run|failed to list Pukbot workflow runs|GitHub rejected the Pukbot workflow dispatch|failed to resolve the authenticated GitHub user|ECONNRESET|ECONNREFUSED|EAI_AGAIN|ENOTFOUND|EPIPE|socket hang up|connection reset|TLS handshake timeout|dial tcp[^\n]*operation timed out|i\/o timeout/i.test(
    text,
  );
}

export function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

export const rateLimitRecoveries = 2;
const exhaustedBelow = 25;
const maximumRateLimitWaitMs = 65 * 60_000;
export const secondaryRateLimitWaitMs = 65_000;

export function isRateLimitFailure(error) {
  return /API rate limit exceeded|secondary rate limit/i.test(
    failureText(error),
  );
}

export function rateLimitWait({ execute = execFileSync, now = Date.now } = {}) {
  try {
    const [remaining, reset] = String(
      execute(
        "gh",
        [
          "api",
          "rate_limit",
          "--jq",
          '.resources.core | "\\(.remaining) \\(.reset)"',
        ],
        { encoding: "utf8", timeout: 30_000 },
      ),
    )
      .trim()
      .split(" ")
      .map(Number);
    if (!Number.isSafeInteger(remaining) || !Number.isSafeInteger(reset))
      return undefined;
    if (remaining >= exhaustedBelow) return null;
    return Math.min(
      Math.max(0, reset * 1000 - now()) + 5_000,
      maximumRateLimitWaitMs,
    );
  } catch {
    return undefined;
  }
}

function recoveryWait(error, recovery, { probe, recoveries }) {
  const probed = recovery < recoveries ? probe() : undefined;
  const wait =
    probed === null && isRateLimitFailure(error)
      ? secondaryRateLimitWaitMs
      : probed;
  if (wait === undefined || wait === null) throw error;
  console.error(
    `GitHub API rate limit exhausted; waiting ${Math.ceil(wait / 1000)}s for the reset`,
  );
  return wait;
}

export function withRateLimitRecoverySync(
  operation,
  {
    probe = rateLimitWait,
    sleep = sleepSync,
    recoveries = rateLimitRecoveries,
  } = {},
) {
  for (let recovery = 0; ; recovery++) {
    try {
      return operation();
    } catch (error) {
      sleep(recoveryWait(error, recovery, { probe, recoveries }));
    }
  }
}

export async function withRateLimitRecovery(
  operation,
  {
    probe = rateLimitWait,
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
    recoveries = rateLimitRecoveries,
  } = {},
) {
  for (let recovery = 0; ; recovery++) {
    try {
      return await operation();
    } catch (error) {
      await sleep(recoveryWait(error, recovery, { probe, recoveries }));
    }
  }
}

function nextDelay(error, attempt, { attempts, random, remaining }) {
  if (attempt >= attempts || !isTransientFailure(error)) throw error;
  const delay = backoffDelay(attempt, {
    retryAfter: error?.retryAfterMs,
    random,
  });
  if (remaining && delay >= remaining()) throw error;
  return delay;
}

export async function withGitHubRetry(
  operation,
  {
    attempts = githubRetryAttempts,
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
    random = Math.random,
    remaining,
    beforeRetry,
  } = {},
) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await operation(attempt);
    } catch (error) {
      const delay = nextDelay(error, attempt, { attempts, random, remaining });
      const settled = await beforeRetry?.(error, attempt);
      if (settled) return settled.value;
      await sleep(delay);
    }
  }
}

export function withGitHubRetrySync(
  operation,
  {
    attempts = githubRetryAttempts,
    sleep = sleepSync,
    random = Math.random,
    remaining,
    beforeRetry,
  } = {},
) {
  for (let attempt = 1; ; attempt++) {
    try {
      return operation(attempt);
    } catch (error) {
      const delay = nextDelay(error, attempt, { attempts, random, remaining });
      const settled = beforeRetry?.(error, attempt);
      if (settled) return settled.value;
      sleep(delay);
    }
  }
}

export async function readGitHubResponse(fetch_, url, init, options = {}) {
  return withGitHubRetry(async () => {
    let response;
    try {
      response = await fetch_(url, init());
    } catch (error) {
      if (/\bHTTP 4(?!29)[0-9]{2}\b/.test(failureText(error))) throw error;
      throw new TransientGitHubError(
        `GitHub request failed: ${error?.message}`,
        {
          cause: error,
        },
      );
    }
    if (isTransientStatus(response.status)) {
      await response.body?.cancel();
      throw new TransientGitHubError(
        `GitHub returned HTTP ${response.status}`,
        {
          retryAfterMs: retryAfterMs(response.headers?.get?.("retry-after")),
        },
      );
    }
    return options.read ? await options.read(response) : response;
  }, options);
}
