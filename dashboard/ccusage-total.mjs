#!/usr/bin/env bun

import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CLI_CONFIG = join(homedir(), ".claude");
const COWORK_ROOT = join(
  homedir(),
  "Library",
  "Application Support",
  "Claude",
  "local-agent-mode-sessions",
);

function findCoworkConfigDirs() {
  const out = [];
  const walk = (dir, depth) => {
    if (depth > 8) return;
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (!e.isDirectory()) continue;
      if (e.name === ".claude") {
        out.push(join(dir, e.name));
        continue;
      }
      walk(join(dir, e.name), depth + 1);
    }
  };
  walk(COWORK_ROOT, 0);
  return out;
}

const COWORK_DIRS = findCoworkConfigDirs();
const CONFIG_DIRS = [CLI_CONFIG, ...COWORK_DIRS];
const PROJECTS_DIRS = CONFIG_DIRS.map((c) => join(c, "projects"));
const CCUSAGE_ENV = {
  ...process.env,
  CLAUDE_CONFIG_DIR: CONFIG_DIRS.join(","),
};

const SOURCES = [
  { key: "code", dirs: [CLI_CONFIG] },
  ...(COWORK_DIRS.length ? [{ key: "cowork", dirs: COWORK_DIRS }] : []),
];

const wantJson = Bun.argv.includes("--json");
const todayOnly = Bun.argv.includes("--today");
const dayWise =
  Bun.argv.includes("--day-wise") || Bun.argv.includes("--daywise");

function localDateStr(d = new Date()) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function fetchCcusage(period, dirs = CONFIG_DIRS) {
  const env = { ...process.env, CLAUDE_CONFIG_DIR: dirs.join(",") };
  const proc = Bun.spawnSync(
    ["bunx", "ccusage@latest", period, "--breakdown", "--json"],
    { stdout: "pipe", stderr: "pipe", env },
  );
  if (proc.exitCode !== 0) {
    const err = proc.stderr.toString().trim();
    throw new Error(
      `ccusage ${period} failed (exit ${proc.exitCode}):\n${err}`,
    );
  }
  return JSON.parse(proc.stdout.toString());
}

function fetchSessionData() {
  const proc = Bun.spawnSync(["bunx", "ccusage@latest", "session", "--json"], {
    stdout: "pipe",
    stderr: "pipe",
    env: CCUSAGE_ENV,
  });
  if (proc.exitCode !== 0) {
    throw new Error(
      `ccusage session failed:\n${proc.stderr.toString().trim()}`,
    );
  }
  return JSON.parse(proc.stdout.toString());
}

const FALLBACK_PRICE_PER_MTOK = {
  "claude-fable-5": [10, 50, 12.5, 1],
  "claude-opus-4-8": [5, 25, 6.25, 0.5],
  "claude-opus-4-7": [5, 25, 6.25, 0.5],
  "claude-sonnet-4-6": [3, 15, 3.75, 0.3],
  "claude-haiku-4-5-20251001": [1, 5, 1.25, 0.1],
};

function leastSquares4(rows) {
  const M = [
    [0, 0, 0, 0],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
    [0, 0, 0, 0],
  ];
  const v = [0, 0, 0, 0];
  for (const { x, y } of rows) {
    for (let i = 0; i < 4; i++) {
      v[i] += x[i] * y;
      for (let j = 0; j < 4; j++) M[i][j] += x[i] * x[j];
    }
  }
  const A = M.map((r, i) => [...r, v[i]]);
  for (let c = 0; c < 4; c++) {
    let piv = c;
    for (let r = c + 1; r < 4; r++)
      if (Math.abs(A[r][c]) > Math.abs(A[piv][c])) piv = r;
    [A[c], A[piv]] = [A[piv], A[c]];
    if (Math.abs(A[c][c]) < 1e-9) return null;
    for (let r = 0; r < 4; r++) {
      if (r === c) continue;
      const f = A[r][c] / A[c][c];
      for (let k = c; k <= 4; k++) A[r][k] -= f * A[c][k];
    }
  }
  return [0, 1, 2, 3].map((i) => A[i][4] / A[i][i]);
}

