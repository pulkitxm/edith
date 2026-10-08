import { createReadStream } from "node:fs";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { execFileSync } from "node:child_process";

const cloudClients = new Set([
  "CODEX_WEB",
  "CODEX_CLOUD",
  "CODEX_WORK_WEB",
  "CODEX_WORK_MOBILE",
  "CODEX_GITHUB",
  "CODEX_GITHUB_CODE_REVIEW",
  "CODEX_SLACK",
  "CODEX_LINEAR",
]);
const usdPerCredit = 0.04;
const firstCloudDay = "2025-05-16";
const collectionDeadline = AbortSignal.timeout(90_000);

function tokens(value) {
  if (!Number.isSafeInteger(value) || value < 0)
    throw new Error("Cloud token count is missing or invalid.");
  return value;
}

function amount(value) {
  if (
    (typeof value !== "number" && typeof value !== "string") ||
    (typeof value === "string" && value.trim() === "")
  )
    throw new Error("Cloud cost is missing.");
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0)
    throw new Error("Cloud cost is invalid.");
  return number;
}

function day(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    throw new Error("Cloud usage date is invalid.");
  const parsed = new Date(`${value}T00:00:00Z`);
  if (
    !Number.isFinite(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== value
  )
    throw new Error("Cloud usage date is invalid.");
  return value;
}

export function normalizeCodexCloud(response) {
  if (!Array.isArray(response?.data) || response.group_by !== "day")
    throw new Error("Cloud analytics response is invalid.");
  const days = new Map();
  for (const row of response.data) {
    const date = day(row.date);
    if (days.has(date) || !Array.isArray(row.clients))
      throw new Error("Cloud analytics day is invalid.");
    const models = [];
    const seen = new Set();
    for (const client of row.clients) {
      if (!cloudClients.has(client.client_id)) continue;
      if (seen.has(client.client_id))
        throw new Error("Cloud analytics client is duplicated.");
      seen.add(client.client_id);
      const inputTokens = tokens(client.uncached_text_input_tokens);
      const cacheReadTokens = tokens(client.cached_text_input_tokens);
      const outputTokens = tokens(client.text_output_tokens);
      if (
        tokens(client.text_total_tokens) !==
        inputTokens + cacheReadTokens + outputTokens
      )
        throw new Error("Cloud analytics token totals disagree.");
      const cost =
        client.cost_usd !== undefined && client.cost_usd !== null
          ? amount(client.cost_usd)
          : response.balance_unit === "credit"
            ? amount(client.credits) * usdPerCredit
            : (() => {
                throw new Error("Cloud analytics currency is unsupported.");
              })();
      if (inputTokens + cacheReadTokens + outputTokens === 0 && cost === 0)
        continue;
      models.push({
        modelName: "unattributed-cloud-model",
        inputTokens,
        outputTokens,
        cacheCreationTokens: 0,
        cacheReadTokens,
        cost,
      });
    }
    days.set(date, models);
  }
  return {
    daily: [...days]
      .filter(([, models]) => models.length > 0)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([date, modelBreakdowns]) => ({ date, modelBreakdowns })),
  };
}

async function jsonFile(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw new Error("Cloud credentials or cache cannot be read.");
  }
}

async function request(url, headers, fetcher) {
  const response = await fetcher(url, {
    headers,
    redirect: "error",
    signal: AbortSignal.any([collectionDeadline, AbortSignal.timeout(20_000)]),
  });
  if (!response.ok)
    throw new Error(`Cloud request failed (HTTP ${response.status}).`);
  const reader = response.body?.getReader();
  if (!reader) throw new Error("Cloud response body is missing.");
  const decoder = new TextDecoder();
  let body = "";
  let bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 32 * 1024 * 1024) {
        await reader.cancel();
        throw new Error("Cloud response is too large.");
      }
      body += decoder.decode(value, { stream: true });
    }
    body += decoder.decode();
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(body);
  } catch {
    throw new Error("Cloud response is not valid JSON.");
  }
}

