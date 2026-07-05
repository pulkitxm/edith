import { cyclesFromBounds } from "./cycles.js";
import { MONTH_NAMES, parseDate } from "./format.js";

export let RAW = {};
try {
  RAW = JSON.parse(document.getElementById("usage-data").textContent || "{}");
} catch (_e) {
  RAW = {};
}
export const DAILY = Array.isArray(RAW.daily) ? RAW.daily.slice() : [];
export const SESSIONS = Array.isArray(RAW.sessions) ? RAW.sessions : [];

const LEGACY_LABEL = { cli: "Code", cowork: "Cowork" };
const SRC_META = RAW.sourceMeta || {};
DAILY.forEach((d) => {
  if (!d.bySource) d.bySource = { cli: d.modelBreakdowns || [] };
});
export let SOURCES = (
  Array.isArray(RAW.sources) && RAW.sources.length ? RAW.sources : ["cli"]
).filter((s) => DAILY.some((d) => (d.bySource[s] || []).length));
if (!SOURCES.length) SOURCES = ["cli"];
export const SOURCE_LABEL = {};
export const SOURCE_TOOL = {};
SOURCES.forEach((s) => {
  SOURCE_LABEL[s] = (SRC_META[s] && SRC_META[s].label) || LEGACY_LABEL[s] || s;
  SOURCE_TOOL[s] = (SRC_META[s] && SRC_META[s].tool) || SOURCE_LABEL[s];
});
export const sourceLabel = (s) => SOURCE_LABEL[s] || s;
const _def =
  Array.isArray(RAW.defaultSources) && RAW.defaultSources.length
    ? RAW.defaultSources.filter((s) => SOURCES.includes(s))
    : [];
export const DEFAULT_SOURCES = _def.length ? _def : SOURCES.slice();

export const modelTotals = {};
for (const d of DAILY)
  for (const s of SOURCES)
    for (const b of d.bySource[s] || []) {
      modelTotals[b.modelName] =
        (modelTotals[b.modelName] || 0) + (+b.cost || 0);
    }
export const ALL_MODELS = Object.keys(modelTotals).sort(
  (a, b) => modelTotals[b] - modelTotals[a],
);

const _defModels = new Set();
for (const d of DAILY)
  for (const s of DEFAULT_SOURCES)
    for (const b of d.bySource[s] || []) _defModels.add(b.modelName);
export const DEFAULT_MODELS = _defModels.size
  ? ALL_MODELS.filter((m) => _defModels.has(m))
  : ALL_MODELS.slice();

const _sortedDays = DAILY.slice().sort((a, b) =>
  a.period < b.period ? -1 : 1,
);
export const EARLIEST = _sortedDays.length
  ? parseDate(_sortedDays[0].period)
  : null;
export const LATEST = _sortedDays.length
  ? parseDate(_sortedDays[_sortedDays.length - 1].period)
  : null;
export const ALL_SPAN_DAYS =
  EARLIEST && LATEST ? Math.round((LATEST - EARLIEST) / 86400000) + 1 : 0;
export function monthsInData() {
  const set = new Set();
  DAILY.forEach((d) => set.add(d.period.slice(0, 7)));
  return [...set]
    .sort()
    .reverse()
    .map((ym) => {
      const [y, m] = ym.split("-").map(Number);
      return { ym, label: `${MONTH_NAMES[m - 1]} ${y}` };
    });
}

export function cyclesInData(day) {
  if (!EARLIEST || !LATEST) return [];
  return cyclesFromBounds(EARLIEST, LATEST, day);
}
