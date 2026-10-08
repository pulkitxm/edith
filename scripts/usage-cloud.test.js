import { describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  claudeCloudReceipts,
  claudeCredentials,
  claudeReceiptIdentity,
  collectClaudeCloud,
  collectCodexCloud,
  localClaudeReceipts,
  normalizeCodexCloud,
} from "../Packages/Edith/Sources/EdithKit/Resources/usage-cloud.mjs";

import { BillingArchive } from "../Packages/Edith/Sources/EdithKit/Resources/usage-billing-archive.mjs";

const client = (id = "CODEX_WORK_WEB", overrides = {}) => ({
  client_id: id,
  credits: 25,
  uncached_text_input_tokens: 100,
  cached_text_input_tokens: 20,
  text_output_tokens: 30,
  text_total_tokens: 150,
  ...overrides,
});
const analytics = (clients, date = "2026-10-01") => ({
  group_by: "day",
  balance_unit: "credit",
  data: [
    {
      date,
      clients,
      models: [{ model: "mixed-provider-model", credits: 1000 }],
    },
  ],
});
const receipt = (id = "message", overrides = {}) => ({
  type: "assistant",
  timestamp: "2026-10-01T12:00:00Z",
  requestId: "request",
  message: {
    id,
    model: "claude-sonnet-4-5",
    content: [{ type: "text", text: "synthetic private content" }],
    usage: {
      input_tokens: 100,
      output_tokens: 30,
      cache_read_input_tokens: 20,
    },
  },
  ...overrides,
});
const reply = (body, status = 200) =>
  new Response(JSON.stringify(body), { status });

describe("Codex cloud usage", () => {
  test("counts cloud clients without re-adding local clients or assigning account-wide models", () => {
    const result = normalizeCodexCloud(
      analytics([
        client(),
        client("CODEX_GITHUB_CODE_REVIEW"),
        client("CODEX_CLI"),
        client("CODEX_DESKTOP_APP"),
        client("CODEX_WORK_DESKTOP"),
        client("CODEX_UNKNOWN_DEFAULT"),
        client("FUTURE_CLIENT"),
      ]),
    );
    expect(result.daily[0].modelBreakdowns).toHaveLength(2);
    expect(result.daily[0].modelBreakdowns[0]).toEqual({
      modelName: "unattributed-cloud-model",
      inputTokens: 100,
      outputTokens: 30,
      cacheReadTokens: 20,
      cacheCreationTokens: 0,
      cost: 1,
    });
    expect(JSON.stringify(result)).not.toContain("mixed-provider-model");
  });

  test("uses explicit USD when present and preserves true zero", () => {
    expect(
      normalizeCodexCloud(
        analytics([client("CODEX_WEB", { cost_usd: "0.125" })]),
      ).daily[0].modelBreakdowns[0].cost,
    ).toBe(0.125);
    expect(
      normalizeCodexCloud(analytics([client("CODEX_WEB", { cost_usd: "0" })]))
        .daily[0].modelBreakdowns[0].cost,
    ).toBe(0);
  });

  test("rejects malformed data instead of turning unavailable accounting into zero", () => {
    for (const overrides of [
      { uncached_text_input_tokens: null },
      { cached_text_input_tokens: -1 },
      { text_output_tokens: 0.1 },
      { text_total_tokens: 500 },
      { credits: null },
      { credits: true },
      { credits: " " },
      { credits: [] },
      { credits: -1 },
      { cost_usd: "NaN" },
    ])
      expect(() =>
        normalizeCodexCloud(analytics([client("CODEX_WEB", overrides)])),
      ).toThrow();
    expect(() =>
      normalizeCodexCloud({
        ...analytics([client()]),
        balance_unit: "percent",
      }),
    ).toThrow();
    expect(() =>
      normalizeCodexCloud(analytics([client()], "2026-02-30")),
    ).toThrow();
    expect(() =>
      normalizeCodexCloud(analytics([client(), client()])),
    ).toThrow();
    expect(() => normalizeCodexCloud({ data: [] })).toThrow();
  });

  test("queries only the signed-in user across bounded UTC date windows", async () => {
    const requests = [];
    const result = await collectCodexCloud(
      {
        tokens: {
          access_token: "synthetic-token",
          account_id: "synthetic-account",
        },
      },
      {
        since: "2026-08-01",
        now: new Date("2026-10-01T12:00:00Z"),
        fetcher: async (url, options) => {
          requests.push({ url, options });
          return reply(
            analytics([client()], url.searchParams.get("start_date")),
          );
        },
      },
    );
    expect(result.daily.map((row) => row.date)).toEqual([
      "2026-08-01",
      "2026-08-31",
      "2026-09-30",
    ]);
    expect(
      requests.every(
        ({ url }) => url.searchParams.get("workspace_user") === "true",
      ),
    ).toBe(true);
    expect(requests[0].options.headers["ChatGPT-Account-Id"]).toBe(
      "synthetic-account",
    );
    expect(requests[0].options.redirect).toBe("error");
    expect(requests.at(-1).url.searchParams.get("end_date")).toBe("2026-10-01");
  });

  test("no sign-in needs no network and rejected access propagates", async () => {
    expect(
      await collectCodexCloud(null, {
        fetcher: () => {
          throw new Error("unexpected request");
        },
      }),
    ).toEqual({ daily: [] });
    await expect(
      collectCodexCloud(
        { tokens: { access_token: "synthetic" } },
        {
          fetcher: async () => reply({}, 403),
        },
      ),
    ).rejects.toThrow("HTTP 403");
  });
});