function derivePrices(sessionData) {
  const rowsByModel = new Map();
  for (const s of sessionData.session ?? []) {
    for (const b of s.modelBreakdowns ?? []) {
      const arr = rowsByModel.get(b.modelName) ?? [];
      arr.push({
        x: [
          b.inputTokens || 0,
          b.outputTokens || 0,
          b.cacheCreationTokens || 0,
          b.cacheReadTokens || 0,
        ],
        y: b.cost || 0,
      });
      rowsByModel.set(b.modelName, arr);
    }
  }

  const prices = new Map();
  for (const [model, rows] of rowsByModel) {
    let p = rows.length >= 4 ? leastSquares4(rows) : null;
    if (p) {
      let actual = 0;
      let dev = 0;
      for (const { x, y } of rows) {
        const pred = x[0] * p[0] + x[1] * p[1] + x[2] * p[2] + x[3] * p[3];
        actual += y;
        dev += Math.abs(pred - y);
      }
      if (!(actual > 0 && dev / actual < 0.02)) p = null;
      if (p && p.some((z) => z < 0)) p = null;
    }
    if (!p) {
      const fb = FALLBACK_PRICE_PER_MTOK[model];
      p = fb ? fb.map((z) => z / 1e6) : null;
    }
    if (p) prices.set(model, { in: p[0], out: p[1], cw: p[2], cr: p[3] });
  }
  return prices;
}

function costOf(prices, model, t) {
  const p = prices.get(model);
  if (!p) return 0;
  return (
    t.input * p.in +
    t.output * p.out +
    t.cacheCreate * p.cw +
    t.cacheRead * p.cr
  );
}

function pricingInfo(prices) {
  const models = {};
  for (const [m, p] of prices) {
    models[m] = {
      inputPerMTok: +(p.in * 1e6).toFixed(4),
      outputPerMTok: +(p.out * 1e6).toFixed(4),
      cacheWritePerMTok: +(p.cw * 1e6).toFixed(4),
      cacheReadPerMTok: +(p.cr * 1e6).toFixed(4),
    };
  }
  return {
    note: "USD per million tokens, derived from ccusage session data so per-chat costs reconcile with ccusage's totals.",
    models,
  };
}

function walkJsonl(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walkJsonl(p));
    else if (e.name.endsWith(".jsonl")) out.push(p);
  }
  return out;
}

function extractText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((c) => c && c.type === "text" && typeof c.text === "string")
      .map((c) => c.text)
      .join(" ");
  }
  return "";
}

