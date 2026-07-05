import { cycleEnd } from "./cycles.js";
import { DAILY, EARLIEST, LATEST, SOURCES } from "./data.js";
import { parseDate, ymd } from "./format.js";
import { state } from "./state.js";

export function dayBreakdowns(d) {
  const out = [];
  for (const s of SOURCES) {
    if (!state.sources.has(s)) continue;
    for (const b of d.bySource[s] || []) out.push(b);
  }
  return out;
}

export const tokensOf = (b) =>
  (+b.inputTokens || 0) +
  (+b.outputTokens || 0) +
  (+b.cacheCreationTokens || 0) +
  (+b.cacheReadTokens || 0);

export function activeWindow() {
  const r = state.range;
  switch (r.mode) {
    case "all":
      return { from: new Date(EARLIEST), to: new Date(LATEST) };
    case "today":
      return { from: new Date(LATEST), to: new Date(LATEST) };
    case "yesterday": {
      const d = new Date(LATEST);
      d.setDate(d.getDate() - 1);
      return { from: d, to: new Date(d) };
    }
    case "thisWeek": {
      const end = new Date(LATEST);
      const dow = (end.getDay() + 6) % 7;
      const start = new Date(end);
      start.setDate(start.getDate() - dow);
      return { from: start, to: end };
    }
    case "lastWeek": {
      const end = new Date(LATEST);
      const dow = (end.getDay() + 6) % 7;
      const thisStart = new Date(end);
      thisStart.setDate(thisStart.getDate() - dow);
      const lwEnd = new Date(thisStart);
      lwEnd.setDate(lwEnd.getDate() - 1);
      const lwStart = new Date(lwEnd);
      lwStart.setDate(lwStart.getDate() - 6);
      return { from: lwStart, to: lwEnd };
    }
    case "month": {
      const [y, m] = r.month.split("-").map(Number);
      return { from: new Date(y, m - 1, 1), to: new Date(y, m, 0) };
    }
    case "cycle": {
      const start = parseDate(r.cycle);
      return { from: start, to: cycleEnd(start, state.billingDay) };
    }
    case "custom":
      return { from: parseDate(r.from), to: parseDate(r.to) };
    default:
      return { from: new Date(EARLIEST), to: new Date(LATEST) };
  }
}

export function inRangeDays() {
  const days = DAILY.slice().sort((a, b) => (a.period < b.period ? -1 : 1));
  if (state.range.mode === "all") return days;
  const w = activeWindow();
  return days.filter((d) => {
    const dt = parseDate(d.period);
    return dt >= w.from && dt <= w.to;
  });
}

export function derive() {
  const sel = state.models;
  const byDate = {};
  inRangeDays().forEach((d) => (byDate[d.period] = d));
  const w = activeWindow();
  const from = new Date(Math.max(w.from.getTime(), EARLIEST.getTime()));
  const to = new Date(Math.min(w.to.getTime(), LATEST.getTime()));
  const rows = [];
  for (let cur = new Date(from); cur <= to; cur.setDate(cur.getDate() + 1)) {
    const key = ymd(cur);
    const d = byDate[key];
    const r = {
      date: key,
      cost: 0,
      input: 0,
      output: 0,
      cacheCreate: 0,
      cacheRead: 0,
      tokens: 0,
      byModel: {},
    };
    if (d) {
      for (const b of dayBreakdowns(d)) {
        if (!sel.has(b.modelName)) continue;
        r.cost += +b.cost || 0;
        r.input += +b.inputTokens || 0;
        r.output += +b.outputTokens || 0;
        r.cacheCreate += +b.cacheCreationTokens || 0;
        r.cacheRead += +b.cacheReadTokens || 0;
        const bm =
          r.byModel[b.modelName] ||
          (r.byModel[b.modelName] = { cost: 0, tokens: 0 });
        bm.cost += +b.cost || 0;
        bm.tokens += tokensOf(b);
      }
    }
    r.tokens = r.input + r.output + r.cacheCreate + r.cacheRead;
    rows.push(r);
  }
  return rows;
}

export function deriveBySource(rows) {
  const byDate = {};
  DAILY.forEach((d) => (byDate[d.period] = d));
  const labels = rows.map((r) => r.date.slice(5));
  const series = {};
  SOURCES.filter((s) => state.sources.has(s)).forEach((s) => {
    series[s] = rows.map((r) => {
      const d = byDate[r.date];
      if (!d) return 0;
      let v = 0;
      for (const b of d.bySource[s] || []) {
        if (!state.models.has(b.modelName)) continue;
        v += tokensOf(b);
      }
      return v;
    });
  });
  return { labels, series };
}
