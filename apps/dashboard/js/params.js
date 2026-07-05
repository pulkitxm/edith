import { cycleStart } from "./cycles.js";
import {
  ALL_MODELS,
  DEFAULT_MODELS,
  DEFAULT_SOURCES,
  LATEST,
  SOURCES,
} from "./data.js";
import { shortModel, ymd } from "./format.js";
import { systemTheme } from "./palette.js";
import { DEFAULT_BILLING_DAY, state } from "./state.js";

export const shortToFull = {};
ALL_MODELS.forEach((m) => {
  shortToFull[shortModel(m)] = m;
});

export function readParams() {
  let q;
  try {
    q = new URLSearchParams(location.search);
  } catch (_e) {
    return;
  }
  const r = q.get("range");
  if (r) {
    if (r === "all") state.range = { mode: "all" };
    else if (/^\d+$/.test(r)) {
      const n = +r;
      const to = new Date(LATEST);
      const from = new Date(LATEST);
      from.setDate(from.getDate() - (n - 1));
      state.range = { mode: "custom", from: ymd(from), to: ymd(to) };
    } else if (["today", "yesterday", "thisWeek", "lastWeek"].includes(r))
      state.range = { mode: r };
    else if (r.startsWith("m:"))
      state.range = { mode: "month", month: r.slice(2) };
    else if (r.startsWith("cy:"))
      state.range = { mode: "cycle", cycle: r.slice(3) };
    else if (r.startsWith("c:")) {
      const [from, to] = r.slice(2).split("~");
      if (from && to) state.range = { mode: "custom", from, to };
    }
  }
  const ms = q.get("models");
  if (ms) {
    const wanted = ms
      .split(",")
      .map((s) => shortToFull[s] || (ALL_MODELS.includes(s) ? s : null))
      .filter(Boolean);
    if (wanted.length) state.models = new Set(wanted);
  }
  const ss = q.get("sources");
  if (ss) {
    const wanted = ss.split(",").filter((s) => SOURCES.includes(s));
    if (wanted.length) state.sources = new Set(wanted);
  }
  const th = q.get("theme");
  if (th === "dark" || th === "light") state.theme = th;
  const cd = q.get("cycleDay");
  if (cd && /^\d+$/.test(cd)) {
    const n = +cd;
    if (n >= 1 && n <= 31) state.billingDay = n;
  }
}

export function rangeToParam() {
  const r = state.range;
  if (r.mode === "all") return "all";
  if (r.mode === "month") return "m:" + r.month;
  if (r.mode === "cycle") {
    if (LATEST && r.cycle === ymd(cycleStart(LATEST, state.billingDay)))
      return "";
    return "cy:" + r.cycle;
  }
  if (r.mode === "custom") return "c:" + r.from + "~" + r.to;
  return r.mode;
}
export function writeParams() {
  let url;
  try {
    url = new URL(location.href);
  } catch (_e) {
    return;
  }
  const q = url.searchParams;
  const rp = rangeToParam();
  rp ? q.set("range", rp) : q.delete("range");
  const isDefaultModels =
    state.models.size === DEFAULT_MODELS.length &&
    DEFAULT_MODELS.every((m) => state.models.has(m));
  if (isDefaultModels) q.delete("models");
  else
    q.set(
      "models",
      ALL_MODELS.filter((m) => state.models.has(m))
        .map(shortModel)
        .join(","),
    );
  const isDefaultSources =
    state.sources.size === DEFAULT_SOURCES.length &&
    DEFAULT_SOURCES.every((s) => state.sources.has(s));
  if (isDefaultSources) q.delete("sources");
  else q.set("sources", SOURCES.filter((s) => state.sources.has(s)).join(","));
  state.billingDay === DEFAULT_BILLING_DAY
    ? q.delete("cycleDay")
    : q.set("cycleDay", String(state.billingDay));
  state.theme === systemTheme ? q.delete("theme") : q.set("theme", state.theme);
  try {
    history.replaceState(null, "", url.toString());
  } catch (_e) {}
}
