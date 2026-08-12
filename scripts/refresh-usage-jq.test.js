import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const inheritedGitVariables = [
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR",
  "GIT_CONFIG",
  "GIT_CONFIG_COUNT",
  "GIT_CONFIG_PARAMETERS",
  "GIT_DIR",
  "GIT_GRAFT_FILE",
  "GIT_IMPLICIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_NO_REPLACE_OBJECTS",
  "GIT_OBJECT_DIRECTORY",
  "GIT_PREFIX",
  "GIT_REPLACE_REF_BASE",
  "GIT_SHALLOW_FILE",
  "GIT_WORK_TREE",
];
const isolatedGitEnvironment = { ...process.env };
for (const variable of inheritedGitVariables) {
  delete isolatedGitEnvironment[variable];
}

const scriptPath = join(
  import.meta.dir,
  "..",
  "Packages",
  "Edith",
  "Sources",
  "EdithKit",
  "Resources",
  "refresh-usage",
);
const script = readFileSync(scriptPath, "utf8");

function extractBlock(name) {
  const m = script.match(new RegExp(`\\n\\s*${name}='([\\s\\S]*?)\\n\\s*'`));
  expect(m).not.toBeNull();
  return m[1];
}

const NORM = extractBlock("NORM");
const GITHUB = extractBlock("GITHUB");
const CWD_CACHE = extractBlock("CWD_CACHE");
const ASSEMBLE = extractBlock("ASSEMBLE");
const VALIDATE = extractBlock("VALIDATE");
const WALK = extractBlock("WALK");
const WALKC = extractBlock("WALKC");
const WALKPI = extractBlock("WALKPI");
const WALKCC = extractBlock("WALKCC");
const DEDUP = extractBlock("DEDUP");
const DETAILS = extractBlock("DETAILS");
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

