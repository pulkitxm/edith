import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

const dataUrl = new URL("../data/usage.json", import.meta.url);

if (!existsSync(dataUrl)) {
  test.skip("dashboard smoke (needs local dashboard/data/usage.json)", () => {});
} else {
  const usage = readFileSync(dataUrl, "utf8");
  globalThis.document = {
    getElementById: (id) =>
      id === "usage-data" ? { textContent: usage } : null,
  };
  globalThis.matchMedia = () => ({ matches: false });

  const data = await import("../js/data.js");
  const { state } = await import("../js/state.js");
  const compute = await import("../js/compute.js");

  const sumCost = (rows) => rows.reduce((a, r) => a + r.cost, 0);
  const ccSources = data.SOURCES.filter(
    (s) => data.SOURCE_TOOL[s] === "Claude Code",
  );

  test("data.js: sources, tool grouping, and Claude-Code default come from the payload", () => {
    expect(data.SOURCES).toEqual(expect.arrayContaining(["cli", "opencode"]));
    expect(data.DEFAULT_SOURCES).toEqual(ccSources);
    expect(ccSources).toEqual(expect.arrayContaining(["cli", "cowork"]));
    expect(data.SOURCE_TOOL.opencode).toBe("OpenCode");
    expect(data.SOURCE_TOOL.cowork).toBe("Claude Code");
    expect(data.sourceLabel("cli")).toBe("Claude Code");
  });

  test("default filter is Claude Code only; derive() excludes opencode/codex spend", () => {
    expect([...state.sources].sort()).toEqual([...ccSources].sort());
    state.range = { mode: "all" };
    const claudeOnly = ccSources.reduce(
      (a, s) => a + (data.RAW.totals.bySource[s]?.cost || 0),
      0,
    );
    expect(sumCost(compute.derive())).toBeCloseTo(claudeOnly, 1);
  });

  test("drilldown chats carry a source tag (so the project tree can filter by source)", () => {
    const chats = data.DAILY.flatMap((d) =>
      (d.projects || []).flatMap((p) =>
        (p.chats || []).concat(
          (p.worktrees || []).flatMap((w) => w.chats || []),
        ),
      ),
    );
    const tagged = chats.filter((c) => c.source);
    expect(tagged.length).toBeGreaterThan(0);
    for (const c of tagged) expect(data.SOURCES).toContain(c.source);
    expect(chats.some((c) => c.source === "cc-cloud")).toBe(true);
  });

  test("enabling every source reconciles to the grand total (opencode included)", () => {
    state.sources = new Set(data.SOURCES);
    state.models = new Set(data.ALL_MODELS);
    expect(sumCost(compute.derive())).toBeCloseTo(data.RAW.totals.cost, 0);
  });
}