function buildChatIndex() {
  const meta = new Map();
  const byDate = new Map();
  const seen = new Set();

  const getMeta = (sid) => {
    let m = meta.get(sid);
    if (!m) {
      m = {
        aiTitle: null,
        firstUserText: null,
        firstUserTs: null,
        project: null,
        projectName: null,
        gitBranch: null,
        version: null,
        firstTs: null,
        lastTs: null,
      };
      meta.set(sid, m);
    }
    return m;
  };

  const getDayChat = (date, sid, ts) => {
    let dayMap = byDate.get(date);
    if (!dayMap) {
      dayMap = new Map();
      byDate.set(date, dayMap);
    }
    let dc = dayMap.get(sid);
    if (!dc) {
      dc = {
        sessionId: sid,
        models: new Map(),
        firstTs: ts,
        lastTs: ts,
        userMsgs: 0,
        asstMsgs: 0,
      };
      dayMap.set(sid, dc);
    }
    if (ts < dc.firstTs) dc.firstTs = ts;
    if (ts > dc.lastTs) dc.lastTs = ts;
    return dc;
  };

  for (const file of PROJECTS_DIRS.flatMap((dir) => walkJsonl(dir))) {
    let text;
    try {
      text = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let o;
      try {
        o = JSON.parse(line);
      } catch {
        continue;
      }
      const sid = o.sessionId;
      if (!sid) continue;

      if (o.type === "ai-title" && o.aiTitle) {
        getMeta(sid).aiTitle = o.aiTitle;
        continue;
      }

      const m = getMeta(sid);
      if (o.cwd) {
        m.project = o.cwd;
        m.projectName = o.cwd.split("/").filter(Boolean).pop() ?? o.cwd;
      }
      if (o.gitBranch) m.gitBranch = o.gitBranch;
      if (o.version) m.version = o.version;

      const ts = o.timestamp;
      if (ts) {
        if (!m.firstTs || ts < m.firstTs) m.firstTs = ts;
        if (!m.lastTs || ts > m.lastTs) m.lastTs = ts;
      }

      if (o.type === "user" && ts) {
        getDayChat(localDateStr(new Date(ts)), sid, ts).userMsgs++;
        if (!m.firstUserTs || ts < m.firstUserTs) {
          const t = extractText(o.message?.content).trim().replace(/\s+/g, " ");
          if (t) {
            m.firstUserText = t.slice(0, 100);
            m.firstUserTs = ts;
          }
        }
        continue;
      }

      if (o.type === "assistant" && ts) {
        const dc = getDayChat(localDateStr(new Date(ts)), sid, ts);
        dc.asstMsgs++;
        const u = o.message?.usage;
        if (!u) continue;
        const key =
          o.message?.id && o.requestId
            ? `${o.message.id}|${o.requestId}`
            : null;
        if (key) {
          if (seen.has(key)) continue;
          seen.add(key);
        }
        const model = o.message?.model ?? "unknown";
        const t = dc.models.get(model) ?? {
          input: 0,
          output: 0,
          cacheCreate: 0,
          cacheRead: 0,
        };
        t.input += u.input_tokens || 0;
        t.output += u.output_tokens || 0;
        t.cacheCreate += u.cache_creation_input_tokens || 0;
        t.cacheRead += u.cache_read_input_tokens || 0;
        dc.models.set(model, t);
      }
    }
  }

  return { byDate, meta };
}

function chatsForDate(index, prices, date) {
  const dayMap = index.byDate.get(date);
  if (!dayMap) return [];

  const chats = [];
  for (const dc of dayMap.values()) {
    const m = index.meta.get(dc.sessionId) ?? {};
    const models = [...dc.models.entries()]
      .map(([modelName, t]) => ({
        modelName,
        inputTokens: t.input,
        outputTokens: t.output,
        cacheCreationTokens: t.cacheCreate,
        cacheReadTokens: t.cacheRead,
        totalTokens: t.input + t.output + t.cacheCreate + t.cacheRead,
        cost: costOf(prices, modelName, t),
      }))
      .sort((a, b) => b.cost - a.cost);

    chats.push({
      sessionId: dc.sessionId,
      title: m.aiTitle || m.firstUserText || "(untitled)",
      titleSource: m.aiTitle
        ? "ai-title"
        : m.firstUserText
          ? "first-prompt"
          : "none",
      project: m.project ?? null,
      projectName: m.projectName ?? null,
      gitBranch: m.gitBranch ?? null,
      claudeVersion: m.version ?? null,
      firstMessageAt: dc.firstTs,
      lastMessageAt: dc.lastTs,
      sessionStart: m.firstTs ?? null,
      sessionEnd: m.lastTs ?? null,
      userMessages: dc.userMsgs,
      assistantMessages: dc.asstMsgs,
      messageCount: dc.userMsgs + dc.asstMsgs,
      models,
      totalTokens: models.reduce((s, x) => s + x.totalTokens, 0),
      totalCost: models.reduce((s, x) => s + x.cost, 0),
    });
  }
  return chats.sort((a, b) => b.totalCost - a.totalCost);
}

