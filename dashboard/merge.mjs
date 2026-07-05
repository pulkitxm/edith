export const tokensOf = (b) =>
  (+b.inputTokens || 0) +
  (+b.outputTokens || 0) +
  (+b.cacheCreationTokens || 0) +
  (+b.cacheReadTokens || 0);

const tokensOfModelObj = (m) =>
  (+m.inputTokens || 0) +
  (+m.outputTokens || 0) +
  (+m.reasoningOutputTokens || 0) +
  (+m.cacheCreationTokens || 0) +
  (+m.cacheReadTokens || 0);

const breakdown = (modelName, m, cost) => ({
  modelName,
  inputTokens: +m.inputTokens || 0,
  outputTokens: (+m.outputTokens || 0) + (+m.reasoningOutputTokens || 0),
  cacheCreationTokens: +m.cacheCreationTokens || 0,
  cacheReadTokens: +m.cacheReadTokens || 0,
  cost: +cost || 0,
});

export function normalizeAgentDaily(row) {
  const period = row.period || row.date;
  let breakdowns = [];

  if (Array.isArray(row.modelBreakdowns)) {
    breakdowns = row.modelBreakdowns.map((b) =>
      breakdown(b.modelName, b, b.cost),
    );
  } else if (row.models && typeof row.models === "object") {
    const entries = Object.entries(row.models);
    const rowCost = +row.totalCost || +row.costUSD || 0;
    const totalTok =
      entries.reduce((a, [, m]) => a + tokensOfModelObj(m), 0) || 1;
    breakdowns = entries.map(([name, m]) =>
      breakdown(name, m, (rowCost * tokensOfModelObj(m)) / totalTok),
    );
  } else if (Array.isArray(row.modelsUsed) && row.modelsUsed.length) {
    const names = row.modelsUsed;
    const n = names.length;
    const rowCost = (+row.totalCost || +row.costUSD || 0) / n;
    const share = (v) => (+v || 0) / n;
    breakdowns = names.map((name) =>
      breakdown(
        name,
        {
          inputTokens: share(row.inputTokens),
          outputTokens: share(row.outputTokens),
          cacheCreationTokens: share(row.cacheCreationTokens),
          cacheReadTokens: share(row.cacheReadTokens),
        },
        rowCost,
      ),
    );
  }
  return { period, breakdowns };
}

export const SOURCE_META = {
  cli: { label: "Claude Code", tool: "Claude Code" },
  "cc-cloud": { label: "Claude Code Cloud", tool: "Claude Code" },
  cowork: { label: "Cowork", tool: "Claude Code" },
  opencode: { label: "OpenCode", tool: "OpenCode" },
  codex: { label: "Codex", tool: "Codex" },
  copilot: { label: "Copilot", tool: "Copilot" },
  gemini: { label: "Gemini CLI", tool: "Gemini CLI" },
  amp: { label: "Amp", tool: "Amp" },
  droid: { label: "Droid", tool: "Droid" },
  goose: { label: "Goose", tool: "Goose" },
  kilo: { label: "Kilo", tool: "Kilo" },
  qwen: { label: "Qwen", tool: "Qwen" },
  kimi: { label: "Kimi", tool: "Kimi" },
};

export const metaFor = (s) =>
  SOURCE_META[s] || {
    label: s.charAt(0).toUpperCase() + s.slice(1),
    tool: s.charAt(0).toUpperCase() + s.slice(1),
  };

export const claudeCodeSources = (sources) =>
  sources.filter((s) => metaFor(s).tool === "Claude Code");
