import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const script = readFileSync(
  join(
    import.meta.dir,
    "..",
    "Packages",
    "Edith",
    "Sources",
    "EdithKit",
    "Resources",
    "refresh-usage",
  ),
  "utf8",
);

function extractBlock(name) {
  const m = script.match(new RegExp(`\\n\\s*${name}='([\\s\\S]*?)\\n\\s*'`));
  expect(m).not.toBeNull();
  return m[1];
}

const NORM = extractBlock("NORM");
const ASSEMBLE = extractBlock("ASSEMBLE");
const VALIDATE = extractBlock("VALIDATE");
const WALK = extractBlock("WALK");
const WALKC = extractBlock("WALKC");
const WALKCC = extractBlock("WALKCC");
const CCDAILY = extractBlock("CCDAILY");
const FLEET = extractBlock("FLEET");

function jq(program, input, args = []) {
  const proc = Bun.spawnSync(["jq", "-c", ...args, program], {
    stdin: Buffer.from(input),
  });
  expect(proc.exitCode).toBe(0);
  return proc.stdout
    .toString()
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function jqExit(program, input, args = []) {
  return Bun.spawnSync(["jq", "-e", ...args, program], {
    stdin: Buffer.from(input),
  }).exitCode;
}

const walk = (lines, src = "cli", off = 0) =>
  jq(WALK, lines.map((l) => JSON.stringify(l)).join("\n"), [
    "--argjson",
    "off",
    String(off),
    "--arg",
    "src",
    src,
  ]);

const assistant = (over = {}) => ({
  type: "assistant",
  timestamp: "2026-06-10T12:30:00.123Z",
  sessionId: "sess-1",
  cwd: "/repo/app",
  requestId: "req-1",
  message: {
    id: "msg-1",
    model: "claude-opus-4-8",
    usage: {
      input_tokens: 10,
      output_tokens: 20,
      cache_creation_input_tokens: 30,
      cache_read_input_tokens: 40,
    },
  },
  ...over,
});

describe("WALK", () => {
  test("assistant line becomes a rec with token sum, epoch ms, and source", () => {
    const [rec] = walk([assistant()]);
    expect(rec.t).toBe("rec");
    expect(rec.tok).toBe(100);
    expect(rec.ts).toBe(Date.parse("2026-06-10T12:30:00Z"));
    expect(rec.date).toBe("2026-06-10");
    expect(rec.hour).toBe(12);
    expect(rec.src).toBe("cli");
    expect(rec.sid).toBe("sess-1");
    expect(rec.wt).toBeNull();
  });

  test("timezone offset shifts date and hour", () => {
    const [rec] = walk(
      [assistant({ timestamp: "2026-06-10T23:30:00Z" })],
      "cli",
      3600,
    );
    expect(rec.date).toBe("2026-06-11");
    expect(rec.hour).toBe(0);
  });

  test("worktree name extracted from claude and cursor markers", () => {
    const [a, b, c] = walk([
      assistant({ cwd: "/repo/app/.claude/worktrees/featx/sub" }),
      assistant({ cwd: "/repo/app/.cursor/worktrees/fix-1" }),
      assistant({ cwd: "/repo/app/src" }),
    ]);
    expect(a.wt).toBe("featx");
    expect(b.wt).toBe("fix-1");
    expect(c.wt).toBeNull();
  });

  test("assistant without usage or without any id is skipped", () => {
    const recs = walk([
      assistant({ message: { id: "m2", model: "m", usage: null } }),
      assistant({
        requestId: null,
        message: { model: "m", usage: { input_tokens: 1 } },
      }),
      assistant(),
    ]);
    expect(recs.length).toBe(1);
    expect(recs[0].id).toBe("msg-1");
  });

  test("ai-title lines become trimmed title records", () => {
    const out = walk([
      { type: "ai-title", aiTitle: "  Fix the bug  ", sessionId: "s1" },
      { type: "ai-title", aiTitle: "", sessionId: "s2" },
      { type: "ai-title", aiTitle: "No session" },
    ]);
    expect(out).toEqual([{ t: "title", sid: "s1", title: "Fix the bug" }]);
  });

  test("user text records: string + array content, tag-prefixed skipped, 80-char cap", () => {
    const long = "x".repeat(200);
    const out = walk([
      {
        type: "user",
        sessionId: "s1",
        timestamp: "t1",
        message: { content: "hello" },
      },
      {
        type: "user",
        sessionId: "s2",
        timestamp: "t2",
        message: {
          content: [
            { type: "tool_result" },
            { type: "text", text: " block text " },
          ],
        },
      },
      {
        type: "user",
        sessionId: "s3",
        message: { content: "<system-reminder>hi" },
      },
      { type: "user", sessionId: "s4", message: { content: long } },
      { type: "user", message: { content: "no session" } },
    ]);
    expect(out[0]).toEqual({ t: "text", sid: "s1", tms: "t1", text: "hello" });
    expect(out[1].text).toBe("block text");
    expect(out.length).toBe(3);
    expect(out[2].text.length).toBe(80);
  });
});

const walkc = (lines, src = "codex", off = 0) =>
  jq(WALKC, lines.map((l) => JSON.stringify(l)).join("\n"), [
    "--argjson",
    "off",
    String(off),
    "--arg",
    "src",
    src,
  ]);

const sessionMeta = (over = {}) => ({
  timestamp: "2026-06-10T12:00:00.000Z",
  type: "session_meta",
  payload: { id: "cx-1", cwd: "/repo/app", ...over },
});

const tokenCount = (usage = {}, over = {}) => ({
  timestamp: "2026-06-10T12:30:00.123Z",
  type: "event_msg",
  payload: {
    type: "token_count",
    info: {
      last_token_usage: {
        input_tokens: 100,
        cached_input_tokens: 60,
        output_tokens: 20,
        reasoning_output_tokens: 5,
        total_tokens: 120,
        ...usage,
      },
    },
  },
  ...over,
});

describe("WALKC", () => {
  test("token_count becomes a rec carrying session meta, model, and source", () => {
    const out = walkc([
      sessionMeta(),
      { type: "turn_context", payload: { model: "gpt-5.6-sol" } },
      tokenCount(),
      tokenCount({}, { timestamp: "2026-06-10T13:30:00.123Z" }),
    ]);
    expect(out.length).toBe(2);
    const [a, b] = out;
    expect(a.t).toBe("rec");
    expect(a.sid).toBe("cx-1");
    expect(a.cwd).toBe("/repo/app");
    expect(a.model).toBe("gpt-5.6-sol");
    expect(a.src).toBe("codex");
    expect(a.tok).toBe(120);
    expect(a.inp).toBe(40);
    expect(a.cr).toBe(60);
    expect(a.out).toBe(20);
    expect(a.date).toBe("2026-06-10");
    expect(a.hour).toBe(12);
    expect(a.ts).toBe(Date.parse("2026-06-10T12:30:00Z"));
    expect(a.wt).toBeNull();
    expect(a.id).not.toBe(b.id);
  });

  test("user_message becomes a text record, tag-prefixed and empty skipped", () => {
    const msg = (message) => ({
      timestamp: "2026-06-10T12:01:00.000Z",
      type: "event_msg",
      payload: { type: "user_message", message },
    });
    const out = walkc([
      sessionMeta(),
      msg("  fix the bug  "),
      msg("<environment_context>x"),
      msg(""),
    ]);
    expect(out).toEqual([
      {
        t: "text",
        sid: "cx-1",
        tms: "2026-06-10T12:01:00.000Z",
        text: "fix the bug",
      },
    ]);
  });

  test("zero-token counts and files without session_meta emit nothing", () => {
    expect(walkc([sessionMeta(), tokenCount({ total_tokens: 0 })])).toEqual([]);
    expect(walkc([tokenCount()])).toEqual([]);
  });
});

const walkcc = (lines, src = "commandcode", off = 0) =>
  jq(WALKCC, lines.map((l) => JSON.stringify(l)).join("\n"), [
    "--argjson",
    "off",
    String(off),
    "--arg",
    "src",
    src,
  ]);

const ccSession = (over = {}) => ({
  type: "session",
  version: 3,
  id: "cc-1",
  timestamp: "2026-06-10T12:00:00.000Z",
  cwd: "/repo/app",
  ...over,
});

const ccAssistant = (usage = {}, over = {}) => ({
  type: "message",
  id: "m-1",
  model: "deepseek/deepseek-v4-pro",
  timestamp: "2026-06-10T12:30:00.123Z",
  usage: {
    inputTokens: 100,
    outputTokens: 20,
    cacheReadTokens: 60,
    cacheWriteTokens: 5,
    costUsd: 0.25,
    ...usage,
  },
  message: { role: "assistant", content: [{ type: "text", text: "ok" }] },
  ...over,
});

const ccUser = (text, over = {}) => ({
  type: "message",
  id: "u-1",
  timestamp: "2026-06-10T12:01:00.000Z",
  message: { role: "user", content: [{ type: "text", text }] },
  ...over,
});

describe("WALKCC", () => {
  test("assistant message becomes a rec carrying its own exact cost", () => {
    const out = walkcc([
      ccSession(),
      ccAssistant(),
      ccAssistant({}, { timestamp: "2026-06-10T13:30:00.123Z" }),
    ]);
    expect(out.length).toBe(2);
    const [a, b] = out;
    expect(a.t).toBe("rec");
    expect(a.sid).toBe("cc-1");
    expect(a.cwd).toBe("/repo/app");
    expect(a.model).toBe("deepseek/deepseek-v4-pro");
    expect(a.src).toBe("commandcode");
    expect(a.inp).toBe(100);
    expect(a.out).toBe(20);
    expect(a.cr).toBe(60);
    expect(a.cc).toBe(5);
    expect(a.tok).toBe(185);
    expect(a.cost).toBe(0.25);
    expect(a.date).toBe("2026-06-10");
    expect(a.hour).toBe(12);
    expect(a.ts).toBe(Date.parse("2026-06-10T12:30:00Z"));
    expect(a.wt).toBeNull();
    expect(a.id).not.toBe(b.id);
  });

  test("user message becomes a text record, tag-prefixed and empty skipped", () => {
    const out = walkcc([
      ccSession(),
      ccUser("  fix the bug  "),
      ccUser("<system-reminder>x"),
      ccUser(""),
    ]);
    expect(out).toEqual([
      {
        t: "text",
        sid: "cc-1",
        tms: "2026-06-10T12:01:00.000Z",
        text: "fix the bug",
      },
    ]);
  });

  test("zero-token, session-less, and checkpoint files emit nothing", () => {
    expect(
      walkcc([
        ccSession(),
        ccAssistant({
          inputTokens: 0,
          outputTokens: 0,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
        }),
      ]),
    ).toEqual([]);
    expect(walkcc([ccAssistant()])).toEqual([]);
    expect(
      walkcc([
        { type: "file-history-snapshot", messageId: "m-1", snapshot: {} },
      ]),
    ).toEqual([]);
  });

  test("timezone offset shifts the local date and hour", () => {
    const [rec] = walkcc(
      [ccSession(), ccAssistant({}, { timestamp: "2026-06-10T23:30:00.000Z" })],
      "commandcode",
      3600 * 2,
    );
    expect(rec.date).toBe("2026-06-11");
    expect(rec.hour).toBe(1);
  });
});

describe("CCDAILY", () => {
  const ccdaily = (lines, off = 0) =>
    jq(CCDAILY, lines.map((l) => JSON.stringify(l)).join("\n"), [
      "-s",
      "--argjson",
      "off",
      String(off),
    ]);

  test("groups by local date then model and maps cache write to creation", () => {
    const [out] = ccdaily([
      ccSession(),
      ccAssistant(),
      ccAssistant(),
      ccAssistant({}, { model: "other-model" }),
      ccAssistant({}, { timestamp: "2026-06-11T09:00:00.000Z" }),
    ]);
    expect(out.daily.map((d) => d.date)).toEqual(["2026-06-10", "2026-06-11"]);

    const first = out.daily[0].modelBreakdowns;
    expect(first.length).toBe(2);
    const deepseek = first.find(
      (m) => m.modelName === "deepseek/deepseek-v4-pro",
    );
    expect(deepseek.inputTokens).toBe(200);
    expect(deepseek.outputTokens).toBe(40);
    expect(deepseek.cacheReadTokens).toBe(120);
    expect(deepseek.cacheCreationTokens).toBe(10);
    expect(deepseek.cost).toBe(0.5);
  });

  test("records without usage are ignored and totals survive NORM", () => {
    const [out] = ccdaily([ccSession(), ccUser("hi"), ccAssistant()]);
    expect(out.daily.length).toBe(1);
    const [norm] = jq(`${NORM} normDay`, JSON.stringify(out.daily[0]));
    expect(norm.period).toBe("2026-06-10");
    expect(norm.breakdowns[0].cost).toBe(0.25);
    expect(norm.breakdowns[0].cacheCreationTokens).toBe(5);
  });
});

describe("NORM", () => {
  const norm = (daily) =>
    jq(
      `${NORM} [.daily[] | normDay | .breakdowns |= dropSynthetic]`,
      JSON.stringify({ daily }),
    )[0];

  test("claude shape keeps per-model rows without re-adding reasoning", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        modelBreakdowns: [
          {
            modelName: "opus",
            inputTokens: 1,
            outputTokens: 2,
            reasoningOutputTokens: 3,
            cacheCreationTokens: 4,
            cacheReadTokens: 5,
            cost: 9,
          },
        ],
      },
    ]);
    expect(day.period).toBe("2026-06-10");
    expect(day.breakdowns[0].outputTokens).toBe(2);
    expect(day.breakdowns[0].cost).toBe(9);
  });

  test("codex shape splits row cost by token share", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        costUSD: 10,
        models: {
          a: { inputTokens: 30, outputTokens: 0 },
          b: { inputTokens: 10, outputTokens: 0 },
        },
      },
    ]);
    const byName = Object.fromEntries(
      day.breakdowns.map((b) => [b.modelName, b]),
    );
    expect(byName.a.cost).toBeCloseTo(7.5);
    expect(byName.b.cost).toBeCloseTo(2.5);
  });

  test("opencode shape splits row evenly across modelsUsed", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        totalCost: 8,
        inputTokens: 100,
        outputTokens: 20,
        modelsUsed: ["a", "b"],
      },
    ]);
    expect(day.breakdowns.length).toBe(2);
    expect(day.breakdowns[0].inputTokens).toBe(50);
    expect(day.breakdowns[0].cost).toBe(4);
  });

  test("zero-token zero-cost synthetic rows dropped, tokened ones kept", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        modelBreakdowns: [
          {
            modelName: "<synthetic>",
            inputTokens: 0,
            outputTokens: 0,
            cost: 0,
          },
          {
            modelName: "<synthetic>",
            inputTokens: 7,
            outputTokens: 0,
            cost: 0,
          },
          { modelName: "real", inputTokens: 0, outputTokens: 0, cost: 0 },
        ],
      },
    ]);
    expect(day.breakdowns.map((b) => b.modelName)).toEqual([
      "<synthetic>",
      "real",
    ]);
    expect(day.breakdowns[0].inputTokens).toBe(7);
  });
});