function projectsForChats(chats) {
  const byProj = new Map();
  for (const c of chats) {
    const key = c.project ?? "(unknown)";
    const a = byProj.get(key) ?? {
      project: c.project ?? null,
      projectName: c.projectName ?? null,
      chatCount: 0,
      totalTokens: 0,
      totalCost: 0,
    };
    a.chatCount++;
    a.totalTokens += c.totalTokens;
    a.totalCost += c.totalCost;
    byProj.set(key, a);
  }
  return [...byProj.values()].sort((a, b) => b.totalCost - a.totalCost);
}

function richDay(date, dailyItem, index, prices) {
  const chats = chatsForDate(index, prices, date);
  return {
    date,
    totals: {
      inputTokens: dailyItem?.inputTokens ?? 0,
      outputTokens: dailyItem?.outputTokens ?? 0,
      cacheCreationTokens: dailyItem?.cacheCreationTokens ?? 0,
      cacheReadTokens: dailyItem?.cacheReadTokens ?? 0,
      totalTokens: dailyItem?.totalTokens ?? 0,
      cost: dailyItem?.totalCost ?? 0,
    },
    models: dailyItem ? rowsFromItems([dailyItem]) : [],
    chatCount: chats.length,
    chatsTotal: {
      totalTokens: chats.reduce((s, c) => s + c.totalTokens, 0),
      totalCost: chats.reduce((s, c) => s + c.totalCost, 0),
    },
    projects: projectsForChats(chats),
    chats,
  };
}

function rowsFromItems(items) {
  const byModel = new Map();
  const empty = () => ({
    inputTokens: 0,
    outputTokens: 0,
    cacheCreationTokens: 0,
    cacheReadTokens: 0,
    cost: 0,
  });

  for (const item of items) {
    for (const m of item.modelBreakdowns ?? []) {
      const acc = byModel.get(m.modelName) ?? empty();
      acc.inputTokens += m.inputTokens ?? 0;
      acc.outputTokens += m.outputTokens ?? 0;
      acc.cacheCreationTokens += m.cacheCreationTokens ?? 0;
      acc.cacheReadTokens += m.cacheReadTokens ?? 0;
      acc.cost += m.cost ?? 0;
      byModel.set(m.modelName, acc);
    }
  }

  return [...byModel.entries()]
    .map(([modelName, v]) => ({
      modelName,
      ...v,
      totalTokens:
        v.inputTokens +
        v.outputTokens +
        v.cacheCreationTokens +
        v.cacheReadTokens,
    }))
    .sort((a, b) => b.cost - a.cost);
}

const num = (n) => n.toLocaleString("en-US");
const usd = (n) => "$" + n.toFixed(2);
const shortName = (n) => n.replace(/^claude-/, "").replace(/-\d{8}$/, "");

function renderTable(headers, rows, align, { dividerBeforeLast = false } = {}) {
  const widths = headers.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => String(r[i]).length)),
  );

  const pad = (s, i) => {
    s = String(s);
    const gap = widths[i] - s.length;
    return align[i] === "r" ? " ".repeat(gap) + s : s + " ".repeat(gap);
  };

  const line = (l, mid, r) =>
    l + widths.map((w) => "─".repeat(w + 2)).join(mid) + r;
  const row = (cells) =>
    "│ " + cells.map((c, i) => pad(c, i)).join(" │ ") + " │";

  const out = [];
  out.push(line("┌", "┬", "┐"));
  out.push(row(headers));
  out.push(line("├", "┼", "┤"));
  rows.forEach((r, idx) => {
    if (dividerBeforeLast && idx === rows.length - 1) {
      out.push(line("├", "┼", "┤"));
    }
    out.push(row(r));
  });
  out.push(line("└", "┴", "┘"));
  return out.join("\n");
}

