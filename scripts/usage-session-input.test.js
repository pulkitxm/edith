import { afterEach, describe, expect, test } from "bun:test";
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  prepareSessionFile,
  prepareSessionUsage,
} from "../Packages/Edith/Sources/EdithKit/Resources/usage-session-input.mjs";

const roots = [];
afterEach(async () => {
  for (const root of roots.splice(0))
    await rm(root, { recursive: true, force: true });
});
const timestamp = "2026-09-22T12:00:00.000Z";
const metadata = {
  type: "session_meta",
  payload: { id: "thread-one", source: "vscode" },
};
const context = { type: "turn_context", payload: { model: "gpt-6-astra" } };
const usage = {
  input_tokens: 1000,
  cached_input_tokens: 200,
  output_tokens: 100,
  total_tokens: 1100,
};
const receipt = (id, overrides = {}) => ({
  timestamp,
  type: "token_usage_record",
  payload: {
    thread_id: "thread-one",
    session_id: "session-one",
    response_id: id,
    usage,
    ...overrides,
  },
});
const legacy = {
  timestamp,
  type: "event_msg",
  payload: { type: "token_count", info: { last_token_usage: usage } },
};
async function fixture(events) {
  const root = await mkdtemp(join(tmpdir(), "edith-session-input-"));
  roots.push(root);
  const source = join(root, "source.jsonl");
  const destination = join(root, "prepared", "session.jsonl");
  await writeFile(
    source,
    events
      .map((event) =>
        typeof event === "string" ? event : JSON.stringify(event),
      )
      .join("\n"),
  );
  return { root, source, destination };
}
async function prepared(events) {
  const files = await fixture(events);
  const result = await prepareSessionFile(files.source, files.destination);
  const rows = (await readFile(files.destination, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  return { ...files, result, rows };
}

describe("per-request session usage", () => {
  test("includes compaction requests missing from summary events without counting summaries twice", async () => {
    const { rows, result } = await prepared([
      metadata,
      context,
      receipt("normal"),
      legacy,
      receipt("compaction", {
        usage: { ...usage, input_tokens: 2000, total_tokens: 2100 },
      }),
      receipt("next"),
      legacy,
    ]);
    expect(result.records).toBe(3);
    const tokens = rows.filter((r) => r.payload?.type === "token_count");
    expect(
      tokens.reduce(
        (sum, r) => sum + r.payload.info.last_token_usage.total_tokens,
        0,
      ),
    ).toBe(4300);
    expect(
      tokens.every((r) => r.payload.info.total_token_usage === undefined),
    ).toBe(true);
  });
  test("deduplicates replayed responses but keeps distinct equal-sized requests", async () => {
    const { result } = await prepared([
      metadata,
      receipt("first"),
      receipt("first"),
      receipt("second"),
    ]);
    expect(result.records).toBe(2);
  });
  test("does not charge inherited parent receipts to a child thread", async () => {
    const { rows, result } = await prepared([
      metadata,
      receipt("parent", { thread_id: "parent-thread" }),
      receipt("child"),
    ]);
    expect(result.records).toBe(1);
    expect(rows.filter((r) => r.payload?.type === "token_count")).toHaveLength(
      1,
    );
  });
  test("preserves legacy turns when a session resumes in a newer client", async () => {
    const { rows, result } = await prepared([
      metadata,
      context,
      legacy,
      receipt("new"),
      legacy,
    ]);
    expect(result.records).toBe(1);
    expect(rows.filter((r) => r.payload?.type === "token_count")).toHaveLength(
      2,
    );
  });
  test("preserves model changes, speed tiers and child replay boundaries", async () => {
    const settings = {
      type: "event_msg",
      payload: {
        type: "thread_settings_applied",
        thread_settings: { service_tier: "priority" },
      },
    };
    const boundary = {
      type: "inter_agent_communication_metadata",
      payload: { trigger_turn: true },
    };
    const changed = { type: "turn_context", payload: { model: "gpt-5.6-sol" } };
    const { rows } = await prepared([
      metadata,
      boundary,
      context,
      settings,
      receipt("one"),
      changed,
      receipt("two"),
    ]);
    expect(rows.slice(0, 4)).toEqual([metadata, boundary, context, settings]);
    expect(rows[5]).toEqual(changed);
  });
  test("leaves legacy-only files byte-for-byte intact", async () => {
    const { source, destination, result } = await prepared([
      metadata,
      context,
      legacy,
    ]);
    expect(result.modern).toBe(false);
    expect((await lstat(destination)).isSymbolicLink()).toBe(true);
    expect(await readFile(destination)).toEqual(await readFile(source));
  });
  test("excludes conversation content and ignores a partial trailing write", async () => {
    const { rows, result } = await prepared([
      metadata,
      context,
      receipt("one"),
      { type: "response_item", payload: { content: "private message" } },
      '{"type":',
    ]);
    expect(result.records).toBe(1);
    expect(JSON.stringify(rows)).not.toContain("private message");
  });
  test("rejects invalid token values before publishing a prepared file", async () => {
    const files = await fixture([
      metadata,
      receipt("bad", { usage: { ...usage, input_tokens: -1 } }),
    ]);
    await expect(
      prepareSessionFile(files.source, files.destination),
    ).rejects.toThrow("Invalid per-request usage");
    await expect(lstat(files.destination)).rejects.toThrow();
  });
  test("discovers active and archived sessions without scanning unrelated directories", async () => {
    const { root } = await fixture([]);
    for (const directory of ["sessions", "archived_sessions", "plugins"]) {
      await mkdir(join(root, "home", directory), { recursive: true });
      await writeFile(
        join(root, "home", directory, "session.jsonl"),
        [metadata, context, receipt(directory)].map(JSON.stringify).join("\n"),
      );
    }
    const result = await prepareSessionUsage(
      join(root, "home"),
      join(root, "output"),
    );
    expect(result).toEqual({ files: 2, modernFiles: 2, records: 2 });
    await expect(lstat(join(root, "output", "plugins"))).rejects.toThrow();
  });
  test("a new installation with no sessions is valid", async () => {
    const { root } = await fixture([]);
    expect(
      await prepareSessionUsage(join(root, "missing"), join(root, "output")),
    ).toEqual({ files: 0, modernFiles: 0, records: 0 });
  });
});
