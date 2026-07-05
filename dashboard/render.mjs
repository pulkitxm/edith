#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { downsampleLimits, parseLimitsJSONL } from "./limits.mjs";
import {
  claudeCodeSources,
  metaFor,
  normalizeAgentDaily,
  tokensOf,
} from "./merge.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
if (args.length < 1) {
  console.error("usage: node render.mjs <manifest.json>");
  console.error(
    "  manifest = [{ source, daily, session, configDirs }] - one entry per ccusage agent stream",
  );
  process.exit(1);
}

const readJSON = (p) => (p ? JSON.parse(readFileSync(p, "utf8")) : {});

const manifest = readJSON(args[0]);
if (!Array.isArray(manifest) || !manifest.length) {
  console.error(
    "ERROR: manifest must be a non-empty array of { source, daily, session, configDirs }",
  );
  process.exit(1);
}

const CLOUD_SOURCE = "cc-cloud";
const cloudIds = new Set();
if (args[1] && existsSync(args[1])) {
  try {
    for (const id of JSON.parse(readFileSync(args[1], "utf8")) || [])
      if (id) cloudIds.add(id);
  } catch (e) {
    console.error("warning: could not read cloud-session ids:", e.message);
  }
}

const byDate = {};
const sessionBySource = {};
const sourcesWithData = [];

for (const entry of manifest) {
  const src = entry.source;
  const rows = readJSON(entry.daily).daily || [];
  sessionBySource[src] = entry.session
    ? readJSON(entry.session)
    : { sessions: [] };
  if (rows.length) sourcesWithData.push(src);
  for (const row of rows) {
    const { period, breakdowns } = normalizeAgentDaily(row);
    if (period) (byDate[period] ||= {})[src] = breakdowns;
  }
}
const sources = [
  "cli",
  ...manifest
    .map((e) => e.source)
    .filter((s) => s !== "cli" && sourcesWithData.includes(s)),
];

const daily = Object.keys(byDate)
  .sort()
  .map((period) => {
    const bySource = {};
    for (const src of sources) bySource[src] = byDate[period][src] || [];
    return { period, bySource };
  });

const blank = () => ({
  cost: 0,
  tokens: 0,
  inputTokens: 0,
  outputTokens: 0,
  cacheCreationTokens: 0,
  cacheReadTokens: 0,
});
const totals = blank();
totals.bySource = {};
for (const src of sources) totals.bySource[src] = { cost: 0, tokens: 0 };
for (const d of daily) {
  for (const src of sources) {
    for (const b of d.bySource[src]) {
      const t = tokensOf(b);
      totals.cost += b.cost;
      totals.tokens += t;
      totals.inputTokens += b.inputTokens;
      totals.outputTokens += b.outputTokens;
      totals.cacheCreationTokens += b.cacheCreationTokens;
      totals.cacheReadTokens += b.cacheReadTokens;
      totals.bySource[src].cost += b.cost;
      totals.bySource[src].tokens += t;
    }
  }
}

const mapSessions = (obj, src) =>
  (obj.sessions || obj.session || []).map((s) => ({
    id: s.sessionId || s.period,
    lastActivity: s.lastActivity || (s.metadata && s.metadata.lastActivity),
    totalCost: s.totalCost,
    totalTokens: s.totalTokens,
    models: s.modelsUsed,
    source: src,
  }));
const sessions = sources.flatMap((src) =>
  mapSessions(sessionBySource[src] || {}, src),
);

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