function printSection(title, rows) {
  console.log(`\n${title}\n`);

  if (rows.length === 0) {
    console.log("  (no usage recorded)\n");
    return;
  }

  const totalCost = rows.reduce((s, r) => s + r.cost, 0);
  const pct = (c) =>
    (totalCost ? ((c / totalCost) * 100).toFixed(1) : "0.0") + "%";

  const headers = [
    "Model",
    "Input",
    "Output",
    "Cache Create",
    "Cache Read",
    "Total Tokens",
    "Cost",
    "% Spend",
  ];
  const align = ["l", "r", "r", "r", "r", "r", "r", "r"];

  const dataRows = rows.map((r) => [
    shortName(r.modelName),
    num(r.inputTokens),
    num(r.outputTokens),
    num(r.cacheCreationTokens),
    num(r.cacheReadTokens),
    num(r.totalTokens),
    usd(r.cost),
    pct(r.cost),
  ]);

  const sum = (key) => rows.reduce((s, r) => s + r[key], 0);
  dataRows.push([
    "TOTAL",
    num(sum("inputTokens")),
    num(sum("outputTokens")),
    num(sum("cacheCreationTokens")),
    num(sum("cacheReadTokens")),
    num(sum("totalTokens")),
    usd(totalCost),
    "100%",
  ]);

  console.log(
    renderTable(headers, dataRows, align, { dividerBeforeLast: true }),
  );
  console.log(`\nTotal spend: ${usd(totalCost)}\n`);
}

function todayRowsBySource() {
  const out = [];
  for (const src of SOURCES) {
    const daily = fetchCcusage("daily", src.dirs);
    const items = (daily.daily ?? []).filter((d) => d.period === today);
    for (const r of rowsFromItems(items)) out.push({ ...r, source: src.key });
  }
  return out;
}

function printTodayBySource(title, rows) {
  console.log(`\n${title}\n`);

  if (rows.length === 0) {
    console.log("  (no usage recorded)\n");
    return;
  }

  const totalCost = rows.reduce((s, r) => s + r.cost, 0);
  const pct = (c) =>
    (totalCost ? ((c / totalCost) * 100).toFixed(1) : "0.0") + "%";
  const sum = (key) => rows.reduce((s, r) => s + r[key], 0);

  const byModelMap = new Map();
  for (const r of rows) {
    const a = byModelMap.get(r.modelName) ?? {
      modelName: r.modelName,
      inputTokens: 0,
      outputTokens: 0,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      totalTokens: 0,
      cost: 0,
    };
    a.inputTokens += r.inputTokens;
    a.outputTokens += r.outputTokens;
    a.cacheCreationTokens += r.cacheCreationTokens;
    a.cacheReadTokens += r.cacheReadTokens;
    a.totalTokens += r.totalTokens;
    a.cost += r.cost;
    byModelMap.set(r.modelName, a);
  }
  const modelRows = [...byModelMap.values()].sort((a, b) => b.cost - a.cost);

  const headers = [
    "Model",
    "Input",
    "Output",
    "Cache Create",
    "Cache Read",
    "Total Tokens",
    "Cost",
    "% Spend",
  ];
  const align = ["l", "r", "r", "r", "r", "r", "r", "r"];
  const dataRows = modelRows.map((r) => [
    shortName(r.modelName),
    num(r.inputTokens),
    num(r.outputTokens),
    num(r.cacheCreationTokens),
    num(r.cacheReadTokens),
    num(r.totalTokens),
    usd(r.cost),
    pct(r.cost),
  ]);
  dataRows.push([
    "TOTAL",
    num(sum("inputTokens")),
    num(sum("outputTokens")),
    num(sum("cacheCreationTokens")),
    num(sum("cacheReadTokens")),
    num(sum("totalTokens")),
    usd(totalCost),
    "100%",
  ]);
  console.log(
    renderTable(headers, dataRows, align, { dividerBeforeLast: true }),
  );

  const bySrc = new Map();
  for (const r of rows) {
    const a = bySrc.get(r.source) ?? {
      source: r.source,
      inputTokens: 0,
      outputTokens: 0,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      totalTokens: 0,
      cost: 0,
    };
    a.inputTokens += r.inputTokens;
    a.outputTokens += r.outputTokens;
    a.cacheCreationTokens += r.cacheCreationTokens;
    a.cacheReadTokens += r.cacheReadTokens;
    a.totalTokens += r.totalTokens;
    a.cost += r.cost;
    bySrc.set(r.source, a);
  }
  const srcRows = [...bySrc.values()].sort((a, b) => b.cost - a.cost);

  console.log("\nBy Source\n");
  const sHeaders = [
    "Source",
    "Input",
    "Output",
    "Cache Create",
    "Cache Read",
    "Total Tokens",
    "Cost",
    "% Spend",
  ];
  const sAlign = ["l", "r", "r", "r", "r", "r", "r", "r"];
  const sData = srcRows.map((r) => [
    r.source,
    num(r.inputTokens),
    num(r.outputTokens),
    num(r.cacheCreationTokens),
    num(r.cacheReadTokens),
    num(r.totalTokens),
    usd(r.cost),
    pct(r.cost),
  ]);
  sData.push([
    "TOTAL",
    num(sum("inputTokens")),
    num(sum("outputTokens")),
    num(sum("cacheCreationTokens")),
    num(sum("cacheReadTokens")),
    num(sum("totalTokens")),
    usd(totalCost),
    "100%",
  ]);
  console.log(
    renderTable(sHeaders, sData, sAlign, { dividerBeforeLast: true }),
  );
  console.log(`\nTotal spend: ${usd(totalCost)}\n`);
}

