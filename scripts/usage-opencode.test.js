import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const source = readFileSync(
  new URL(
    "../Packages/Edith/Sources/EdithKit/Resources/refresh-usage",
    import.meta.url,
  ),
  "utf8",
);
const walker = source.slice(
  source.indexOf('  OPENCODE_MESSAGES="'),
  source.indexOf("  NFILES=$(find"),
);

function collect(configure) {
  const directory = mkdtempSync(join(tmpdir(), "edith-opencode-test-"));
  try {
    const path = join(directory, "opencode.db");
    const database = new Database(path);
    configure(database);
    database.close();
    const result = Bun.spawnSync(
      ["bash", "-c", `${walker}\nwalk_opencode "$1"`, "--", path],
      { env: { ...process.env, TMP: directory, OFF: "0" } },
    );
    expect(result.exitCode).toBe(0);
    return readFileSync(join(directory, "walk.jsonl"), "utf8")
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

function modernSchema(database) {
  database.run("create table session_v2 (id text, directory text, title text)");
  database.run(
    "create table session_message (id text, session_id text, type text, time_created integer, data text)",
  );
  database.run(
    "insert into session_v2 values ('session-1', '/synthetic/project', 'Synthetic session')",
  );
}

function receipt(input, created = 1_786_000_000_000) {
  return {
    time: { created },
    model: { id: "gpt-5.6-sol" },
    tokens: { input, output: 2, reasoning: 3, cache: { read: 7, write: 0 } },
  };
}

test("collects modern OpenCode requests with repository, reasoning, and title", () => {
  const rows = collect((database) => {
    modernSchema(database);
    database.run(
      "insert into session_message values (?, ?, ?, ?, ?)",
      "message-1",
      "session-1",
      "assistant",
      1_786_000_000_000,
      JSON.stringify(receipt(5)),
    );
    database.run(
      "insert into session_message values (?, ?, ?, ?, ?)",
      "user-1",
      "session-1",
      "user",
      1_786_000_000_000,
      JSON.stringify(receipt(999)),
    );
  });
  expect(rows.filter((row) => row.t === "rec")).toEqual([
    expect.objectContaining({
      id: "opencode:message-1",
      cwd: "/synthetic/project",
      model: "gpt-5.6-sol",
      inp: 5,
      out: 5,
      cr: 7,
      tok: 17,
    }),
  ]);
  expect(rows).toContainEqual({
    t: "title",
    sid: "session-1",
    title: "Synthetic session",
  });
});

test("deduplicates migrated IDs while retaining legacy and simultaneous requests", () => {
  const rows = collect((database) => {
    modernSchema(database);
    database.run("create table message (id text, session_id text, data text)");
    for (const [id, input] of [
      ["shared", 5],
      ["legacy-only", 10],
    ]) {
      database.run(
        "insert into message values (?, 'session-1', ?)",
        id,
        JSON.stringify({
          ...receipt(input),
          role: "assistant",
          modelID: "gpt-5.6-sol",
        }),
      );
    }
    for (const [id, input] of [
      ["shared", 20],
      ["modern-only", 30],
    ]) {
      database.run(
        "insert into session_message values (?, 'session-1', 'assistant', ?, ?)",
        id,
        1_786_000_000_000,
        JSON.stringify(receipt(input)),
      );
    }
  }).filter((row) => row.t === "rec");
  expect(rows).toHaveLength(3);
  expect(rows.find((row) => row.id === "opencode:shared").inp).toBe(20);
  expect(rows.reduce((total, row) => total + row.tok, 0)).toBe(96);
});

test("falls back to the modern row timestamp when the receipt omits it", () => {
  const rows = collect((database) => {
    modernSchema(database);
    const data = receipt(5);
    delete data.time;
    database.run(
      "insert into session_message values ('message-1', 'session-1', 'assistant', ?, ?)",
      1_786_000_000_000,
      JSON.stringify(data),
    );
  });
  expect(rows.find((row) => row.t === "rec").ts).toBe(1_786_000_000_000);
});
