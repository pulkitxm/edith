import { expect, test } from "bun:test";
import { statsSummary } from "../js/stats.js";

const rows = [
  {
    date: "2026-05-26",
    cost: 1,
    input: 100,
    output: 50,
    cacheCreate: 200,
    cacheRead: 300,
    tokens: 650,
    byModel: { "claude-opus-4-8": { cost: 1, tokens: 650 } },
  },
  {
    date: "2026-05-27",
    cost: 0,
    input: 0,
    output: 0,
    cacheCreate: 0,
    cacheRead: 0,
    tokens: 0,
    byModel: {},
  },
  {
    date: "2026-05-28",
    cost: 3,
    input: 100,
    output: 10,
    cacheCreate: 0,
    cacheRead: 100,
    tokens: 210,
    byModel: { "claude-haiku-4-5": { cost: 3, tokens: 210 } },
  },
];

test("statsSummary: totals and token breakdown", () => {
  const s = statsSummary(rows);
  expect(s.totalCost).toBe(4);
  expect(s.totalTokens).toBe(860);
  expect(s.input).toBe(200);
  expect(s.output).toBe(60);
  expect(s.cacheCreate).toBe(200);
  expect(s.cacheRead).toBe(400);
  expect(s.cache).toBe(600);
});

test("statsSummary: cacheRate = read/(read+input)", () => {
  expect(statsSummary(rows).cacheRate).toBeCloseTo(400 / 600, 10);
});

test("statsSummary: activeDays ignores zero-token days; dailyAvg = cost/activeDays", () => {
  const s = statsSummary(rows);
  expect(s.activeDays).toBe(2);
  expect(s.dailyAvg).toBe(2);
});

test("statsSummary: topModel by summed cost; peakDay by tokens", () => {
  const s = statsSummary(rows);
  expect(s.topModel).toBe("claude-haiku-4-5");
  expect(s.peakDay).toEqual({ date: "2026-05-26", tokens: 650, cost: 1 });
});

test("statsSummary: all-zero and empty -> safe zeros, null topModel/peakDay", () => {
  const z = statsSummary([
    {
      date: "2026-05-26",
      cost: 0,
      input: 0,
      output: 0,
      cacheCreate: 0,
      cacheRead: 0,
      tokens: 0,
      byModel: {},
    },
  ]);
  expect(z.totalCost).toBe(0);
  expect(z.cacheRate).toBe(0);
  expect(z.dailyAvg).toBe(0);
  expect(z.activeDays).toBe(0);
  expect(z.topModel).toBeNull();
  expect(z.peakDay).toBeNull();
  const e = statsSummary([]);
  expect(e.topModel).toBeNull();
  expect(e.peakDay).toBeNull();
});