export async function collectCodexCloud(
  auth,
  { fetcher = fetch, now = new Date(), since = firstCloudDay } = {},
) {
  if (!auth?.tokens?.access_token) return { daily: [] };
  const headers = {
    Authorization: `Bearer ${auth.tokens.access_token}`,
    "ChatGPT-Account-Id": auth.tokens.account_id ?? "",
    "User-Agent": "Edith/1.0",
  };
  const end = now.toISOString().slice(0, 10);
  let start = day(since);
  const daily = [];
  while (start <= end) {
    const last = new Date(`${start}T00:00:00Z`);
    last.setUTCDate(last.getUTCDate() + 29);
    const until =
      last.toISOString().slice(0, 10) < end
        ? last.toISOString().slice(0, 10)
        : end;
    const url = new URL(
      "https://chatgpt.com/backend-api/wham/analytics/daily-workspace-usage-counts",
    );
    url.search = new URLSearchParams({
      start_date: start,
      end_date: until,
      group_by: "day",
      workspace_user: "true",
    });
    const page = normalizeCodexCloud(await request(url, headers, fetcher));
    if (page.daily.some((row) => row.date < start || row.date > until))
      throw new Error(
        "Cloud analytics returned a day outside the requested range.",
      );
    daily.push(...page.daily);
    last.setUTCDate(last.getUTCDate() + 1);
    start = last.toISOString().slice(0, 10);
  }
  return { daily };
}

export function claudeReceiptIdentity(value) {
  const row = value?.data?.message ?? value;
  const message = row?.message;
  if (
    (row?.type !== undefined && row.type !== "assistant") ||
    !message?.usage ||
    !message.id ||
    !row.requestId
  )
    return null;
  return JSON.stringify([message.id, row.requestId]);
}

export function claudeCloudReceipts(events, sessionID, local = new Set()) {
  const result = new Map();
  for (const event of events) {
    const payload = event?.payload ?? event;
    const row = payload?.data?.message ?? payload;
    const identity = claudeReceiptIdentity(row);
    if (!identity || local.has(identity)) continue;
    if (
      !Number.isFinite(Date.parse(row.timestamp)) ||
      typeof row.message.model !== "string"
    )
      throw new Error("Cloud receipt metadata is invalid.");
    const usage = row.message.usage;
    for (const key of [
      "input_tokens",
      "output_tokens",
      "cache_creation_input_tokens",
      "cache_read_input_tokens",
    ])
      tokens(usage[key] ?? (key.startsWith("cache_") ? 0 : undefined));
    const normalized = {
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      cache_creation_input_tokens: usage.cache_creation_input_tokens ?? 0,
      cache_read_input_tokens: usage.cache_read_input_tokens ?? 0,
    };
    if (usage.cache_creation) {
      normalized.cache_creation = {
        ephemeral_5m_input_tokens: tokens(
          usage.cache_creation.ephemeral_5m_input_tokens ?? 0,
        ),
        ephemeral_1h_input_tokens: tokens(
          usage.cache_creation.ephemeral_1h_input_tokens ?? 0,
        ),
      };
      if (
        Object.values(normalized.cache_creation).reduce((a, b) => a + b, 0) !==
        normalized.cache_creation_input_tokens
      )
        throw new Error("Cloud prompt cache totals disagree.");
    }
    const total = (value) =>
      value.input_tokens +
      value.output_tokens +
      value.cache_creation_input_tokens +
      value.cache_read_input_tokens;
    if (
      result.has(identity) &&
      total(result.get(identity).message.usage) > total(normalized)
    )
      continue;
    result.set(identity, {
      type: "assistant",
      timestamp: row.timestamp,
      sessionId: sessionID,
      requestId: row.requestId,
      message: {
        id: row.message.id,
        model: row.message.model,
        usage: normalized,
      },
    });
  }
  return [...result.values()];
}