function derivePrices(...sessionDatas) {
  const rowsByModel = new Map();
  for (const sessionData of sessionDatas) {
    for (const s of sessionData.sessions ?? sessionData.session ?? []) {
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
  }
  const prices = new Map();
  for (const [model, rows] of rowsByModel) {
    let p = rows.length >= 4 ? leastSquares4(rows) : null;
    if (p) {
      let actual = 0,
        dev = 0;
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

function costOfTokens(prices, model, t) {
  const p = prices.get(model);
  if (!p) return 0;
  return t.input * p.in + t.output * p.out + t.cw * p.cw + t.cr * p.cr;
}

function walkJsonl(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walkJsonl(p));
    else if (e.name.endsWith(".jsonl")) out.push(p);
  }
  return out;
}

function localDateStr(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

const splitDirs = (s) =>
  (s || "")
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
const configDirsFor = {};
for (const entry of manifest)
  configDirsFor[entry.source] = splitDirs(entry.configDirs);

const WORKTREE_MARKERS = ["/.claude/worktrees/", "/.cursor/worktrees/"];
const projectNameCache = new Map();

function gitMainRepoRoot(cwd) {
  let commonDir;
  try {
    commonDir = execFileSync(
      "git",
      ["-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
  } catch {
    return null;
  }
  if (!commonDir) return null;
  if (commonDir.endsWith("/.git")) return dirname(commonDir);
  try {
    return (
      execFileSync(
        "git",
        ["-C", cwd, "rev-parse", "--path-format=absolute", "--show-toplevel"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
      ).trim() || null
    );
  } catch {
    return null;
  }
}

function repoRootFromPath(cwd) {
  for (const m of WORKTREE_MARKERS) {
    const i = cwd.indexOf(m);
    if (i > 0) return cwd.slice(0, i);
  }
  return null;
}

function projectNameFromCwd(cwd) {
  if (!cwd) return "(unknown)";
  const cached = projectNameCache.get(cwd);
  if (cached !== undefined) return cached;
  let name;
  if (cwd.includes("/local-agent-mode-sessions/")) {
    name = "Cowork";
  } else {
    let root = existsSync(cwd) ? gitMainRepoRoot(cwd) : null;
    if (!root) root = repoRootFromPath(cwd);
    name = (root || cwd).split("/").filter(Boolean).pop() || "(unknown)";
  }
  projectNameCache.set(cwd, name);
  return name;
}

function worktreeOf(cwd) {
  if (!cwd) return null;
  for (const m of WORKTREE_MARKERS) {
    const i = cwd.indexOf(m);
    if (i >= 0)
      return (
        cwd
          .slice(i + m.length)
          .split("/")
          .filter(Boolean)[0] || null
      );
  }
  return null;
}

function userText(o) {
  const c = o.message?.content;
  if (typeof c === "string") return c.trim();
  if (Array.isArray(c)) {
    for (const b of c)
      if (b?.type === "text" && typeof b.text === "string")
        return b.text.trim();
  }
  return "";
}

function buildDrilldown(prices) {
  const byDate = new Map();
  const seen = new Set();
  const titleBySession = new Map();
  const firstTextBySession = new Map();
  const cloudByDateModel = new Map();
  const getDay = (date) => {
    let d = byDate.get(date);
    if (!d) {
      d = {
        projects: new Map(),
        hours: Array.from({ length: 24 }, () => ({ tokens: 0, cost: 0 })),
      };
      byDate.set(date, d);
    }
    return d;
  };
  const blankProj = () => ({
    tokens: 0,
    cost: 0,
    main: new Map(),
    worktrees: new Map(),
  });
  const blankChat = () => ({
    tokens: 0,
    cost: 0,
    firstTs: 0,
    lastTs: 0,
    source: "",
  });

  for (const src of sources) {
    for (const cfg of configDirsFor[src] || []) {
      for (const file of walkJsonl(join(cfg, "projects"))) {
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

          if (o.type === "ai-title" && o.aiTitle && o.sessionId) {
            titleBySession.set(o.sessionId, String(o.aiTitle).trim());
            continue;
          }
          if (
            o.type === "user" &&
            o.sessionId &&
            !firstTextBySession.has(o.sessionId)
          ) {
            const txt = userText(o);
            if (txt && !txt.startsWith("<"))
              firstTextBySession.set(o.sessionId, txt.slice(0, 80));
          }
          if (o.type !== "assistant") continue;

          const ts = o.timestamp;
          const u = o.message?.usage;
          if (!ts || !u) continue;
          const key =
            o.message?.id && o.requestId
              ? `${o.message.id}|${o.requestId}`
              : null;
          if (key) {
            if (seen.has(key)) continue;
            seen.add(key);
          }

          const dt = new Date(ts);
          const date = localDateStr(dt);
          const hour = dt.getHours();
          const model = o.message?.model ?? "unknown";
          const t = {
            input: u.input_tokens || 0,
            output: u.output_tokens || 0,
            cw: u.cache_creation_input_tokens || 0,
            cr: u.cache_read_input_tokens || 0,
          };
          const tokens = t.input + t.output + t.cw + t.cr;
          const cost = costOfTokens(prices, model, t);

          const projectName = projectNameFromCwd(o.cwd);
          const wt = worktreeOf(o.cwd);
          const sid = o.sessionId || "(no-session)";

          if (cloudIds.has(sid)) {
            let cm = cloudByDateModel.get(date);
            if (!cm) cloudByDateModel.set(date, (cm = new Map()));
            let agg = cm.get(model);
            if (!agg)
              cm.set(
                model,
                (agg = {
                  input: 0,
                  output: 0,
                  cw: 0,
                  cr: 0,
                  cost: 0,
                  tokens: 0,
                }),
              );
            agg.input += t.input;
            agg.output += t.output;
            agg.cw += t.cw;
            agg.cr += t.cr;
            agg.cost += cost;
            agg.tokens += tokens;
          }

          const day = getDay(date);

          const p = day.projects.get(projectName) ?? blankProj();
          p.tokens += tokens;
          p.cost += cost;
          let chats;
          if (wt) {
            const w = p.worktrees.get(wt) ?? {
              tokens: 0,
              cost: 0,
              chats: new Map(),
            };
            w.tokens += tokens;
            w.cost += cost;
            p.worktrees.set(wt, w);
            chats = w.chats;
          } else {
            chats = p.main;
          }
          const c = chats.get(sid) ?? blankChat();
          c.tokens += tokens;
          c.cost += cost;
          c.source = cloudIds.has(sid) ? CLOUD_SOURCE : src;
          const tms = dt.getTime();
          if (!c.firstTs || tms < c.firstTs) c.firstTs = tms;
          if (tms > c.lastTs) c.lastTs = tms;
          chats.set(sid, c);
          day.projects.set(projectName, p);

          day.hours[hour].tokens += tokens;
          day.hours[hour].cost += cost;
        }
      }
    }
  }

  for (const day of byDate.values()) {
    for (const p of day.projects.values()) {
      const locs = [{ chats: p.main, wt: null }];
      for (const w of p.worktrees.values())
        locs.push({ chats: w.chats, wt: w });
      const bySid = new Map();
      for (const loc of locs) {
        for (const [sid, c] of loc.chats) {
          if (sid === "(no-session)") continue;
          const arr = bySid.get(sid) ?? [];
          arr.push({ loc, c });
          bySid.set(sid, arr);
        }
      }
      for (const [sid, frags] of bySid) {
        if (frags.length < 2) continue;
        let winner = frags[0];
        for (const f of frags) if (f.c.tokens > winner.c.tokens) winner = f;
        for (const f of frags) {
          if (f === winner) continue;
          winner.c.tokens += f.c.tokens;
          winner.c.cost += f.c.cost;
          if (
            f.c.firstTs &&
            (!winner.c.firstTs || f.c.firstTs < winner.c.firstTs)
          )
            winner.c.firstTs = f.c.firstTs;
          if (f.c.lastTs > winner.c.lastTs) winner.c.lastTs = f.c.lastTs;
          f.loc.chats.delete(sid);
          if (f.loc.wt) {
            f.loc.wt.tokens -= f.c.tokens;
            f.loc.wt.cost -= f.c.cost;
          }
          if (winner.loc.wt) {
            winner.loc.wt.tokens += f.c.tokens;
            winner.loc.wt.cost += f.c.cost;
          }
        }
      }
      for (const [name, w] of [...p.worktrees]) {
        if (!w.chats.size && w.tokens <= 0) p.worktrees.delete(name);
      }
    }
  }

  byDate.titleFor = (id) =>
    titleBySession.get(id) ||
    firstTextBySession.get(id) ||
    (id && id !== "(no-session)" ? `Chat ${id.slice(0, 8)}` : "Untitled chat");
  byDate.cloudByDateModel = cloudByDateModel;
  return byDate;
}

let drilldownAvailable = false;
if (Object.values(configDirsFor).some((a) => a.length)) {
  try {
    const prices = derivePrices(...Object.values(sessionBySource));
    const dd = buildDrilldown(prices);
    const chatList = (m) =>
      [...m.entries()]
        .map(([id, v]) => ({
          id,
          title: dd.titleFor(id),
          tokens: v.tokens,
          cost: v.cost,
          firstTs: v.firstTs || 0,
          lastTs: v.lastTs || 0,
          source: v.source || "",
        }))
        .sort((a, b) => b.tokens - a.tokens || a.id.localeCompare(b.id));
    for (const d of daily) {
      const day = dd.get(d.period);
      if (day) {
        d.projects = [...day.projects.entries()]
          .map(([projectName, v]) => ({
            projectName,
            tokens: v.tokens,
            cost: v.cost,
            chats: chatList(v.main),
            worktrees: [...v.worktrees.entries()]
              .map(([name, w]) => ({
                name,
                tokens: w.tokens,
                cost: w.cost,
                chats: chatList(w.chats),
              }))
              .sort(
                (a, b) => b.tokens - a.tokens || a.name.localeCompare(b.name),
              ),
          }))
          .sort(
            (a, b) =>
              b.tokens - a.tokens || a.projectName.localeCompare(b.projectName),
          );
        d.hours = day.hours.map((h) => ({ tokens: h.tokens, cost: h.cost }));
      } else {
        d.projects = [];
        d.hours = Array.from({ length: 24 }, () => ({ tokens: 0, cost: 0 }));
      }
    }

    const cbm = dd.cloudByDateModel;
    let splitAny = false;
    if (cloudIds.size && cbm && cbm.size) {
      for (const d of daily) {
        const cm = cbm.get(d.period);
        if (!cm || !cm.size) continue;
        const cli = d.bySource.cli || [];
        const cloudBreakdowns = [];
        for (const [model, agg] of cm) {
          const b = cli.find((x) => x.modelName === model);
          const cIn = b ? Math.min(agg.input, b.inputTokens) : agg.input;
          const cOut = b ? Math.min(agg.output, b.outputTokens) : agg.output;
          const cCw = b ? Math.min(agg.cw, b.cacheCreationTokens) : agg.cw;
          const cCr = b ? Math.min(agg.cr, b.cacheReadTokens) : agg.cr;
          const cCost = b ? Math.min(agg.cost, b.cost) : agg.cost;
          if (cIn + cOut + cCw + cCr <= 0 && cCost <= 0) continue;
          cloudBreakdowns.push({
            modelName: model,
            inputTokens: cIn,
            outputTokens: cOut,
            cacheCreationTokens: cCw,
            cacheReadTokens: cCr,
            cost: cCost,
          });
          if (b) {
            b.inputTokens -= cIn;
            b.outputTokens -= cOut;
            b.cacheCreationTokens -= cCw;
            b.cacheReadTokens -= cCr;
            b.cost -= cCost;
          }
        }
        if (cloudBreakdowns.length) {
          d.bySource[CLOUD_SOURCE] = cloudBreakdowns;
          splitAny = true;
        }
      }
    }
    if (splitAny) {
      sources.splice(1, 0, CLOUD_SOURCE);
      for (const d of daily) d.bySource[CLOUD_SOURCE] ||= [];
      const t2 = blank();
      t2.bySource = {};
      for (const src of sources) t2.bySource[src] = { cost: 0, tokens: 0 };
      for (const d of daily)
        for (const src of sources)
          for (const b of d.bySource[src]) {
            const tk = tokensOf(b);
            t2.cost += b.cost;
            t2.tokens += tk;
            t2.inputTokens += b.inputTokens;
            t2.outputTokens += b.outputTokens;
            t2.cacheCreationTokens += b.cacheCreationTokens;
            t2.cacheReadTokens += b.cacheReadTokens;
            t2.bySource[src].cost += b.cost;
            t2.bySource[src].tokens += tk;
          }
      Object.assign(totals, t2);
      for (const s of sessions)
        if (s.source === "cli" && cloudIds.has(s.id)) s.source = CLOUD_SOURCE;
    }

    drilldownAvailable = true;
  } catch (e) {
    console.error(
      "warning: failed to build v3 drilldown (projects/hours):",
      e.message,
    );
  }
}

const payload = {
  schemaVersion: drilldownAvailable ? 4 : 2,
  generatedAt: new Date().toISOString(),
  sources,
  totals,
  daily,
  sessions,
  sourceMeta: Object.fromEntries(sources.map((s) => [s, metaFor(s)])),
  defaultSources: claudeCodeSources(sources).length
    ? claudeCodeSources(sources)
    : sources,
};

mkdirSync(resolve(here, "data"), { recursive: true });
writeFileSync(
  resolve(here, "data", "usage.json"),
  JSON.stringify(payload, null, 2) + "\n",
);

const htmlPath = resolve(here, "dashboard.html");
let html = readFileSync(htmlPath, "utf8");
const safe = JSON.stringify(payload).replace(/<\/script>/g, "<\\/script>");
const re =
  /(<script id="usage-data" type="application\/json">)([\s\S]*?)(<\/script>)/;
if (!re.test(html)) {
  console.error(
    'ERROR: could not find <script id="usage-data"> block in dashboard.html',
  );
  process.exit(1);
}
html = html.replace(re, `$1\n${safe}\n$3`);

const limitsPath = resolve(here, "data", "limits-history.jsonl");
let limitsPayload = { points: [] };
if (existsSync(limitsPath)) {
  const rows = parseLimitsJSONL(readFileSync(limitsPath, "utf8"));
  limitsPayload = { points: downsampleLimits(rows, Date.now()) };
}
const reL =
  /(<script id="limits-data" type="application\/json">)([\s\S]*?)(<\/script>)/;
if (reL.test(html)) {
  const safeL = JSON.stringify(limitsPayload).replace(
    /<\/script>/g,
    "<\\/script>",
  );
  html = html.replace(reL, `$1\n${safeL}\n$3`);
} else {
  console.error(
    'warning: no <script id="limits-data"> block (rebuild dashboard.html with bun build.mjs)',
  );
}
writeFileSync(htmlPath, html);

const bs = sources
  .map((s) => `${s} $${totals.bySource[s].cost.toFixed(2)}`)
  .join(" · ");
console.log(
  `rendered: schema v${payload.schemaVersion} · ${daily.length} days, ${sessions.length} sessions · ${bs} · $${totals.cost.toFixed(2)} total`,
);