describe("usage pipeline", () => {
  const assemble = (sources, sessions = []) =>
    jq(ASSEMBLE, sources.map((source) => JSON.stringify(source)).join("\n"), [
      "-s",
      "--arg",
      "now",
      "2026-07-15T12:00:00Z",
      "--argjson",
      "ss",
      JSON.stringify([[{ sessions }]]),
    ])[0];

  test("large multi-agent totals survive normalization and assembly exactly", () => {
    const normalized = (source, label, daily) => ({
      source,
      label,
      norm: jq(
        `${NORM} [.daily[] | normDay | .breakdowns |= dropSynthetic]`,
        JSON.stringify({ daily }),
      )[0],
    });
    const cli = normalized("cli", "Claude Code", [
      {
        date: "2026-07-15",
        modelBreakdowns: [
          {
            modelName: "opus",
            inputTokens: 12_989,
            outputTokens: 100_000,
            cacheCreationTokens: 0,
            cacheReadTokens: 300_000,
            cost: 1,
          },
        ],
      },
    ]);
    const codex = normalized("codex", "Codex", [
      {
        date: "2026-07-15",
        costUSD: 1000,
        models: {
          "gpt-5.6-sol": {
            inputTokens: 43_272_379,
            outputTokens: 2_830_907,
            reasoningOutputTokens: 692_521,
            cacheReadTokens: 1_473_051_648,
          },
        },
      },
    ]);
    const out = assemble(
      [cli, codex],
      [
        { id: "cli-session", source: "cli" },
        { id: "codex-session", source: "codex" },
      ],
    );
    expect(out.sources).toEqual(["cli", "codex"]);
    expect(out.defaultSources).toEqual(["cli", "codex"]);
    expect(out.totals.tokens).toBe(1_519_567_923);
    expect(out.totals.inputTokens).toBe(43_285_368);
    expect(out.totals.outputTokens).toBe(2_930_907);
    expect(out.totals.cacheReadTokens).toBe(1_473_351_648);
    expect(out.daily[0].bySource.cli[0].inputTokens).toBe(12_989);
    expect(out.daily[0].bySource.codex[0].outputTokens).toBe(2_830_907);
    expect(out.sessions).toHaveLength(2);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("empty tokens and sessions produce rigid zero totals", () => {
    const out = assemble([
      {
        source: "codex",
        label: "Codex",
        norm: [{ period: "2026-07-15", breakdowns: [] }],
      },
    ]);
    expect(out.totals).toEqual({
      cost: 0,
      tokens: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
    });
    expect(out.sessions).toEqual([]);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("validation rejects every inconsistent token invariant", () => {
    const valid = assemble([
      {
        source: "codex",
        label: "Codex",
        norm: [
          {
            period: "2026-07-15",
            breakdowns: [
              {
                modelName: "gpt",
                inputTokens: 10,
                outputTokens: 20,
                cacheCreationTokens: 30,
                cacheReadTokens: 40,
                cost: 1,
              },
            ],
          },
        ],
      },
    ]);
    const corruptions = [
      (value) => value.totals.tokens++,
      (value) => value.totals.inputTokens++,
      (value) => value.totals.outputTokens++,
      (value) => value.totals.cacheCreationTokens++,
      (value) => value.totals.cacheReadTokens++,
      (value) => (value.daily[0].bySource.codex[0].inputTokens = -1),
      (value) => value.daily.push(structuredClone(value.daily[0])),
      (value) => value.sources.push("codex"),
      (value) => value.defaultSources.push("missing"),
    ];
    for (const corrupt of corruptions) {
      const value = structuredClone(valid);
      corrupt(value);
      expect(jqExit(VALIDATE, JSON.stringify(value))).toBe(1);
    }
  });
});

const localDoc = (over = {}) => ({
  schemaVersion: 6,
  generatedAt: "2026-08-08T10:00:00Z",
  sources: ["cli"],
  defaultSources: ["cli"],
  sourceMeta: { cli: { label: "Claude Code", tool: "Claude Code" } },
  totals: {
    cost: 1,
    tokens: 100,
    inputTokens: 10,
    outputTokens: 20,
    cacheCreationTokens: 30,
    cacheReadTokens: 40,
  },
  sessions: [{ id: "s1", source: "cli" }],
  daily: [
    {
      period: "2026-08-07",
      bySource: {
        cli: [
          {
            modelName: "opus",
            inputTokens: 10,
            outputTokens: 20,
            cacheCreationTokens: 30,
            cacheReadTokens: 40,
            cost: 1,
          },
        ],
      },
      hours: [{ tokens: 100, cost: 1 }],
      projects: [
        {
          projectName: "edith",
          path: "/Users/p/edith",
          tokens: 100,
          cost: 1,
          chats: [{ id: "c1", source: "cli", tokens: 100, cost: 1 }],
          worktrees: [],
        },
      ],
    },
  ],
  ...over,
});

const machineDoc = (over = {}) => ({
  schemaVersion: 6,
  generatedAt: "2026-08-08T09:00:00Z",
  sources: ["cli", "codex"],
  defaultSources: ["cli", "codex"],
  sourceMeta: {
    cli: { label: "Claude Code", tool: "Claude Code" },
    codex: { label: "Codex", tool: "Codex" },
  },
  machine: {
    id: "11111111-1111-1111-1111-111111111111",
    name: "tuf",
    slug: "tuf",
    host: "tuf.local",
    collectedAt: "2026-08-08T09:05:00Z",
  },
  sessions: [{ id: "s9", source: "cli" }],
  daily: [
    {
      period: "2026-08-07",
      bySource: {
        cli: [
          {
            modelName: "opus",
            inputTokens: 1,
            outputTokens: 2,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            cost: 2,
          },
        ],
      },
      hours: [{ tokens: 3, cost: 2 }],
      projects: [
        {
          projectName: "edith",
          path: "/home/p/edith",
          tokens: 3,
          cost: 2,
          chats: [{ id: "c9", source: "cli", tokens: 3, cost: 2 }],
          worktrees: [
            {
              name: "wt",
              chats: [{ id: "c8", source: "codex", tokens: 0, cost: 0 }],
            },
          ],
        },
      ],
    },
  ],
  ...over,
});

const fleet = (docs) =>
  jq(FLEET, docs.map((d) => JSON.stringify(d)).join("\n"), ["-s"])[0];

describe("FLEET", () => {
  test("machine sources are namespaced and labelled with the machine", () => {
    const out = fleet([localDoc(), machineDoc()]);
    expect(out.sources).toEqual(["cli", "tuf:cli", "tuf:codex"]);
    expect(out.defaultSources).toEqual(["cli", "tuf:cli", "tuf:codex"]);
    expect(out.sourceMeta["tuf:cli"].label).toBe("Claude Code · tuf");
    expect(out.sourceMeta["tuf:cli"].machine).toBe("tuf");
    expect(out.sourceMeta.cli.label).toBe("Claude Code");
  });

  test("a day seen on both sides keeps one row with both sides' sources", () => {
    const out = fleet([localDoc(), machineDoc()]);
    expect(out.daily).toHaveLength(1);
    expect(Object.keys(out.daily[0].bySource).sort()).toEqual([
      "cli",
      "tuf:cli",
    ]);
    expect(out.daily[0].hours).toHaveLength(24);
    expect(out.daily[0].hours[0]).toEqual({ tokens: 103, cost: 3 });
  });

  test("machine projects and chats stay separable from the local ones", () => {
    const out = fleet([localDoc(), machineDoc()]);
    const projects = out.daily[0].projects;
    expect(projects.map((p) => p.projectName)).toEqual([
      "edith",
      "edith · tuf",
    ]);
    expect(projects[1].path).toBe("tuf:/home/p/edith");
    expect(projects[1].chats[0].source).toBe("tuf:cli");
    expect(projects[1].worktrees[0].chats[0].source).toBe("tuf:codex");
  });

  test("totals are recomputed over the merged rows and pass validation", () => {
    const out = fleet([localDoc(), machineDoc()]);
    expect(out.totals.cost).toBe(3);
    expect(out.totals.tokens).toBe(103);
    expect(out.totals.inputTokens).toBe(11);
    expect(out.machines).toEqual([
      {
        id: "11111111-1111-1111-1111-111111111111",
        name: "tuf",
        slug: "tuf",
        host: "tuf.local",
        collectedAt: "2026-08-08T09:05:00Z",
        sources: ["tuf:cli", "tuf:codex"],
      },
    ]);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("two machines never collide, and days only one of them has survive", () => {
    const other = machineDoc({
      machine: {
        id: "22222222-2222-2222-2222-222222222222",
        name: "pi",
        slug: "pi",
        host: "pi.local",
        collectedAt: "2026-08-08T09:06:00Z",
      },
      daily: [
        {
          period: "2026-08-06",
          bySource: {
            cli: [
              {
                modelName: "opus",
                inputTokens: 4,
                outputTokens: 0,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                cost: 5,
              },
            ],
          },
          hours: [],
          projects: [],
        },
      ],
    });
    const out = fleet([localDoc(), machineDoc(), other]);
    expect(out.daily.map((d) => d.period)).toEqual([
      "2026-08-06",
      "2026-08-07",
    ]);
    expect(Object.keys(out.daily[0].bySource)).toEqual(["pi:cli"]);
    expect(out.totals.cost).toBe(8);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("a machine with no usage adds nothing but still reports itself", () => {
    const out = fleet([
      localDoc(),
      machineDoc({ sources: [], defaultSources: [], daily: [], sessions: [] }),
    ]);
    expect(out.sources).toEqual(["cli"]);
    expect(out.totals.tokens).toBe(100);
    expect(out.machines[0].sources).toEqual([]);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });
});
