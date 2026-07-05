import { expect, test } from "bun:test";
import { claudeCodeSources, metaFor, normalizeAgentDaily } from "../merge.mjs";

test("normalizeAgentDaily: claude/opencode modelBreakdowns[] pass through with per-model cost", () => {
  const { period, breakdowns } = normalizeAgentDaily({
    date: "2026-06-11",
    modelBreakdowns: [
      {
        modelName: "gpt-5.5",
        inputTokens: 10,
        outputTokens: 5,
        cacheCreationTokens: 0,
        cacheReadTokens: 100,
        cost: 1.5,
      },
      {
        modelName: "claude-opus-4-8",
        inputTokens: 2,
        outputTokens: 3,
        cacheCreationTokens: 1,
        cacheReadTokens: 4,
        cost: 0.25,
      },
    ],
  });
  expect(period).toBe("2026-06-11");
  expect(breakdowns).toHaveLength(2);
  expect(breakdowns[0]).toEqual({
    modelName: "gpt-5.5",
    inputTokens: 10,
    outputTokens: 5,
    cacheCreationTokens: 0,
    cacheReadTokens: 100,
    cost: 1.5,
  });
  expect(breakdowns[1].cost).toBe(0.25);
});

test("normalizeAgentDaily: codex models{}+costUSD splits row cost by token share, folds reasoning into output", () => {
  const { period, breakdowns } = normalizeAgentDaily({
    date: "2026-06-09",
    costUSD: 0.022311,
    models: {
      "gpt-5.5": {
        inputTokens: 3349,
        outputTokens: 17,
        reasoningOutputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 10112,
      },
    },
  });
  expect(period).toBe("2026-06-09");
  expect(breakdowns).toHaveLength(1);
  const b = breakdowns[0];
  expect(b.modelName).toBe("gpt-5.5");
  expect(b.cost).toBeCloseTo(0.022311, 10);
  expect(b.outputTokens).toBe(17);
});

test("normalizeAgentDaily: codex multi-model splits cost proportionally by tokens", () => {
  const { breakdowns } = normalizeAgentDaily({
    date: "2026-06-09",
    costUSD: 3.0,
    models: {
      a: { inputTokens: 100 },
      b: { inputTokens: 200 },
    },
  });
  const byName = Object.fromEntries(
    breakdowns.map((b) => [b.modelName, b.cost]),
  );
  expect(byName.a).toBeCloseTo(1.0, 10);
  expect(byName.b).toBeCloseTo(2.0, 10);
});

test("normalizeAgentDaily: reasoning tokens fold into output", () => {
  const { breakdowns } = normalizeAgentDaily({
    period: "2026-06-09",
    models: { m: { outputTokens: 10, reasoningOutputTokens: 7 } },
    costUSD: 0,
  });
  expect(breakdowns[0].outputTokens).toBe(17);
});

test("normalizeAgentDaily: opencode row-level tokens + modelsUsed → single model gets full row", () => {
  const { period, breakdowns } = normalizeAgentDaily({
    date: "2026-06-09",
    inputTokens: 88694,
    outputTokens: 7886,
    cacheCreationTokens: 0,
    cacheReadTokens: 402432,
    totalCost: 0.950326,
    modelsUsed: ["gpt-5.5"],
  });
  expect(period).toBe("2026-06-09");
  expect(breakdowns).toHaveLength(1);
  expect(breakdowns[0]).toEqual({
    modelName: "gpt-5.5",
    inputTokens: 88694,
    outputTokens: 7886,
    cacheCreationTokens: 0,
    cacheReadTokens: 402432,
    cost: 0.950326,
  });
});

test("normalizeAgentDaily: opencode multi-model day splits row tokens+cost equally", () => {
  const { breakdowns } = normalizeAgentDaily({
    date: "2026-06-11",
    inputTokens: 100,
    outputTokens: 20,
    cacheCreationTokens: 0,
    cacheReadTokens: 80,
    totalCost: 18,
    modelsUsed: ["gpt-5.5", "claude-opus-4-8"],
  });
  expect(breakdowns).toHaveLength(2);
  for (const b of breakdowns) {
    expect(b.inputTokens).toBe(50);
    expect(b.cacheReadTokens).toBe(40);
    expect(b.cost).toBe(9);
  }
});

test("claudeCodeSources: groups cli+cc-cloud+cowork, excludes other agents", () => {
  expect(
    claudeCodeSources(["cli", "cc-cloud", "cowork", "opencode", "codex"]),
  ).toEqual(["cli", "cc-cloud", "cowork"]);
  expect(metaFor("opencode").tool).toBe("OpenCode");
  expect(metaFor("cowork").tool).toBe("Claude Code");
  expect(metaFor("cc-cloud")).toEqual({
    label: "Claude Code Cloud",
    tool: "Claude Code",
  });
  expect(metaFor("unknownagent")).toEqual({
    label: "Unknownagent",
    tool: "Unknownagent",
  });
});
