import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const githubRetryAttempts = 6;
export const rateLimitRetries = 3;
const maximumDelayMs = 30_000;
const maximumSecondaryWaitMs = 5 * 60_000;
const maximumRateLimitWaitMs = 65 * 60_000;
export const secondaryRateLimitWaitMs = 65_000;
export const rateLimitRecoveries = 2;
const exhaustedBelow = 25;

export class TransientGitHubError extends Error {
  constructor(message, { retryAfterMs, rateLimited, cause } = {}) {
    super(message, { cause });
    this.name = "TransientGitHubError";
    this.retryAfterMs = retryAfterMs;
    this.rateLimited =
      rateLimited ?? (cause !== undefined && isRateLimitFailure(cause));
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

export function rateLimitResetMs(headers, now = Date.now()) {
  const header = (name) => headers?.get?.(name) ?? null;
  const retryAfter = retryAfterMs(header("retry-after"), now);
  if (retryAfter !== undefined) return retryAfter;
  if (header("x-ratelimit-remaining") !== "0") return undefined;
  const reset = Number(header("x-ratelimit-reset"));
  if (!Number.isSafeInteger(reset) || reset < 1) return undefined;
  return Math.max(0, reset * 1000 - now) + 1_000;
}

export function isRateLimitedResponse(status, headers, body = "") {
  if (status === 429) return true;
  if (status !== 403) return false;
  return (
    headers?.get?.("retry-after") != null ||
    headers?.get?.("x-ratelimit-remaining") === "0" ||
    /rate limit/i.test(body)
  );
}

export function backoffDelay(
  attempt,
  { retryAfter, random = Math.random } = {},
) {
  const base = Math.min(1000 * 2 ** (attempt - 1), maximumDelayMs);
  const jittered = Math.min(
    base + Math.floor(random() * base * 0.25),
    maximumDelayMs,
  );
  return Math.min(Math.max(jittered, retryAfter ?? 0), maximumRateLimitWaitMs);
}

export function secondaryRateLimitDelay(hit, { random = Math.random } = {}) {
  return (
    Math.min(
      secondaryRateLimitWaitMs * 2 ** (hit - 1),
      maximumSecondaryWaitMs,
    ) + Math.floor(random() * 5_000)
  );
}

function failureText(error) {
  return [error?.message, error?.stderr, error?.stdout]
    .map((part) => (part === undefined || part === null ? "" : String(part)))
    .join("\n");
}

export function isRateLimitFailure(error) {
  if (error instanceof TransientGitHubError) return error.rateLimited;
  return /API rate limit exceeded|secondary rate limit|abuse detection mechanism|\bHTTP 429\b|\b429 Too Many Requests\b/i.test(
    failureText(error),
  );
}

export function isTransientFailure(error) {
  if (error instanceof TransientGitHubError) return true;
  if (error instanceof SyntaxError) return true;
  if (isRateLimitFailure(error)) return true;
  const text = failureText(error);
  if (/\bHTTP 4[0-9]{2}\b/.test(text)) return false;
  return /\bHTTP 5[0-9]{2}\b|\b5[0-9]{2} (?:Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)\b|unexpected end of JSON input|Unexpected end of JSON|Pukbot workflow failed|could not find the dispatched Pukbot workflow run|failed to inspect the Pukbot workflow run|failed to list Pukbot workflow runs|GitHub rejected the Pukbot workflow dispatch|failed to resolve the authenticated GitHub user|ECONNRESET|ECONNREFUSED|EAI_AGAIN|ENOTFOUND|EPIPE|socket hang up|connection reset|TLS handshake timeout|dial tcp[^\n]*operation timed out|i\/o timeout/i.test(
    text,
  );
}

export function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
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

export function retryWithProbe(execute, retry = {}) {
  return { probe: () => rateLimitWait({ execute }), ...retry };
}

function recoveryWait(error, recovery, { probe, recoveries }) {
  if (recovery >= recoveries) throw error;
  if (isRateLimitFailure(error) && error?.retryAfterMs !== undefined)
    return Math.min(error.retryAfterMs, maximumRateLimitWaitMs);
  const probed = probe();
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

function rateLimitDelay(error, hit, { probe, random }) {
  if (error?.retryAfterMs !== undefined)
    return Math.min(error.retryAfterMs, maximumRateLimitWaitMs);
  const probed = probe();
  if (typeof probed === "number") return probed;
  return secondaryRateLimitDelay(hit, { random });
}

function nextDelay(error, attempt, state, options) {
  const { attempts, random, remaining, probe } = options;
  if (attempt >= attempts) throw error;
  const rateLimited = isRateLimitFailure(error);
  let delay;
  if (rateLimited) {
    state.rateLimited += 1;
    if (state.rateLimited > rateLimitRetries) throw error;
    delay = rateLimitDelay(error, state.rateLimited, { probe, random });
  } else {
    if (!isTransientFailure(error)) throw error;
    delay = backoffDelay(attempt, { retryAfter: error?.retryAfterMs, random });
  }
  if (remaining && delay >= remaining()) throw error;
  if (rateLimited)
    console.error(
      `GitHub API rate limited; waiting ${Math.ceil(delay / 1000)}s before retrying`,
    );
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
    probe = rateLimitWait,
  } = {},
) {
  const state = { rateLimited: 0 };
  for (let attempt = 1; ; attempt++) {
    try {
      return await operation(attempt);
    } catch (error) {
      const delay = nextDelay(error, attempt, state, {
        attempts,
        random,
        remaining,
        probe,
      });
      await sleep(delay);
      const settled = await beforeRetry?.(error, attempt);
      if (settled) return settled.value;
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
    probe = rateLimitWait,
  } = {},
) {
  const state = { rateLimited: 0 };
  for (let attempt = 1; ; attempt++) {
    try {
      return operation(attempt);
    } catch (error) {
      const delay = nextDelay(error, attempt, state, {
        attempts,
        random,
        remaining,
        probe,
      });
      sleep(delay);
      const settled = beforeRetry?.(error, attempt);
      if (settled) return settled.value;
    }
  }
}

export async function readGitHubResponse(fetch_, url, init, options = {}) {
  return withGitHubRetry(async () => {
    let response;
    try {
      response = await fetch_(url, init());
    } catch (error) {
      if (
        isRateLimitFailure(error) ||
        /\bHTTP 4[0-9]{2}\b/.test(failureText(error))
      )
        throw error;
      throw new TransientGitHubError(
        `GitHub request failed: ${error?.message}`,
        { cause: error },
      );
    }
    if (response.status === 403 || isTransientStatus(response.status)) {
      const body = response.status === 403 ? await response.text() : "";
      if (response.status !== 403) await response.body?.cancel();
      const rateLimited = isRateLimitedResponse(
        response.status,
        response.headers,
        body,
      );
      if (response.status !== 403 || rateLimited)
        throw new TransientGitHubError(
          `GitHub returned HTTP ${response.status}${rateLimited ? ": API rate limit exceeded" : ""}`,
          {
            retryAfterMs: rateLimited
              ? rateLimitResetMs(response.headers)
              : retryAfterMs(response.headers?.get?.("retry-after")),
            rateLimited,
          },
        );
      response = new Response(body, {
        status: 403,
        headers: response.headers,
      });
    }
    return options.read ? await options.read(response) : response;
  }, options);
}

const publicReadPath =
  /^(?:https:\/\/api\.github\.com\/)?repos\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/(?:git\/ref\/(?:heads|tags)\/[A-Za-z0-9_.%/-]+|git\/tags\/[a-f0-9]{40}|commits\/[a-f0-9]{40})$/;

export function isPublicRead(command, args) {
  return (
    command === "gh" &&
    args.length === 2 &&
    args[0] === "api" &&
    publicReadPath.test(args[1])
  );
}

export function publicReadExecute(
  execute = execFileSync,
  environment = process.env,
) {
  const token = environment.GITHUB_TOKEN;
  if (!token) return execute;
  return (command, args, options = {}) =>
    isPublicRead(command, args)
      ? execute(command, args, {
          ...options,
          env: { ...environment, ...options.env, GH_TOKEN: token },
        })
      : execute(command, args, options);
}

export function retryDelaySeconds({
  attempt,
  transientSeconds,
  rateLimitSeconds,
  failure,
}) {
  if (
    !Number.isSafeInteger(attempt) ||
    attempt < 1 ||
    !Number.isSafeInteger(transientSeconds) ||
    transientSeconds < 0 ||
    !Number.isSafeInteger(rateLimitSeconds) ||
    rateLimitSeconds < 0
  )
    throw new Error("Invalid retry delay request");
  if (!isRateLimitFailure({ message: failure }))
    return attempt * transientSeconds;
  return Math.min(
    rateLimitSeconds * 2 ** (attempt - 1),
    maximumSecondaryWaitMs / 1000,
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const [mode, attempt, transientSeconds, rateLimitSeconds, ...files] =
    process.argv.slice(2);
  if (mode !== "delay" || rateLimitSeconds === undefined) {
    process.stderr.write(
      "usage: github-retry.mjs delay <attempt> <transient-seconds> <rate-limit-seconds> [failure-file...]\n",
    );
    process.exit(2);
  }
  const failure = files
    .map((file) => {
      try {
        return readFileSync(file, "utf8");
      } catch {
        return "";
      }
    })
    .join("\n");
  process.stdout.write(
    `${retryDelaySeconds({
      attempt: Number(attempt),
      transientSeconds: Number(transientSeconds),
      rateLimitSeconds: Number(rateLimitSeconds),
      failure,
    })}\n`,
  );
}