function runCollectorFixture({
  hasLocalUsage,
  machineJSON,
  failDetails,
  failClaudeDaily = false,
  malformedClaudeDaily = false,
  failNormalization = false,
  legacyDeletedWorktree = false,
  deletedWorktreeBaseRepository = false,
}) {
  const root = mkdtempSync(join(tmpdir(), "edith-refresh-usage-"));
  const home = join(root, "home");
  const cache = join(root, "cache");
  const output = join(root, "output");
  const bin = join(home, ".local", "bin");
  const ccusage = join(cache, ".ccusage", "node_modules", ".bin");
  mkdirSync(bin, { recursive: true });
  mkdirSync(ccusage, { recursive: true });
  mkdirSync(output, { recursive: true });
  let deletedCwd = join(root, "deleted-worktree");
  if (deletedWorktreeBaseRepository) {
    const baseRepository = join(root, "repository");
    mkdirSync(baseRepository, { recursive: true });
    expect(
      Bun.spawnSync(["git", "init", baseRepository], {
        env: isolatedGitEnvironment,
      }).exitCode,
    ).toBe(0);
    expect(
      Bun.spawnSync(
        [
          "git",
          "-C",
          baseRepository,
          "remote",
          "add",
          "origin",
          "git@github.com:owner/repository.git",
        ],
        { env: isolatedGitEnvironment },
      ).exitCode,
    ).toBe(0);
    deletedCwd = join(
      baseRepository,
      ".claude",
      "worktrees",
      "deleted",
      "subfolder",
    );
  }
  if (legacyDeletedWorktree || deletedWorktreeBaseRepository) {
    const projects = join(home, ".claude", "projects");
    mkdirSync(projects, { recursive: true });
    writeFileSync(
      join(projects, "session.jsonl"),
      `${JSON.stringify({
        type: "assistant",
        timestamp: "2026-08-07T12:00:00.000Z",
        sessionId: "legacy-session",
        cwd: deletedCwd,
        requestId: "legacy-request",
        message: {
          id: "legacy-message",
          model: "opus",
          usage: { input_tokens: 1 },
        },
      })}\n`,
    );
    if (legacyDeletedWorktree) {
      writeFileSync(
        join(cache, ".cwdmap.v4.jsonl"),
        `${JSON.stringify({
          cwd: deletedCwd,
          name: "repository",
          root: deletedCwd,
          repositoryID: "github.com/owner/repository",
          repositoryName: "repository",
          repositoryURL: "https://github.com/owner/repository",
          folderName: "deleted-worktree",
        })}\n`,
      );
    }
  }
  const existing = '{"sentinel":"preserved"}\n';
  writeFileSync(join(output, "usage.json"), existing);
  if (machineJSON !== undefined) {
    const machines = join(output, "machines");
    mkdirSync(machines, { recursive: true });
    writeFileSync(join(machines, "machine.json"), machineJSON);
  }
  const bunPath = join(bin, "bun");
  writeFileSync(bunPath, '#!/bin/sh\nexec "$@"\n');
  chmodSync(bunPath, 0o755);
  const ccusagePath = join(ccusage, "ccusage");
  writeFileSync(
    ccusagePath,
    `#!/bin/sh
if [ "\${1:-}" = "--version" ]; then
  printf 'ccusage 20.0.19\\n'
elif [ "\${2:-}" = "daily" ]; then
  if [ "\${1:-}" = "claude" ] && [ "\${FAIL_CLAUDE_DAILY:-0}" = "1" ]; then
    exit 72
  elif [ "\${1:-}" = "claude" ] && [ "\${MALFORMED_CLAUDE_DAILY:-0}" = "1" ]; then
    printf '{"daily":'
  elif [ "\${1:-}" = "claude" ] && [ "\${FAIL_NORMALIZATION:-0}" = "1" ]; then
    printf '%s\\n' '{"daily":[{"date":"2026-08-07","models":{"broken":42}}]}'
  elif [ "\${1:-}" = "claude" ] && [ "\${FAKE_LOCAL_USAGE:-0}" = "1" ]; then
    printf '%s\\n' '{"daily":[{"date":"2026-08-07","modelBreakdowns":[{"modelName":"opus","inputTokens":1,"outputTokens":0,"cacheCreationTokens":0,"cacheReadTokens":0,"cost":1}]}]}'
  else
    printf '%s\\n' '{"daily":[]}'
  fi
elif [ "\${2:-}" = "session" ]; then
  printf '%s\\n' '{"sessions":[]}'
else
  exit 1
fi
`,
  );
  chmodSync(ccusagePath, 0o755);
  if (failDetails) {
    const realJQ = Bun.which("jq");
    expect(realJQ).not.toBeNull();
    const jqPath = join(bin, "jq");
    writeFileSync(
      jqPath,
      `#!/bin/sh
has_usage=0
has_records=0
for argument in "$@"; do
  [ "$argument" = "usage" ] && has_usage=1
  case "$argument" in
    */recs.json) has_records=1 ;;
  esac
done
[ "$has_usage" = "1" ] && [ "$has_records" = "1" ] && exit 86
exec "$REAL_JQ" "$@"
`,
    );
    chmodSync(jqPath, 0o755);
  }
  const process = Bun.spawnSync(["bash", scriptPath, output], {
    env: {
      ...isolatedGitEnvironment,
      HOME: home,
      EDITH_CACHE_DIR: cache,
      FAKE_LOCAL_USAGE: hasLocalUsage ? "1" : "0",
      FAIL_CLAUDE_DAILY: failClaudeDaily ? "1" : "0",
      MALFORMED_CLAUDE_DAILY: malformedClaudeDaily ? "1" : "0",
      FAIL_NORMALIZATION: failNormalization ? "1" : "0",
      REAL_JQ: Bun.which("jq") ?? "jq",
    },
  });
  const result = {
    exitCode: process.exitCode,
    stdout: process.stdout.toString(),
    stderr: process.stderr.toString(),
    output: readFileSync(join(output, "usage.json"), "utf8"),
    existing,
    deletedCwd,
  };
  rmSync(root, { recursive: true, force: true });
  return result;
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

  test("nested cache creation tiers win when the top-level total is zero", () => {
    const value = assistant();
    value.message.usage.cache_creation_input_tokens = 0;
    value.message.usage.cache_creation = {
      ephemeral_5m_input_tokens: 31,
      ephemeral_1h_input_tokens: 47,
    };
    const [rec] = walk([value]);
    expect(rec.cc).toBe(78);
    expect(rec.tok).toBe(148);
  });

  test("the final streaming usage record wins during deduplication", () => {
    const first = assistant({ timestamp: "2026-06-10T12:30:00.000Z" });
    first.message.usage.output_tokens = 5;
    const final = assistant({ timestamp: "2026-06-10T12:30:02.000Z" });
    final.message.usage.output_tokens = 207;
    const records = walk([first, final]);
    const [deduped] = jq(
      DEDUP,
      records.map((record) => JSON.stringify(record)).join("\n"),
      ["-s"],
    );
    expect(deduped).toHaveLength(1);
    expect(deduped[0].out).toBe(207);
    expect(deduped[0].tok).toBe(287);
  });

  test("a later lower-token streaming duplicate cannot replace the complete record", () => {
    const complete = assistant({ timestamp: "2026-06-10T12:30:00.000Z" });
    complete.message.usage.output_tokens = 207;
    const partial = assistant({ timestamp: "2026-06-10T12:30:02.000Z" });
    partial.message.usage.output_tokens = 5;
    const records = walk([complete, partial]);
    const [deduped] = jq(
      DEDUP,
      records.map((record) => JSON.stringify(record)).join("\n"),
      ["-s"],
    );
    expect(deduped).toHaveLength(1);
    expect(deduped[0].out).toBe(207);
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

const tokenCount = (usage = {}, over = {}, totalUsage = usage) => {
  const defaults = {
    input_tokens: 100,
    cached_input_tokens: 60,
    output_tokens: 20,
    reasoning_output_tokens: 5,
    total_tokens: 120,
  };
  return {
    timestamp: "2026-06-10T12:30:00.123Z",
    type: "event_msg",
    payload: {
      type: "token_count",
      info: {
        last_token_usage: { ...defaults, ...usage },
        total_token_usage: { ...defaults, ...totalUsage },
      },
    },
    ...over,
  };
};

const secondCumulativeUsage = {
  input_tokens: 200,
  cached_input_tokens: 120,
  output_tokens: 40,
  reasoning_output_tokens: 10,
  total_tokens: 240,
};

describe("WALKC", () => {
  test("session metadata is retained while token snapshots emit no detail", () => {
    const out = walkc([
      sessionMeta(),
      { type: "turn_context", payload: { model: "gpt-5.6-sol" } },
      tokenCount(),
      tokenCount(
        {},
        { timestamp: "2026-06-10T13:30:00.123Z" },
        secondCumulativeUsage,
      ),
    ]);
    expect(out).toEqual([
      { t: "meta", sid: "cx-1", cwd: "/repo/app", src: "codex" },
    ]);
  });

  test("fork replay, model switches, repeats, and cumulative resets stay unattributed", () => {
    const resetUsage = {
      input_tokens: 40,
      cached_input_tokens: 20,
      output_tokens: 10,
      reasoning_output_tokens: 2,
      total_tokens: 50,
    };
    const out = walkc([
      sessionMeta(),
      { type: "turn_context", payload: { model: "gpt-first" } },
      tokenCount({}, { timestamp: "2026-06-10T12:30:00.123Z" }),
      tokenCount({}, { timestamp: "2026-06-10T12:31:00.123Z" }),
      { type: "turn_context", payload: { model: "gpt-second" } },
      tokenCount(
        {},
        { timestamp: "2026-06-10T12:32:00.123Z" },
        secondCumulativeUsage,
      ),
      tokenCount({}, { timestamp: "2026-06-10T12:33:00.123Z" }, resetUsage),
      tokenCount(
        {},
        { timestamp: "2026-06-10T12:34:00.123Z" },
        secondCumulativeUsage,
      ),
    ]);
    expect(out).toEqual([
      { t: "meta", sid: "cx-1", cwd: "/repo/app", src: "codex" },
    ]);
    expect(out.some((record) => record.t === "rec")).toBeFalse();
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
      { t: "meta", sid: "cx-1", cwd: "/repo/app", src: "codex" },
      {
        t: "text",
        sid: "cx-1",
        tms: "2026-06-10T12:01:00.000Z",
        text: "fix the bug",
      },
    ]);
  });

  test("files without session_meta emit nothing", () => {
    expect(walkc([tokenCount()])).toEqual([]);
  });
});

const walkpi = (lines, src = "pi", off = 0) =>
  jq(WALKPI, lines.map((l) => JSON.stringify(l)).join("\n"), [
    "--argjson",
    "off",
    String(off),
    "--arg",
    "src",
    src,
  ]);

const piSession = (over = {}) => ({
  type: "session",
  version: 3,
  id: "pi-session-1",
  timestamp: "2026-06-10T12:00:00.000Z",
  cwd: "/repo/pi-app",
  ...over,
});

const piUsage = (over = {}) => ({
  input: 100,
  output: 20,
  cacheRead: 60,
  cacheWrite: 5,
  totalTokens: 185,
  cost: {
    input: 0.1,
    output: 0.1,
    cacheRead: 0.02,
    cacheWrite: 0.03,
    total: 0.25,
  },
  ...over,
});

const piMessage = (role, over = {}) => ({
  type: "message",
  id: `${role}-1`,
  parentId: null,
  timestamp: "2026-06-10T12:30:00.123Z",
  message: {
    role,
    model: role === "assistant" ? "claude-sonnet-4-5" : undefined,
    usage: role === "user" ? undefined : piUsage(),
    content: role === "user" ? [{ type: "text", text: "fix pi usage" }] : [],
  },
  ...over,
});

describe("WALKPI", () => {
  test("assistant, tool, and summary usage become exact detail records", () => {
    const out = walkpi([
      piSession(),
      piMessage("assistant"),
      piMessage("toolResult", { id: "tool-1" }),
      {
        type: "compaction",
        id: "compact-1",
        timestamp: "2026-06-10T13:30:00.123Z",
        usage: piUsage({ input: 10, output: 2, cacheRead: 0, cacheWrite: 0 }),
      },
      {
        type: "branch_summary",
        id: "summary-1",
        timestamp: "2026-06-10T14:30:00.123Z",
        usage: piUsage({ input: 8, output: 3, cacheRead: 0, cacheWrite: 0 }),
      },
    ]);
    expect(out).toHaveLength(4);
    expect(out[0]).toMatchObject({
      t: "rec",
      id: "pi:pi-session-1:assistant-1",
      sid: "pi-session-1",
      cwd: "/repo/pi-app",
      model: "claude-sonnet-4-5",
      src: "pi",
      inp: 100,
      out: 20,
      cr: 60,
      cc: 5,
      tok: 185,
      cost: 0.25,
      date: "2026-06-10",
      hour: 12,
      ts: Date.parse("2026-06-10T12:30:00Z"),
      wt: null,
    });
    expect(out[1].model).toBe("unknown");
    expect(out[2]).toMatchObject({
      id: "pi:pi-session-1:compact-1",
      inp: 10,
      out: 2,
    });
    expect(out[3]).toMatchObject({
      id: "pi:pi-session-1:summary-1",
      inp: 8,
      out: 3,
    });
  });

  test("user text and explicit session names provide chat titles", () => {
    const out = walkpi([
      piSession(),
      piMessage("user"),
      { type: "session_info", id: "name-1", name: "  Pi coverage  " },
    ]);
    expect(out).toEqual([
      {
        t: "text",
        sid: "pi-session-1",
        tms: "2026-06-10T12:30:00.123Z",
        text: "fix pi usage",
      },
      { t: "title", sid: "pi-session-1", title: "Pi coverage" },
    ]);
  });

  test("zero-token usage and files without a session header emit nothing", () => {
    expect(
      walkpi([
        piSession(),
        piMessage("assistant", {
          message: {
            role: "assistant",
            model: "model",
            usage: piUsage({
              input: 0,
              output: 0,
              cacheRead: 0,
              cacheWrite: 0,
            }),
          },
        }),
      ]),
    ).toEqual([]);
    expect(walkpi([piMessage("assistant")])).toEqual([]);
  });

  test("timezone offset shifts the local date and hour", () => {
    const [rec] = walkpi(
      [
        piSession(),
        piMessage("assistant", { timestamp: "2026-06-10T23:30:00.000Z" }),
      ],
      "pi",
      3600 * 2,
    );
    expect(rec.date).toBe("2026-06-11");
    expect(rec.hour).toBe(1);
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

  test("mixed-model shape keeps model tokens and marks cost unavailable", () => {
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
    expect(byName.a.inputTokens).toBe(30);
    expect(byName.a.cost).toBe(0);
    expect(byName.b.inputTokens).toBe(10);
    expect(byName.b.cost).toBe(0);
    expect(byName["unattributed-cost"]).toEqual({
      modelName: "unattributed-cost",
      inputTokens: 0,
      outputTokens: 0,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      cost: 10,
    });
    expect(
      day.breakdowns.reduce(
        (sum, row) =>
          sum +
          row.inputTokens +
          row.outputTokens +
          row.cacheCreationTokens +
          row.cacheReadTokens,
        0,
      ),
    ).toBe(40);
    expect(day.breakdowns.reduce((sum, row) => sum + row.cost, 0)).toBe(10);
  });

  test("single-model shape assigns the exact source cost", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        costUSD: 10,
        models: {
          a: { inputTokens: 30, outputTokens: 10 },
        },
      },
    ]);
    expect(day.breakdowns).toEqual([
      {
        modelName: "a",
        inputTokens: 30,
        outputTokens: 10,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: 10,
      },
    ]);
  });

  test("empty model shape keeps source cost unattributed", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        costUSD: 10,
        models: {},
      },
    ]);
    expect(day.breakdowns).toEqual([
      {
        modelName: "unattributed-cost",
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: 10,
      },
    ]);
  });

  test("aggregate multi-model shape keeps exact totals under unknown", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        totalCost: 8,
        inputTokens: 100,
        outputTokens: 20,
        modelsUsed: ["a", "b"],
      },
    ]);
    expect(day.breakdowns).toEqual([
      {
        modelName: "unknown",
        inputTokens: 100,
        outputTokens: 20,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: 8,
      },
    ]);
  });

  test("missing model name remains unknown", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        modelBreakdowns: [
          {
            inputTokens: 12,
            outputTokens: 3,
            cost: 2,
          },
        ],
      },
    ]);
    expect(day.breakdowns).toEqual([
      {
        modelName: "unknown",
        inputTokens: 12,
        outputTokens: 3,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: 2,
      },
    ]);
  });

  test("aggregate single-model shape retains the available model name", () => {
    const [day] = norm([
      {
        date: "2026-06-10",
        totalCost: 8,
        inputTokens: 100,
        outputTokens: 20,
        modelsUsed: ["one-model"],
      },
    ]);
    expect(day.breakdowns[0].modelName).toBe("one-model");
    expect(day.breakdowns[0].inputTokens).toBe(100);
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
  const assemble = (sources, sessions = []) => {
    const out = jq(
      ASSEMBLE,
      sources.map((source) => JSON.stringify(source)).join("\n"),
      [
        "-s",
        "--arg",
        "now",
        "2026-07-15T12:00:00Z",
        "--argjson",
        "ss",
        JSON.stringify([[{ sessions }]]),
      ],
    )[0];
    out.schemaVersion = 7;
    for (const day of out.daily) {
      day.hours = Array.from({ length: 24 }, () => ({
        tokens: 0,
        cost: 0,
        bySource: {},
        byPath: {},
      }));
      day.projects = [];
    }
    return out;
  };

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

  test("mixed-model unattributed cost row does not double source tokens", () => {
    const norm = jq(
      `${NORM} [.daily[] | normDay | .breakdowns |= dropSynthetic]`,
      JSON.stringify({
        daily: [
          {
            date: "2026-07-15",
            costUSD: 10,
            models: {
              a: { inputTokens: 30 },
              b: { outputTokens: 10 },
            },
          },
        ],
      }),
    )[0];
    const out = assemble([{ source: "codex", label: "Codex", norm }]);
    expect(out.totals.tokens).toBe(40);
    expect(out.totals.cost).toBe(10);
    expect(out.daily[0].bySource.codex).toHaveLength(3);
    expect(out.daily[0].bySource.codex).toContainEqual({
      modelName: "unattributed-cost",
      inputTokens: 0,
      outputTokens: 0,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      cost: 10,
    });
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

  test("validation rejects inconsistent token and cost invariants", () => {
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
      (value) => (value.totals.cost += 1),
      (value) => value.totals.inputTokens++,
      (value) => value.totals.outputTokens++,
      (value) => value.totals.cacheCreationTokens++,
      (value) => value.totals.cacheReadTokens++,
      (value) => (value.daily[0].bySource.codex[0].inputTokens = -1),
      (value) => value.daily.push(structuredClone(value.daily[0])),
      (value) => value.sources.push("codex"),
      (value) => value.defaultSources.push("missing"),
      (value) => (value.schemaVersion = 6),
      (value) => value.daily[0].hours.pop(),
      (value) => delete value.daily[0].hours[0].byPath,
      (value) => delete value.daily[0].projects,
    ];
    for (const corrupt of corruptions) {
      const value = structuredClone(valid);
      corrupt(value);
      expect(jqExit(VALIDATE, JSON.stringify(value))).toBe(1);
    }
    const withinTolerance = structuredClone(valid);
    withinTolerance.totals.cost += 0.0000005;
    expect(jqExit(VALIDATE, JSON.stringify(withinTolerance))).toBe(0);
  });
});

const localDoc = (over = {}) => ({
  schemaVersion: 7,
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
      hours: [
        {
          tokens: 100,
          cost: 1,
          bySource: {
            cli: {
              tokens: 100,
              cost: 1,
              byModel: { opus: { tokens: 100, cost: 1 } },
            },
          },
          byPath: {
            "/Users/p/edith": {
              tokens: 100,
              cost: 1,
              bySource: {
                cli: {
                  tokens: 100,
                  cost: 1,
                  byModel: { opus: { tokens: 100, cost: 1 } },
                },
              },
            },
          },
        },
      ],
      projects: [
        {
          projectName: "edith",
          repositoryID: "github.com/pulkitxm/edith",
          repositoryName: "edith",
          repositoryURL: "https://github.com/pulkitxm/edith",
          folderName: "edith-local",
          path: "/Users/p/edith",
          tokens: 100,
          cost: 1,
          bySource: {
            cli: {
              tokens: 100,
              cost: 1,
              byModel: { opus: { tokens: 100, cost: 1 } },
            },
          },
          chats: [
            {
              id: "c1",
              path: "/Users/p/edith",
              source: "cli",
              tokens: 100,
              cost: 1,
            },
          ],
          worktrees: [],
        },
      ],
    },
  ],
  ...over,
});