export async function localClaudeReceipts(root) {
  const found = new Set();
  async function walk(directory) {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (error.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        const lines = createInterface({
          input: createReadStream(path),
          crlfDelay: Infinity,
        });
        for await (const line of lines) {
          try {
            const identity = claudeReceiptIdentity(JSON.parse(line));
            if (identity) found.add(identity);
          } catch {}
        }
      }
    }
  }
  await walk(root);
  return found;
}

async function fetchClaudeCloud(token, { fetcher, organization, cached }) {
  const headers = {
    Authorization: `Bearer ${token}`,
    "anthropic-version": "2023-06-01",
    "User-Agent": "Edith/1.0",
  };
  if (organization) headers["x-organization-uuid"] = organization;
  const sessions = [];
  const seen = new Set();
  let cursor;
  for (let page = 0; ; page++) {
    if (page >= 100) throw new Error("Cloud session pagination limit reached.");
    const url = new URL("https://api.anthropic.com/v1/code/sessions");
    url.searchParams.set("limit", "100");
    if (cursor) url.searchParams.set("cursor", cursor);
    const response = await request(url, headers, fetcher);
    if (!Array.isArray(response.data))
      throw new Error("Cloud sessions response is invalid.");
    for (const session of response.data) {
      if (
        typeof session.id !== "string" ||
        !/^[A-Za-z0-9_-]+$/.test(session.id)
      )
        throw new Error("Cloud session identity is invalid.");
      if (session.environment_kind === "bridge" || seen.has(session.id))
        continue;
      seen.add(session.id);
      sessions.push({
        id: session.id,
        revision: session.last_event_at ?? null,
      });
    }
    const next = response.next_cursor;
    if (!next) break;
    if (typeof next !== "string" || next === cursor)
      throw new Error("Cloud session cursor is invalid.");
    cursor = next;
  }
  const records = new Array(sessions.length);
  let index = 0;
  async function worker() {
    while (index < sessions.length) {
      const slot = index++;
      const { id: sessionID, revision } = sessions[slot];
      const previous = cached?.find(
        (record) => record.id === sessionID && record.revision === revision,
      );
      if (revision && previous) {
        records[slot] = {
          id: sessionID,
          revision,
          rows: claudeCloudReceipts(previous.rows, sessionID),
        };
        continue;
      }
      const events = [];
      let cursor;
      for (let page = 0; ; page++) {
        if (page >= 100)
          throw new Error("Cloud event pagination limit reached.");
        const url = new URL(
          `https://api.anthropic.com/v1/code/sessions/${encodeURIComponent(sessionID)}/teleport-events`,
        );
        url.searchParams.set("limit", "1000");
        if (cursor) url.searchParams.set("cursor", cursor);
        const response = await request(url, headers, fetcher);
        if (!Array.isArray(response.data))
          throw new Error("Cloud events response is invalid.");
        events.push(...response.data);
        const next = response.next_cursor;
        if (!next) break;
        if (typeof next !== "string" || next === cursor)
          throw new Error("Cloud event cursor is invalid.");
        cursor = next;
      }
      records[slot] = {
        id: sessionID,
        revision,
        rows: claudeCloudReceipts(events, sessionID),
      };
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(4, sessions.length) }, worker),
  );
  return records;
}