describe("Claude Code cloud receipts", () => {
  test("deduplicates streaming receipts and excludes exactly matching local requests", () => {
    const local = new Set([claudeReceiptIdentity(receipt("local"))]);
    const rows = claudeCloudReceipts(
      [
        receipt("local"),
        receipt("cloud"),
        receipt("cloud"),
        receipt("distinct"),
        { type: "user", message: { content: "synthetic prompt" } },
      ],
      "session-cloud",
      local,
    );
    expect(rows).toHaveLength(2);
    expect(rows.map((r) => r.message.id)).toEqual(["cloud", "distinct"]);
    expect(rows[0].sessionId).toBe("session-cloud");
    expect(JSON.stringify(rows)).not.toContain("content");
  });

  test("excludes local receipts after the billing archive removes transcript fields", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-billing-test-"));
    let archive;
    try {
      const config = join(root, "config");
      const projects = join(config, "projects", "synthetic");
      await mkdir(projects, { recursive: true });
      const rows = [
        receipt("resumed"),
        { type: "progress", data: { message: receipt("wrapped") } },
      ];
      await writeFile(
        join(projects, "session.jsonl"),
        rows.map(JSON.stringify).join("\n") + "\n",
      );
      archive = new BillingArchive(join(root, "history"));
      archive.bootstrap({ generatedAt: "2026-10-01T12:00:00Z", blocks: [] });
      archive.ingest(config);
      const snapshot = join(root, "snapshot");
      archive.materialize(snapshot);
      const local = await localClaudeReceipts(join(snapshot, "projects"));
      expect(local.size).toBe(2);
      const remaining = claudeCloudReceipts(
        [receipt("resumed"), receipt("wrapped"), receipt("web-only")],
        "cloud-session",
        local,
      );
      expect(remaining.map((row) => row.message.id)).toEqual(["web-only"]);
    } finally {
      archive?.close();
      await rm(root, { recursive: true, force: true });
    }
  });

  test("reads event payloads and preserves prompt cache categories", () => {
    const row = receipt();
    row.message.usage.cache_creation_input_tokens = 50;
    expect(
      claudeCloudReceipts([{ payload: row }], "session")[0].message.usage,
    ).toEqual({
      input_tokens: 100,
      output_tokens: 30,
      cache_creation_input_tokens: 50,
      cache_read_input_tokens: 20,
    });
  });

  test("rejects invalid token counts and timestamps", () => {
    const row = receipt();
    row.message.usage.input_tokens = -1;
    expect(() => claudeCloudReceipts([row], "session")).toThrow();
    expect(() =>
      claudeCloudReceipts(
        [receipt("one", { timestamp: "invalid" })],
        "session",
      ),
    ).toThrow();
  });

  test("walks all session and event pages, includes archives, excludes local remote-control sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-test-"));
    const requested = [];
    try {
      const result = await collectClaudeCloud("synthetic-token", root, {
        fetcher: async (url) => {
          requested.push(url.pathname);
          if (url.pathname.endsWith("/sessions"))
            return reply(
              url.searchParams.has("cursor")
                ? {
                    data: [{ id: "archived", status: "archived" }],
                    next_cursor: null,
                  }
                : {
                    data: [
                      { id: "cloud" },
                      { id: "local", environment_kind: "bridge" },
                    ],
                    next_cursor: "second",
                  },
            );
          return reply(
            url.searchParams.has("cursor")
              ? { data: [{ payload: receipt("two") }], next_cursor: null }
              : { data: [{ payload: receipt() }], next_cursor: "next" },
          );
        },
      });
      expect(result).toEqual({ sessions: 2, receipts: 2 });
      expect(requested).not.toContain(
        "/v1/code/sessions/local/teleport-events",
      );
      const saved = await readFile(
        join(root, "projects", "cloud", "cloud.jsonl"),
        "utf8",
      );
      expect(saved.trim().split("\n")).toHaveLength(2);
      expect(saved).not.toContain("synthetic private content");
      expect(saved).not.toContain("synthetic-token");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("rejects repeated pagination cursors and unsafe session names", async () => {
    await expect(
      collectClaudeCloud("synthetic", "/unused", {
        fetcher: async () => reply({ data: [], next_cursor: "same" }),
      }),
    ).rejects.toThrow("cursor");
    await expect(
      collectClaudeCloud("synthetic", "/unused", {
        fetcher: async () => reply({ data: [{ id: "../outside" }] }),
      }),
    ).rejects.toThrow("identity");
  });
  test("keeps the largest streamed receipt and preserves cache lifetimes", () => {
    const larger = receipt("stream");
    larger.message.usage.cache_creation_input_tokens = 50;
    larger.message.usage.cache_creation = {
      ephemeral_5m_input_tokens: 20,
      ephemeral_1h_input_tokens: 30,
    };
    const rows = claudeCloudReceipts([larger, receipt("stream")], "session");
    expect(rows).toHaveLength(1);
    expect(rows[0].message.usage.cache_creation).toEqual({
      ephemeral_5m_input_tokens: 20,
      ephemeral_1h_input_tokens: 30,
    });
    larger.message.usage.cache_creation.ephemeral_1h_input_tokens = 40;
    expect(() => claudeCloudReceipts([larger], "session")).toThrow("totals");
  });

  test("reuses unchanged sessions and excludes resumed receipts even when the provider is unavailable", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-cache-test-"));
    const cache = join(root, "cache", "receipts.json");
    const fetcher = async (url) =>
      url.pathname.endsWith("/sessions")
        ? reply({
            data: [{ id: "cloud", last_event_at: "2026-10-01T12:00:00Z" }],
          })
        : reply({ data: [receipt("resumed"), receipt("web-only")] });
    try {
      await collectClaudeCloud("synthetic", join(root, "first"), {
        cache,
        fetcher,
      });
      const saved = await readFile(cache, "utf8");
      expect(saved).not.toContain("content");
      expect(saved).not.toContain("synthetic");
      let calls = 0;
      await collectClaudeCloud("synthetic", join(root, "second"), {
        cache,
        fetcher: async (url) => {
          calls++;
          if (!url.pathname.endsWith("/sessions"))
            throw new Error("unchanged session was fetched");
          return fetcher(url);
        },
      });
      expect(calls).toBe(1);
      const notices = [];
      const result = await collectClaudeCloud(
        "synthetic",
        join(root, "offline"),
        {
          cache,
          local: new Set([claudeReceiptIdentity(receipt("resumed"))]),
          fetcher: async () => reply({}, 401),
          notice: (message) => notices.push(message),
        },
      );
      expect(result.receipts).toBe(1);
      expect(notices).toHaveLength(1);
      const remaining = await readFile(
        join(root, "offline", "projects", "cloud", "cloud.jsonl"),
        "utf8",
      );
      expect(remaining).not.toContain("resumed");
      await expect(
        collectClaudeCloud("different-account", join(root, "other"), {
          cache,
          fetcher: async () => reply({}, 401),
        }),
      ).rejects.toThrow("HTTP 401");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});

describe("Claude cloud sign-in", () => {
  test("uses subscription browser credentials even when a model-only environment token is present", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-auth-test-"));
    try {
      await mkdir(join(root, ".claude"));
      await writeFile(
        join(root, ".claude", ".credentials.json"),
        JSON.stringify({
          claudeAiOauth: {
            accessToken: "synthetic-browser-token",
            scopes: ["user:inference", "user:sessions:claude_code"],
          },
        }),
      );
      expect(
        await claudeCredentials(root, {
          platform: "linux",
          env: { CLAUDE_CODE_OAUTH_TOKEN: "synthetic-model-token" },
        }),
      ).toBe("synthetic-browser-token");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("does not mistake setup-token or an API key for cloud-session access", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-auth-test-"));
    try {
      await expect(
        claudeCredentials(root, {
          platform: "linux",
          env: { CLAUDE_CODE_OAUTH_TOKEN: "synthetic-model-token" },
        }),
      ).rejects.toThrow("setup-token only supports model requests");
      expect(
        await claudeCredentials(root, {
          platform: "linux",
          env: { ANTHROPIC_API_KEY: "synthetic-api-key" },
        }),
      ).toBeNull();
      await mkdir(join(root, ".claude"));
      await writeFile(
        join(root, ".claude", ".credentials.json"),
        JSON.stringify({
          claudeAiOauth: {
            accessToken: "synthetic-limited-token",
            scopes: ["user:inference"],
          },
        }),
      );
      await expect(
        claudeCredentials(root, { platform: "linux", env: {} }),
      ).rejects.toThrow("lacks session access");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  test("reads subscription credentials from the macOS keychain", async () => {
    const root = await mkdtemp(join(tmpdir(), "edith-cloud-auth-test-"));
    try {
      const services = [];
      const token = await claudeCredentials(root, {
        env: {},
        platform: "darwin",
        keychain: (service) => {
          services.push(service);
          return JSON.stringify({
            claudeAiOauth: {
              accessToken: "synthetic-browser-token",
              scopes: ["user:sessions:claude_code"],
            },
          });
        },
      });
      expect(token).toBe("synthetic-browser-token");
      expect(services).toEqual(["Claude Code-credentials"]);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
