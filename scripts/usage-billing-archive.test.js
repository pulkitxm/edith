import { expect, test } from "bun:test";
import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BillingArchive } from "../Packages/Edith/Sources/EdithKit/Resources/usage-billing-archive.mjs";

const binary = process.env.EDITH_NATIVE_CCUSAGE;
const line = (id, tokens = 10, time = "2026-09-05T01:00:00Z") =>
  `${JSON.stringify({
    timestamp: time,
    version: "1.0.0",
    sessionId: "session",
    requestId: "request",
    costUSD: 1,
    message: {
      ...(id ? { id } : {}),
      model: "model",
      usage: { input_tokens: tokens, output_tokens: 2 },
      content: [{ type: "text", text: "PRIVATE_CONTENT_CANARY" }],
    },
  })}\n`;
const put = (root, path, contents) => {
  const target = join(root, "projects", path);
  mkdirSync(target.slice(0, target.lastIndexOf("/")), {
    recursive: true,
    mode: 0o700,
  });
  writeFileSync(target, contents);
  return target;
};
const native = (root, config, mode = "daily") => {
  if (!binary)
    throw new Error(
      "Native billing verification requires EDITH_NATIVE_CCUSAGE.",
    );
  const env = {
    ...process.env,
    HOME: join(root, "home"),
    XDG_CONFIG_HOME: join(root, "xdg"),
    CLAUDE_CONFIG_DIR: config,
  };
  delete env.CFFIXED_USER_HOME;
  const result = Bun.spawnSync(
    [
      binary,
      "claude",
      mode,
      "--json",
      "--offline",
      "--mode",
      "display",
      "--single-thread",
    ],
    { env, cwd: root, timeout: 10_000 },
  );
  expect(result.exitCode).toBe(0);
  return JSON.parse(result.stdout.toString());
};
const openArchive = (history, limits) => {
  const archive = new BillingArchive(history, limits);
  archive.bootstrap({ generatedAt: "2026-09-06T01:00:00Z", blocks: [] });
  return archive;
};
const fixture = (action) => {
  const root = mkdtempSync(join(tmpdir(), "edith-billing-ledger-"));
  const config = join(root, "input");
  const history = join(root, "history");
  try {
    action({ root, config, history });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
};

test("restart and disappeared files retain exact native daily and session results with appended new events", () =>
  fixture(({ root, config, history }) => {
    const old = line("old", 20);
    const live = line("live", 15);
    const next = line("new", 7, "2026-09-06T01:00:00Z");
    const oldPath = put(config, "a/session-a.jsonl", old);
    const livePath = put(config, "b/session-b.jsonl", live);
    let archive = openArchive(history);
    expect(archive.ingest(config).retainedFiles).toBe(0);
    archive.close();
    unlinkSync(oldPath);
    appendFileSync(livePath, next);
    archive = openArchive(history);
    expect(archive.ingest(config)).toEqual({
      version: 1,
      collectorVersion: "20.0.19",
      retainedFiles: 1,
      unresolvedCandidates: 0,
      rawFilesRead: 1,
      rawBytesRead: Buffer.byteLength(live + next),
    });
    const expected = join(root, "expected");
    put(expected, "a/session-a.jsonl", old);
    put(expected, "b/session-b.jsonl", live + next);
    const output = join(root, "snapshot");
    archive.materialize(output);
    if (binary) {
      for (const mode of ["daily", "session"])
        expect(native(root, output, mode)).toEqual(
          native(root, expected, mode),
        );
    }
    expect(
      readFileSync(join(output, "projects/a/session-a.jsonl"), "utf8"),
    ).not.toContain("PRIVATE_CONTENT_CANARY");
    put(config, "a/session-a.jsonl", old);
    expect(archive.ingest(config).retainedFiles).toBe(0);
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(3);
    archive.close();
  }));

test("anonymous rewritten records remain uncounted candidates while exact later appends continue", () =>
  fixture(({ root, config, history }) => {
    const old = line(null, 20);
    const rewritten = line(null, 90);
    const next = line(null, 7, "2026-09-06T01:00:00Z");
    const file = put(config, "project/session.jsonl", old);
    const archive = openArchive(history);
    archive.ingest(config);
    writeFileSync(file, rewritten + rewritten);
    expect(archive.ingest(config).unresolvedCandidates).toBe(2);
    expect(archive.ingest(config).unresolvedCandidates).toBe(2);
    appendFileSync(file, next);
    expect(archive.ingest(config).unresolvedCandidates).toBe(2);
    const expected = join(root, "expected");
    put(expected, "project/session.jsonl", old + next);
    const output = join(root, "snapshot");
    archive.materialize(output);
    if (binary) expect(native(root, output)).toEqual(native(root, expected));
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(4);
    archive.close();
  }));

test("stable identities retain streaming revisions and delegate exact duplicate choice to native collector", () =>
  fixture(({ root, config, history }) => {
    const old = line("same", 20);
    const fresh = line("same", 25) + line("new", 9);
    const file = put(config, "project/session.jsonl", old);
    const archive = openArchive(history);
    archive.ingest(config);
    writeFileSync(file, fresh);
    expect(archive.ingest(config).unresolvedCandidates).toBe(0);
    const output = join(root, "snapshot");
    archive.materialize(output);
    if (binary) expect(native(root, output)).toEqual(native(root, config));
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(3);
    archive.close();
  }));

test("capacity refusal rolls back new records and file receipt while preserving previously admitted billing", () =>
  fixture(({ config, history }) => {
    const old = line("old");
    const file = put(config, "project/session.jsonl", old);
    let archive = openArchive(history, { records: 1 });
    archive.ingest(config);
    const receipt = archive.database.query("SELECT * FROM files").get();
    appendFileSync(file, line("new"));
    expect(() => archive.ingest(config)).toThrow("capacity reached");
    expect(archive.database.query("SELECT * FROM files").get()).toEqual(
      receipt,
    );
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(1);
    archive.close();
    archive = openArchive(history, { records: 2 });
    archive.ingest(config);
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(2);
    archive.close();
  }));

test("incomplete final lines are admitted once after completion", () =>
  fixture(({ config, history }) => {
    const record = line(null);
    const first = record.slice(0, 50);
    const file = put(config, "project/session.jsonl", first);
    const archive = openArchive(history);
    archive.ingest(config);
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(0);
    appendFileSync(file, record.slice(50));
    archive.ingest(config);
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(1);
    archive.ingest(config);
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(1);
    archive.close();
  }));

test("source identity and path safety refuse admission without changing retained records", () =>
  fixture(({ root, config, history }) => {
    put(config, "project/session.jsonl", line("old"));
    const archive = openArchive(history);
    archive.ingest(config);
    expect(() => archive.ingest(join(root, "other"))).toThrow(
      "source identity changed",
    );
    symlinkSync(join(root, "outside"), join(config, "projects/link"));
    expect(() => archive.ingest(config)).toThrow("symbolic links");
    expect(
      archive.database.query("SELECT records FROM capacity").get().records,
    ).toBe(1);
    archive.close();
    chmodSync(history, 0o755);
    expect(() => new BillingArchive(history)).toThrow("owned");
  }));

test("billing integer bytes remain exact beyond JavaScript safe integer precision", () =>
  fixture(({ root, config, history }) => {
    const raw = line("large").replace(
      '"input_tokens":10',
      '"input_tokens":18446744073709551615',
    );
    put(config, "project/session.jsonl", raw);
    const archive = openArchive(history);
    archive.ingest(config);
    const output = join(root, "snapshot");
    archive.materialize(output);
    expect(
      readFileSync(join(output, "projects/project/session.jsonl"), "utf8"),
    ).toContain("18446744073709551615");
    archive.close();
  }));

const block = (period, tokens) => ({
  period,
  bySource: {
    cli: [
      {
        modelName: "model",
        inputTokens: tokens,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: tokens / 10,
      },
    ],
  },
  hours: Array.from({ length: 24 }, () => ({
    tokens: 0,
    cost: 0,
    bySource: {},
    byPath: {},
  })),
  projects: [],
});

test("recovered aggregate must bootstrap before scanning and matching historical output has provenance without a warning", () =>
  fixture(({ config, history }) => {
    put(config, "project/session.jsonl", line("available", 60));
    const archive = new BillingArchive(history);
    expect(() => archive.ingest(config)).toThrow("baseline is required");
    const recovered = block("2026-08-05", 100);
    archive.bootstrap({
      generatedAt: "2026-09-06T01:00:00Z",
      blocks: [recovered],
    });
    archive.ingest(config);
    expect(archive.reconcile([recovered])).toEqual({ version: 1, blocks: [] });
    expect(
      JSON.parse(
        archive.database.query("SELECT payload FROM baselines").get().payload,
      ),
    ).toEqual(recovered);
    expect(
      JSON.parse(
        archive.database
          .query("SELECT value FROM metadata WHERE key='baseline'")
          .get().value,
      ).kind,
    ).toBe("published-aggregate");
    archive.close();
  }));

test("divergent historical and active-day candidates stay distinct across restart while new days are unrestricted", () =>
  fixture(({ history }) => {
    const historical = block("2026-08-05", 100);
    const active = block("2026-09-06", 20);
    let archive = new BillingArchive(history);
    archive.bootstrap({
      generatedAt: "2026-09-06T01:00:00Z",
      blocks: [historical, active],
    });
    expect(archive.reconcile([historical, active]).blocks).toHaveLength(0);
    const first = archive.reconcile([
      block("2026-08-05", 60),
      block("2026-09-06", 25),
      block("2026-09-07", 9),
    ]);
    expect(first.blocks).toHaveLength(2);
    expect(first.blocks.map((value) => value.baseline)).toEqual([
      historical,
      active,
    ]);
    archive.close();
    archive = new BillingArchive(history);
    archive.bootstrap({
      generatedAt: "2026-09-07T02:00:00Z",
      blocks: [block("2026-08-05", 999)],
    });
    const second = archive.reconcile([
      block("2026-08-05", 110),
      block("2026-09-06", 25),
      block("2026-09-07", 17),
    ]);
    expect(second.blocks[0].baseline).toEqual(historical);
    expect(second.blocks[0].candidates).toHaveLength(2);
    expect(second.blocks[1].candidates).toHaveLength(1);
    expect(second.blocks.some((value) => value.period === "2026-09-07")).toBe(
      false,
    );
    expect(
      archive.reconcile([historical, active]).blocks[0].candidates,
    ).toHaveLength(2);
    archive.close();
  }));

test("aggregate candidate capacity refusal retains the exact earlier baseline and admitted candidate", () =>
  fixture(({ history }) => {
    const historical = block("2026-08-05", 100);
    const archive = new BillingArchive(history, { aggregateCandidates: 1 });
    archive.bootstrap({
      generatedAt: "2026-09-06T01:00:00Z",
      blocks: [historical],
    });
    const first = archive.reconcile([block("2026-08-05", 60)]);
    expect(() => archive.reconcile([block("2026-08-05", 70)])).toThrow(
      "capacity reached",
    );
    expect(archive.reconcile([block("2026-08-05", 60)])).toEqual(first);
    expect(
      archive.database
        .query("SELECT COUNT(*) AS count FROM aggregate_candidates")
        .get().count,
    ).toBe(1);
    archive.close();
  }));