export async function collectClaudeCloud(
  token,
  destination,
  {
    fetcher = fetch,
    local = new Set(),
    organization,
    cache,
    notice = () => {},
  } = {},
) {
  if (!token) return { sessions: 0, receipts: 0 };
  const account = createHash("sha256")
    .update(`${token}:${organization ?? ""}`)
    .digest("hex");
  const saved = cache ? await jsonFile(cache) : null;
  const cached =
    saved?.account === account && Array.isArray(saved.sessions)
      ? saved.sessions
      : null;
  let records;
  try {
    records = await fetchClaudeCloud(token, { fetcher, organization, cached });
    if (cache) {
      await mkdir(join(cache, ".."), { recursive: true, mode: 0o700 });
      await writeFile(
        `${cache}.pending`,
        JSON.stringify({ account, sessions: records }),
        { mode: 0o600 },
      );
      await rename(`${cache}.pending`, cache);
    }
  } catch (error) {
    if (!cached) throw error;
    records = cached;
    notice("Cloud refresh unavailable. Using saved usage receipts.");
  }
  let receipts = 0;
  const excluded = new Set(local);
  for (const record of records) {
    if (typeof record.id !== "string" || !/^[A-Za-z0-9_-]+$/.test(record.id))
      throw new Error("Cloud cached session identity is invalid.");
    const rows = claudeCloudReceipts(record.rows, record.id, excluded);
    for (const row of rows) excluded.add(claudeReceiptIdentity(row));
    if (!rows.length) continue;
    await mkdir(join(destination, "projects", "cloud"), {
      recursive: true,
      mode: 0o700,
    });
    await writeFile(
      join(destination, "projects", "cloud", `${record.id}.jsonl`),
      rows.map(JSON.stringify).join("\n") + "\n",
      { mode: 0o600 },
    );
    receipts += rows.length;
  }
  return { sessions: records.length, receipts };
}

export async function claudeCredentials(
  home,
  {
    env = process.env,
    platform = process.platform,
    keychain = (service) =>
      execFileSync("security", ["find-generic-password", "-s", service, "-w"], {
        timeout: 2000,
        stdio: ["ignore", "pipe", "ignore"],
      }),
  } = {},
) {
  const config = env.CLAUDE_CONFIG_DIR || join(home, ".claude");
  let credentials = await jsonFile(join(config, ".credentials.json"));
  if (!credentials?.claudeAiOauth?.accessToken && platform === "darwin") {
    const suffix = env.CLAUDE_CONFIG_DIR
      ? `-${createHash("sha256").update(config.normalize("NFC")).digest("hex").slice(0, 8)}`
      : "";
    try {
      credentials = JSON.parse(keychain(`Claude Code-credentials${suffix}`));
    } catch {}
  }
  const oauth = credentials?.claudeAiOauth;
  if (!oauth?.accessToken) {
    if (env.CLAUDE_CODE_OAUTH_TOKEN)
      throw new Error(
        "Cloud session access requires a browser sign-in. A setup-token only supports model requests. Run claude auth login.",
      );
    return null;
  }
  if (
    Array.isArray(oauth.scopes) &&
    !oauth.scopes.includes("user:sessions:claude_code")
  )
    throw new Error(
      "Cloud browser sign-in lacks session access. Run claude auth login.",
    );
  return oauth.accessToken;
}

if (import.meta.main) {
  const [provider, destination, localRoot, cache] = process.argv.slice(2);
  try {
    const home = homedir();
    if (provider === "codex") {
      const auth = await jsonFile(
        join(process.env.CODEX_HOME || join(home, ".codex"), "auth.json"),
      );
      if (!auth?.tokens?.access_token)
        throw new Error("Cloud sign-in unavailable. Run codex login.");
      const result = await collectCodexCloud(auth);
      await writeFile(`${destination}.pending`, JSON.stringify(result), {
        mode: 0o600,
      });
      await rename(`${destination}.pending`, destination);
    } else if (provider === "claude") {
      const local = await localClaudeReceipts(localRoot);
      const cowork = await localClaudeReceipts(
        join(
          home,
          "Library",
          "Application Support",
          "Claude",
          "local-agent-mode-sessions",
        ),
      );
      for (const identity of cowork) local.add(identity);
      const token = await claudeCredentials(home);
      if (!token)
        throw new Error("Cloud sign-in unavailable. Run claude auth login.");
      const account = await jsonFile(join(home, ".claude.json"));
      await collectClaudeCloud(token, destination, {
        local,
        cache,
        organization:
          process.env.CLAUDE_CODE_ORGANIZATION_UUID ??
          account?.oauthAccount?.organizationUuid,
        notice: (message) => console.error(message),
      });
    } else throw new Error("Unknown cloud provider.");
  } catch (error) {
    console.error(
      error.message.startsWith("Cloud ")
        ? error.message
        : "Cloud collection failed.",
    );
    process.exitCode = 1;
  }
}
