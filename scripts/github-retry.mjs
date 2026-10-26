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
  return /\bHTTP (?:429|5[0-9]{2})\b|\b(?:429|5[0-9]{2}) (?:Too Many Requests|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Timeout)\b|unexpected end of JSON input|Unexpected end of JSON|Pukbot workflow failed|could not find the dispatched Pukbot workflow run|GitHub rejected the Pukbot workflow dispatch|ECONNRESET|ECONNREFUSED|EAI_AGAIN|ENOTFOUND|EPIPE|socket hang up|connection reset|TLS handshake timeout|i\/o timeout/i.test(
    text,
  );
}

export function sleepSync(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
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