const machineDoc = (over = {}) => ({
  schemaVersion: 7,
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
      hours: [
        {
          tokens: 3,
          cost: 2,
          bySource: {
            cli: {
              tokens: 3,
              cost: 2,
              byModel: { opus: { tokens: 3, cost: 2 } },
            },
          },
          byPath: {
            "/home/p/edith/.claude/worktrees/wt/sub": {
              tokens: 3,
              cost: 2,
              bySource: {
                cli: {
                  tokens: 3,
                  cost: 2,
                  byModel: { opus: { tokens: 3, cost: 2 } },
                },
              },
            },
          },
        },
      ],
      projects: [
        {
          projectName: "edith",
          repositoryID: "github.com/pulkitxm/edith",
          repositoryName: "edith",
          repositoryURL: "https://github.com/pulkitxm/edith",
          folderName: "edith-tuf",
          path: "/home/p/edith",
          tokens: 3,
          cost: 2,
          bySource: {
            cli: {
              tokens: 3,
              cost: 2,
              byModel: { opus: { tokens: 3, cost: 2 } },
            },
          },
          chats: [
            {
              id: "c9",
              path: "/home/p/edith",
              source: "cli",
              tokens: 3,
              cost: 2,
            },
          ],
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

describe("repository and detail attribution", () => {
  test("cached fallback identities are revalidated for GitHub promotion", () => {
    const kept = jq(
      CWD_CACHE,
      [
        { cwd: "/repo/fallback", repositoryID: "folder:/repo/fallback" },
        {
          cwd: "/repo/stable",
          repositoryID: "github.com/owner/stable",
          repositoryFingerprint: "stable-fingerprint",
        },
      ]
        .map((entry) => JSON.stringify(entry))
        .join("\n"),
      [
        "--arg",
        "want",
        "/repo/fallback\n/repo/stable\n",
        "--argjson",
        "fingerprints",
        '[{"/repo/fallback":{"verified":false,"fingerprint":""},"/repo/stable":{"verified":true,"fingerprint":"stable-fingerprint"}}]',
      ],
    );
    expect(kept).toEqual([
      {
        cwd: "/repo/stable",
        repositoryID: "github.com/owner/stable",
        repositoryFingerprint: "stable-fingerprint",
      },
    ]);
    expect(script).toContain('cp "$TMP/cwdmap.jsonl" "$CWDMAP_CACHE"');
  });

  test("cached GitHub identity is discarded when the current origin changes", () => {
    const kept = jq(
      CWD_CACHE,
      JSON.stringify({
        cwd: "/repo/app",
        repositoryID: "github.com/old/fork",
        repositoryFingerprint: "old-remotes",
      }),
      [
        "--arg",
        "want",
        "/repo/app\n",
        "--argjson",
        "fingerprints",
        '[{"/repo/app":{"verified":true,"fingerprint":"current-remotes"}}]',
      ],
    );
    expect(kept).toEqual([]);
    const [currentID] = jq(
      `${GITHUB} githubRepositoryID`,
      JSON.stringify("git@github.com:current/origin.git"),
    );
    expect(currentID).toBe("github.com/current/origin");
    expect(script).toContain('CWDMAP_CACHE="$EDCACHE/.cwdmap.v5.jsonl"');
    expect(script).toContain(
      "git_quick -C \"$git_probe\" config --get-regexp '^remote\\..*\\.url$'",
    );
  });

  test("deleted worktree retains its cached GitHub identity", () => {
    const cached = {
      cwd: "/repo/deleted-worktree",
      repositoryID: "github.com/owner/repository",
      repositoryName: "repository",
    };
    const kept = jq(CWD_CACHE, JSON.stringify(cached), [
      "--arg",
      "want",
      "/repo/deleted-worktree\n",
      "--argjson",
      "fingerprints",
      '[{"/repo/deleted-worktree":{"verified":false,"fingerprint":""}}]',
    ]);
    expect(kept).toEqual([cached]);
    expect(script).toContain('cp "$LEGACY_CWDMAP_CACHE" "$CWDMAP_CACHE"');
  });

  test("existing non-Git folder discards its stale GitHub identity", () => {
    const kept = jq(
      CWD_CACHE,
      JSON.stringify({
        cwd: "/repo/plain-folder",
        repositoryID: "github.com/owner/old-repository",
      }),
      [
        "--arg",
        "want",
        "/repo/plain-folder\n",
        "--argjson",
        "fingerprints",
        '[{"/repo/plain-folder":{"verified":true,"fingerprint":"plain-folder"}}]',
      ],
    );
    expect(kept).toEqual([]);
  });

  test("first v5 refresh imports a deleted worktree identity from v4", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      legacyDeletedWorktree: true,
    });
    expect(result.exitCode).toBe(0);
    const report = JSON.parse(result.output);
    expect(report.daily[0].projects).toHaveLength(1);
    expect(report.daily[0].projects[0].repositoryID).toBe(
      "github.com/owner/repository",
    );
    expect(report.daily[0].projects[0].path).toBe(result.deletedCwd);
  }, 15_000);

  test("deleted worktree resolves through its live base repository", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      deletedWorktreeBaseRepository: true,
    });
    expect(result.exitCode).toBe(0);
    const report = JSON.parse(result.output);
    const project = report.daily[0].projects[0];
    expect(project.repositoryID).toBe("github.com/owner/repository");
    expect(project.repositoryURL).toBe("https://github.com/owner/repository");
    expect(project.path).toBe(
      result.deletedCwd.split("/.claude/worktrees/")[0],
    );
  }, 15_000);

  test("normalizes common GitHub remote forms to one stable ID", () => {
    const [ids] = jq(
      `${GITHUB} map(githubRepositoryID)`,
      JSON.stringify([
        "git@github.com:PulkitXM/Edith.git",
        "ssh://git@github.com/PulkitXM/Edith.git",
        "https://github.com/PulkitXM/Edith.git",
        "https://token@github.com/PulkitXM/Edith.git",
        "git://github.com/PulkitXM/Edith.git",
        "https://gitlab.com/PulkitXM/Edith.git",
      ]),
    );
    expect(ids).toEqual([
      "github.com/pulkitxm/edith",
      "github.com/pulkitxm/edith",
      "github.com/pulkitxm/edith",
      "github.com/pulkitxm/edith",
      "github.com/pulkitxm/edith",
      "",
    ]);
  });

  test("keeps same-repository folders flat with exact source and model detail", () => {
    const usage = localDoc({
      sources: ["cli", "commandcode", "codex", "amp"],
      defaultSources: ["cli", "commandcode", "codex", "amp"],
      daily: [
        {
          period: "2026-08-07",
          bySource: { cli: [], commandcode: [], codex: [], amp: [] },
        },
      ],
    });
    const mappings = {
      "/laptop/edith": {
        cwd: "/laptop/edith",
        root: "/laptop/edith",
        repositoryID: "github.com/pulkitxm/edith",
        repositoryName: "edith",
        repositoryURL: "https://github.com/pulkitxm/edith",
        folderName: "laptop-clone",
      },
      "/tuf/edith": {
        cwd: "/tuf/edith",
        root: "/tuf/edith",
        repositoryID: "github.com/pulkitxm/edith",
        repositoryName: "edith",
        repositoryURL: "https://github.com/pulkitxm/edith",
        folderName: "tuf-clone",
      },
      "/laptop/edith/.claude/worktrees/feature/src": {
        cwd: "/laptop/edith/.claude/worktrees/feature/src",
        root: "/laptop/edith",
        repositoryID: "github.com/pulkitxm/edith",
        repositoryName: "edith",
        repositoryURL: "https://github.com/pulkitxm/edith",
        folderName: "laptop-clone",
      },
    };
    const record = (over) => ({
      id: over.sid,
      date: "2026-08-07",
      hour: 9,
      ts: 1,
      model: "opus",
      cwd: "/laptop/edith",
      wt: null,
      sid: "s1",
      src: "cli",
      inp: 0,
      out: 0,
      cc: 0,
      cr: 0,
      tok: 10,
      cost: 1,
      ...over,
    });
    const records = [
      record({ sid: "s1" }),
      record({
        sid: "s2",
        src: "commandcode",
        model: "deepseek",
        tok: 20,
        cost: 2,
      }),
      record({
        sid: "s3",
        cwd: "/tuf/edith",
        hour: 10,
        model: "sonnet",
        tok: 30,
        cost: 3,
      }),
      record({
        sid: "s4",
        cwd: "/laptop/edith/.claude/worktrees/feature/src",
        wt: "feature",
        hour: 11,
        model: "haiku",
        tok: 5,
        cost: 0.5,
      }),
    ];
    const [out] = jq(DETAILS, JSON.stringify(records), [
      "--argjson",
      "usage",
      JSON.stringify([usage]),
      "--argjson",
      "titles",
      JSON.stringify([{}]),
      "--argjson",
      "cm",
      JSON.stringify([mappings]),
    ]);
    expect(out.schemaVersion).toBe(7);
    expect(out.daily[0].projects).toHaveLength(2);
    expect(
      out.daily[0].projects.map((project) => project.repositoryID),
    ).toEqual(["github.com/pulkitxm/edith", "github.com/pulkitxm/edith"]);
    const laptop = out.daily[0].projects.find(
      (project) => project.folderName === "laptop-clone",
    );
    expect(laptop.bySource.cli).toEqual({
      tokens: 15,
      cost: 1.5,
      byModel: {
        haiku: { tokens: 5, cost: 0.5 },
        opus: { tokens: 10, cost: 1 },
      },
    });
    expect(laptop.bySource.commandcode.byModel.deepseek).toEqual({
      tokens: 20,
      cost: 2,
    });
    expect(out.daily[0].hours).toHaveLength(24);
    expect(out.daily[0].hours[9].tokens).toBe(30);
    expect(out.daily[0].hours[9].bySource.cli.byModel.opus).toEqual({
      tokens: 10,
      cost: 1,
    });
    expect(out.daily[0].hours[9].bySource.commandcode.byModel.deepseek).toEqual(
      { tokens: 20, cost: 2 },
    );
    expect(out.daily[0].hours[9].byPath["/laptop/edith"]).toEqual({
      tokens: 30,
      cost: 3,
      bySource: {
        cli: {
          tokens: 10,
          cost: 1,
          byModel: { opus: { tokens: 10, cost: 1 } },
        },
        commandcode: {
          tokens: 20,
          cost: 2,
          byModel: { deepseek: { tokens: 20, cost: 2 } },
        },
      },
    });
    expect(out.daily[0].hours[10].byPath["/tuf/edith"].tokens).toBe(30);
    const nestedPath = "/laptop/edith/.claude/worktrees/feature/src";
    expect(out.daily[0].hours[11].byPath[nestedPath]).toEqual({
      tokens: 5,
      cost: 0.5,
      bySource: {
        cli: {
          tokens: 5,
          cost: 0.5,
          byModel: { haiku: { tokens: 5, cost: 0.5 } },
        },
      },
    });
    expect(
      out.daily[0].hours.some(
        (hour) =>
          Object.hasOwn(hour.bySource, "amp") ||
          Object.hasOwn(hour.bySource, "codex"),
      ),
    ).toBeFalse();
  });
});