const today = localDateStr();

const dailyData = fetchCcusage("daily");
const allDays = (dailyData.daily ?? [])
  .slice()
  .sort((a, b) => (a.period < b.period ? -1 : 1));
const todayItems = allDays.filter((d) => d.period === today);

const dayRange =
  allDays.length === 0
    ? "no data"
    : allDays[0].period === allDays.at(-1).period
      ? allDays[0].period
      : `${allDays[0].period} → ${allDays.at(-1).period}`;

let allRows = [];
let range = "no data";
if (!todayOnly && !dayWise) {
  const monthlyData = fetchCcusage("monthly");
  const allItems = monthlyData.monthly ?? [];
  allRows = rowsFromItems(allItems);
  const periods = allItems.map((m) => m.period).sort();
  range =
    periods.length === 0
      ? "no data"
      : periods[0] === periods.at(-1)
        ? periods[0]
        : `${periods[0]} → ${periods.at(-1)}`;
}

let prices = null;
let chatIndex = null;
if (wantJson) {
  prices = derivePrices(fetchSessionData());
  chatIndex = buildChatIndex();
}

if (dayWise) {
  if (wantJson) {
    const payload = {
      generatedAt: new Date().toISOString(),
      range: {
        from: allDays[0]?.period ?? null,
        to: allDays.at(-1)?.period ?? null,
      },
      pricing: pricingInfo(prices),
      days: allDays.map((d) => richDay(d.period, d, chatIndex, prices)),
    };
    console.log(JSON.stringify(payload, null, 2));
  } else if (allDays.length === 0) {
    console.log("\nClaude Code - Day-wise Usage\n\n  (no usage recorded)\n");
  } else {
    console.log(`\nClaude Code - Day-wise Usage by Model (${dayRange})`);
    for (const d of allDays) {
      printSection(`${d.period}`, rowsFromItems([d]));
    }
  }
} else if (wantJson) {
  const totalOf = (rows) => rows.reduce((s, r) => s + r.cost, 0);
  const todayBlock = richDay(today, todayItems[0] ?? null, chatIndex, prices);
  const payload = todayOnly
    ? {
        generatedAt: new Date().toISOString(),
        pricing: pricingInfo(prices),
        today: todayBlock,
      }
    : {
        generatedAt: new Date().toISOString(),
        pricing: pricingInfo(prices),
        today: todayBlock,
        allTime: { range, totalCost: totalOf(allRows), models: allRows },
      };
  console.log(JSON.stringify(payload, null, 2));
} else {
  printTodayBySource(
    `Claude Code - Today's Usage by Model (${today})`,
    todayRowsBySource(),
  );
  if (!todayOnly) {
    printSection(`Claude Code - All-Time Usage by Model (${range})`, allRows);
  }
}