const fleet = (docs) =>
  jq(FLEET, docs.map((d) => JSON.stringify(d)).join("\n"), ["-s"])[0];

const tufPrefix = "machine:11111111-1111-1111-1111-111111111111:";
const tufCLI = "machine:11111111-1111-1111-1111-111111111111:cli";
const tufCodex = "machine:11111111-1111-1111-1111-111111111111:codex";
const piPrefix = "machine:22222222-2222-2222-2222-222222222222:";
const piCLI = "machine:22222222-2222-2222-2222-222222222222:cli";

describe("FLEET", () => {
  test("machine sources are namespaced and labelled with the machine", () => {
    const out = fleet([localDoc(), machineDoc()]);
    expect(out.sources).toEqual(["cli", tufCLI, tufCodex]);
    expect(out.defaultSources).toEqual(["cli", tufCLI, tufCodex]);
    expect(out.sourceMeta[tufCLI].label).toBe("Claude Code · tuf");
    expect(out.sourceMeta[tufCLI].machine).toBe("tuf");
    expect(out.sourceMeta[tufCLI].machineHost).toBe("tuf.local");
    expect(out.sourceMeta.cli.label).toBe("Claude Code");
  });

  test("machine source identity survives a machine rename", () => {
    const renamed = machineDoc({
      machine: {
        id: "11111111-1111-1111-1111-111111111111",
        name: "studio",
        slug: "studio",
        host: "studio.local",
        collectedAt: "2026-08-08T09:05:00Z",
      },
    });
    const out = fleet([localDoc(), renamed]);
    expect(out.sources).toEqual(["cli", tufCLI, tufCodex]);
    expect(out.sourceMeta[tufCLI].label).toBe("Claude Code · studio");
    expect(out.sourceMeta[tufCLI].machineID).toBe(
      "11111111-1111-1111-1111-111111111111",
    );
    expect(out.daily[0].projects[1].path).toBe(`${tufPrefix}/home/p/edith`);
  });

  test("same-name machines keep distinct source identities", () => {
    const other = machineDoc({
      machine: {
        id: "22222222-2222-2222-2222-222222222222",
        name: "tuf",
        slug: "tuf",
        host: "other.local",
        collectedAt: "2026-08-08T09:06:00Z",
      },
    });
    const out = fleet([localDoc(), machineDoc(), other]);
    expect(out.sources).toContain(tufCLI);
    expect(out.sources).toContain(piCLI);
    expect(tufCLI).not.toBe(piCLI);
    expect(Object.keys(out.daily[0].hours[0].byPath)).toContain(
      `${tufPrefix}/home/p/edith/.claude/worktrees/wt/sub`,
    );
    expect(Object.keys(out.daily[0].hours[0].byPath)).toContain(
      `${piPrefix}/home/p/edith/.claude/worktrees/wt/sub`,
    );
  });

  test("machine sources without a machine ID are rejected", () => {
    const doc = machineDoc();
    doc.machine.id = "";
    expect(
      jqExit(
        FLEET,
        [localDoc(), doc].map((value) => JSON.stringify(value)).join("\n"),
        ["-s"],
      ),
    ).not.toBe(0);
  });

  test("empty machine snapshot without a machine ID is rejected", () => {
    const doc = machineDoc({
      sources: [],
      defaultSources: [],
      daily: [],
      sessions: [],
    });
    doc.machine.id = "";
    expect(
      jqExit(
        FLEET,
        [localDoc(), doc].map((value) => JSON.stringify(value)).join("\n"),
        ["-s"],
      ),
    ).not.toBe(0);
  });

  test("numeric machine ID is rejected before fleet output", () => {
    const doc = machineDoc();
    doc.machine.id = 123;
    expect(
      jqExit(
        FLEET,
        [localDoc(), doc].map((value) => JSON.stringify(value)).join("\n"),
        ["-s"],
      ),
    ).not.toBe(0);
  });

  test("a day seen on both sides keeps one row with both sides' sources", () => {
    const out = fleet([localDoc(), machineDoc()]);
    expect(out.daily).toHaveLength(1);
    expect(Object.keys(out.daily[0].bySource).sort()).toEqual(["cli", tufCLI]);
    expect(out.daily[0].hours).toHaveLength(24);
    expect(out.daily[0].hours[0]).toEqual({
      tokens: 103,
      cost: 3,
      bySource: {
        cli: {
          tokens: 100,
          cost: 1,
          byModel: { opus: { tokens: 100, cost: 1 } },
        },
        [tufCLI]: {
          tokens: 3,
          cost: 2,
          byModel: { opus: { tokens: 3, cost: 2 } },
        },
      },
      byPath: {
        "/Users/p/edith": {
          tokens: 100,
          cost: 1,
          bySource: {
            cli: {
              tokens: 100,
              cost: 1,
              byModel: { opus: { tokens: 100, cost: 1 } },
            },
          },
        },
        [`${tufPrefix}/home/p/edith/.claude/worktrees/wt/sub`]: {
          tokens: 3,
          cost: 2,
          bySource: {
            [tufCLI]: {
              tokens: 3,
              cost: 2,
              byModel: { opus: { tokens: 3, cost: 2 } },
            },
          },
        },
      },
    });
    expect(Object.keys(out.daily[0].hours[0].byPath).sort()).toEqual([
      "/Users/p/edith",
      `${tufPrefix}/home/p/edith/.claude/worktrees/wt/sub`,
    ]);
    expect(
      out.daily[0].hours[0].byPath[
        `${tufPrefix}/home/p/edith/.claude/worktrees/wt/sub`
      ].bySource[tufCLI].byModel.opus.tokens,
    ).toBe(3);
  });

  test("machine projects and chats stay separable from the local ones", () => {
    const out = fleet([localDoc(), machineDoc()]);
    const projects = out.daily[0].projects;
    expect(projects.map((p) => p.projectName)).toEqual(["edith", "edith"]);
    expect(projects.map((p) => p.repositoryID)).toEqual([
      "github.com/pulkitxm/edith",
      "github.com/pulkitxm/edith",
    ]);
    expect(projects[1].folderName).toBe("edith-tuf");
    expect(projects[1].path).toBe(`${tufPrefix}/home/p/edith`);
    expect(projects[1].machineName).toBe("tuf");
    expect(projects[1].machineID).toBe("11111111-1111-1111-1111-111111111111");
    expect(projects[1].chats[0].path).toBe(`${tufPrefix}/home/p/edith`);
    expect(projects[1].chats[0].source).toBe(tufCLI);
    expect(projects[1].worktrees).toEqual([]);
    expect(Object.keys(projects[1].bySource)).toEqual([tufCLI]);
  });

  test("stored remote Codex detail stays unavailable", () => {
    const doc = machineDoc();
    doc.daily[0].bySource.codex = [
      {
        modelName: "gpt",
        inputTokens: 5,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        cost: 1,
      },
    ];
    doc.daily[0].hours[0].tokens += 5;
    doc.daily[0].hours[0].cost += 1;
    doc.daily[0].hours[0].bySource.codex = {
      tokens: 5,
      cost: 1,
      byModel: { gpt: { tokens: 5, cost: 1 } },
    };
    doc.daily[0].hours[0].byPath["/home/p/codex"] = {
      tokens: 5,
      cost: 1,
      bySource: {
        codex: {
          tokens: 5,
          cost: 1,
          byModel: { gpt: { tokens: 5, cost: 1 } },
        },
      },
    };
    doc.daily[0].projects.push({
      projectName: "codex-only",
      repositoryID: "github.com/owner/codex-only",
      repositoryName: "codex-only",
      repositoryURL: "https://github.com/owner/codex-only",
      folderName: "codex-only",
      path: "/home/p/codex",
      tokens: 5,
      cost: 1,
      bySource: {
        codex: {
          tokens: 5,
          cost: 1,
          byModel: { gpt: { tokens: 5, cost: 1 } },
        },
      },
      chats: [{ id: "c10", source: "codex", tokens: 5, cost: 1 }],
      worktrees: [],
    });
    const out = fleet([localDoc(), doc]);
    const remoteDay = out.daily[0];
    expect(remoteDay.bySource[tufCodex][0].inputTokens).toBe(5);
    expect(remoteDay.hours[0].tokens).toBe(103);
    expect(remoteDay.hours[0].bySource[tufCodex]).toBeUndefined();
    expect(
      remoteDay.hours[0].byPath[`${tufPrefix}/home/p/codex`],
    ).toBeUndefined();
    expect(remoteDay.projects.map((project) => project.projectName)).toEqual([
      "edith",
      "edith",
    ]);
    expect(remoteDay.projects[1].tokens).toBe(3);
    expect(remoteDay.projects[1].worktrees).toEqual([]);
    expect(out.totals.tokens).toBe(108);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("machine-qualifies fallback folder repository IDs", () => {
    const doc = machineDoc();
    delete doc.daily[0].projects[0].repositoryID;
    delete doc.daily[0].projects[0].repositoryName;
    delete doc.daily[0].projects[0].repositoryURL;
    const out = fleet([localDoc(), doc]);
    expect(out.daily[0].projects[1].repositoryID).toBe(
      `${tufPrefix}folder:/home/p/edith`,
    );
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
        sources: [tufCLI, tufCodex],
      },
    ]);
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(0);
  });

  test("validation rejects an inconsistent hour total", () => {
    const out = fleet([localDoc(), machineDoc()]);
    out.daily[0].hours[0].tokens += 1;
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(1);
  });

  test("validation rejects an inconsistent path total", () => {
    const out = fleet([localDoc(), machineDoc()]);
    out.daily[0].hours[0].byPath["/Users/p/edith"].cost += 1;
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(1);
  });

  test("validation rejects an inconsistent project total", () => {
    const out = fleet([localDoc(), machineDoc()]);
    out.daily[0].projects[0].tokens += 1;
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(1);
  });

  test("validation rejects a negative nested model total", () => {
    const out = fleet([localDoc(), machineDoc()]);
    out.daily[0].hours[0].bySource.cli.byModel.opus.tokens = -1;
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(1);
  });

  test("validation rejects an inconsistent nested source cost", () => {
    const out = fleet([localDoc(), machineDoc()]);
    out.daily[0].projects[0].bySource.cli.cost += 1;
    expect(jqExit(VALIDATE, JSON.stringify(out))).toBe(1);
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
    expect(Object.keys(out.daily[0].bySource)).toEqual([piCLI]);
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

describe("collector failure handling", () => {
  test("nonzero Claude daily collection preserves the existing report", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      failClaudeDaily: true,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toContain("cli daily collection failed");
    expect(result.output).toBe(result.existing);
  }, 15_000);

  test("malformed Claude daily collection preserves the existing report", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      malformedClaudeDaily: true,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toContain("cli daily usage is malformed");
    expect(result.output).toBe(result.existing);
  }, 15_000);

  test("normalization failure preserves the existing report", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      failNormalization: true,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toContain("cli usage normalization failed");
    expect(result.output).toBe(result.existing);
  }, 15_000);

  test("malformed machine JSON preserves the existing report", () => {
    const result = runCollectorFixture({
      hasLocalUsage: false,
      machineJSON: '{"machine":',
      failDetails: false,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toContain("machine snapshot assembly failed");
    expect(result.output).toBe(result.existing);
  }, 15_000);

  test("detail assembly failure preserves the existing report", () => {
    const result = runCollectorFixture({
      hasLocalUsage: true,
      failDetails: true,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toContain("detail assembly failed");
    expect(result.output).toBe(result.existing);
  }, 15_000);
});

describe("collector configuration", () => {
  test("uses one pinned ccusage version for bun and npx", () => {
    expect(script).toContain('CCUSAGE_VERSION="20.0.19"');
    expect(script).toContain('bun add --exact "ccusage@$CCUSAGE_VERSION"');
    expect(script).toContain('npx -y "ccusage@$CCUSAGE_VERSION"');
  });

  test("limits Codex discovery to sessions and archived sessions", () => {
    expect(script).toContain('CODEX_CFG="$TMP/codex-home"');
    expect(script).toContain("for dir in sessions archived_sessions; do");
    expect(script).toContain(
      'CODEX_HOME="$CODEX_CFG" ccu codex daily --json --offline',
    );
    expect(script).not.toContain(
      "for agent in codex opencode amp droid codebuff hermes pi goose kilo",
    );
    expect(script).toContain(
      'walk_dir "$HOME/.pi/agent/sessions" pi "$WALKPI"',
    );
  });

  test("resolves repository remotes and physical worktree roots deterministically", () => {
    expect(script).toContain(
      "for remote in origin upstream $(printf '%s\\n' \"$remaining_remotes\" | LC_ALL=C sort); do",
    );
    expect(script).not.toContain(
      "for remote in upstream origin $(printf '%s\\n' \"$remaining_remotes\" | LC_ALL=C sort); do",
    );
    expect(script).toContain(
      'git_root=$(git_quick -C "$git_probe" rev-parse --path-format=absolute --show-toplevel',
    );
    expect(script).not.toContain("--git-common-dir");
  });

  test("provides readable labels for every discovered provider", () => {
    const labels = {
      cli: "Claude Code",
      cowork: "Cowork",
      codex: "Codex",
      opencode: "OpenCode",
      commandcode: "Command Code",
      amp: "Amp",
      droid: "Droid",
      codebuff: "Codebuff",
      hermes: "Hermes",
      pi: "pi-agent",
      goose: "Goose",
      kilo: "Kilo",
      copilot: "GitHub Copilot",
      gemini: "Gemini",
      kimi: "Kimi",
      qwen: "Qwen",
      openclaw: "OpenClaw",
    };
    for (const [source, label] of Object.entries(labels)) {
      expect(script).toContain(`${source}) echo "${label}" ;;`);
    }
  });
});
