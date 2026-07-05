import { cycleStart } from "./cycles.js";
import {
  ALL_MODELS,
  cyclesInData,
  DEFAULT_MODELS,
  DEFAULT_SOURCES,
  LATEST,
  monthsInData,
  SOURCES,
  sourceLabel,
} from "./data.js";
import { shortModel, ymd } from "./format.js";
import {
  MODEL_COLOR,
  OTHER_COLOR,
  setPalette,
  sourceColor,
} from "./palette.js";
import { writeParams } from "./params.js";
import {
  liveRetheme,
  openHourly,
  renderAll,
  renderHourly,
  renderProjectsTable,
  renderTable,
  setHeatMetric,
  toggleProjList,
} from "./render.js";
import { DEFAULT_BILLING_DAY, state } from "./state.js";
import { toast } from "./toast.js";

function copyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(
      () => toast("Copied chat id"),
      () => toast("Copy failed"),
    );
    return;
  }
  try {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    ta.remove();
    toast("Copied chat id");
  } catch (_e) {
    toast("Copy failed");
  }
}

function sourceSummaryText() {
  const n = state.sources.size;
  if (n === SOURCES.length) return "All sources";
  if (n === 1) return sourceLabel([...state.sources][0]);
  return `${n} sources`;
}
function updateSourceSummary() {
  const el = document.getElementById("source-summary");
  if (el) el.textContent = sourceSummaryText();
}
export function buildSourceChips() {
  if (SOURCES.length < 2) return;
  document.getElementById("source-group").style.display = "";
  document.getElementById("card-source").style.display = "";
  const menu = document.getElementById("source-menu");
  menu.innerHTML = SOURCES.map(
    (s) =>
      `<label class="dd-row" data-source="${s}">
         <input type="checkbox" ${state.sources.has(s) ? "checked" : ""}>
         <span class="swatch" style="background:${sourceColor(s)}"></span>
         <span class="dd-name">${sourceLabel(s)}</span>
       </label>`,
  ).join("");
  menu.querySelectorAll(".dd-row input").forEach((inp) =>
    inp.addEventListener("change", () => {
      const s = inp.closest(".dd-row").dataset.source;
      if (inp.checked) state.sources.add(s);
      else if (state.sources.size === 1) {
        inp.checked = true;
        return;
      } else state.sources.delete(s);
      updateSourceSummary();
      renderAll();
      writeParams();
    }),
  );
  updateSourceSummary();
}

export function buildChips() {
  const box = document.getElementById("model-chips");
  box.innerHTML = ALL_MODELS.map(
    (m) =>
      `<button class="chip" data-model="${m}" aria-pressed="${state.models.has(m) ? "true" : "false"}">
         <span class="swatch" style="background:${MODEL_COLOR[m]}"></span>${shortModel(m)}
       </button>`,
  ).join("");
  box.querySelectorAll(".chip").forEach((c) =>
    c.addEventListener("click", () => {
      const m = c.dataset.model;
      if (state.models.has(m)) {
        if (state.models.size === 1) return;
        state.models.delete(m);
        c.setAttribute("aria-pressed", "false");
      } else {
        state.models.add(m);
        c.setAttribute("aria-pressed", "true");
      }
      renderAll();
      writeParams();
    }),
  );
}

function skinChips() {
  document.querySelectorAll("#model-chips .chip").forEach((c) => {
    const sw = c.querySelector(".swatch");
    if (sw) sw.style.background = MODEL_COLOR[c.dataset.model] || OTHER_COLOR;
  });
  document.querySelectorAll("#source-menu .dd-row").forEach((r) => {
    const sw = r.querySelector(".swatch");
    if (sw) sw.style.background = sourceColor(r.dataset.source);
  });
}

function setSeg(container, attr, val) {
  document
    .querySelectorAll(`#${container} button`)
    .forEach((b) =>
      b.setAttribute(
        "aria-pressed",
        b.dataset[attr] === val ? "true" : "false",
      ),
    );
}
export function buildMonthSelect() {
  const sel = document.getElementById("month-select");
  sel.innerHTML =
    `<option value="">- pick month -</option>` +
    monthsInData()
      .map((m) => `<option value="${m.ym}">${m.label}</option>`)
      .join("");
}
export function buildCycleSelect() {
  const sel = document.getElementById("cycle-select");
  sel.innerHTML =
    `<option value="">- pick cycle -</option>` +
    cyclesInData(state.billingDay)
      .map((c) => `<option value="${c.start}">${c.label}</option>`)
      .join("");
}
export function syncRangeControls() {
  const r = state.range;
  const isCurrentCycle =
    r.mode === "cycle" &&
    LATEST &&
    r.cycle === ymd(cycleStart(LATEST, state.billingDay));
  const segVal = ["today", "yesterday", "thisWeek", "lastWeek", "all"].includes(
    r.mode,
  )
    ? r.mode
    : isCurrentCycle
      ? "cycle"
      : "__none__";
  setSeg("seg-range", "range", segVal);
  document.getElementById("month-select").value =
    r.mode === "month" ? r.month : "";
  document.getElementById("date-from").value =
    r.mode === "custom" ? r.from : "";
  document.getElementById("date-to").value = r.mode === "custom" ? r.to : "";
  document.getElementById("cycle-select").value =
    r.mode === "cycle" && !isCurrentCycle ? r.cycle : "";
  document.getElementById("billing-day").value = String(state.billingDay);
}

export function applyTheme(t) {
  document.documentElement.setAttribute("data-theme", t);
  document.documentElement.style.colorScheme = t;
  document.getElementById("theme-toggle").textContent =
    t === "dark" ? "☀" : "☾";
}
function switchTheme(t) {
  state.theme = t;
  applyTheme(t);
  setPalette(t);
  liveRetheme();
  skinChips();
}

export function wireControls() {
  document.addEventListener("click", (e) => {
    const dd = document.getElementById("source-dd");
    if (dd && dd.open && !dd.contains(e.target)) dd.open = false;
  });
  document.getElementById("seg-range").addEventListener("click", (e) => {
    const b = e.target.closest("button");
    if (!b) return;
    const m = b.dataset.range;
    state.range =
      m === "cycle" && LATEST
        ? { mode: "cycle", cycle: ymd(cycleStart(LATEST, state.billingDay)) }
        : { mode: m };
    syncRangeControls();
    renderAll();
    writeParams();
  });
  document.getElementById("month-select").addEventListener("change", (e) => {
    const v = e.target.value;
    state.range = v ? { mode: "month", month: v } : { mode: "all" };
    syncRangeControls();
    renderAll();
    writeParams();
  });
  document.getElementById("cycle-select").addEventListener("change", (e) => {
    const v = e.target.value;
    state.range = v ? { mode: "cycle", cycle: v } : { mode: "all" };
    syncRangeControls();
    renderAll();
    writeParams();
  });
  document.getElementById("billing-day").addEventListener("change", (e) => {
    let n = parseInt(e.target.value, 10);
    if (!Number.isFinite(n)) n = DEFAULT_BILLING_DAY;
    n = Math.min(31, Math.max(1, n));
    state.billingDay = n;
    e.target.value = String(n);
    if (state.range.mode === "cycle") state.range = { mode: "all" };
    buildCycleSelect();
    syncRangeControls();
    renderAll();
    writeParams();
  });
  const onCustomDate = () => {
    const from = document.getElementById("date-from").value;
    const to = document.getElementById("date-to").value;
    if (from && to) {
      state.range = { mode: "custom", from, to };
      syncRangeControls();
      renderAll();
      writeParams();
    }
  };
  document.getElementById("date-from").addEventListener("change", onCustomDate);
  document.getElementById("date-to").addEventListener("change", onCustomDate);
  document.querySelectorAll("#tbl-models thead th").forEach((th) =>
    th.addEventListener("click", () => {
      const k = th.dataset.key;
      if (state.sort.key === k) state.sort.dir *= -1;
      else state.sort = { key: k, dir: k === "name" ? 1 : -1 };
      renderTable();
    }),
  );
  document.querySelectorAll("#tbl-projects thead th").forEach((th) =>
    th.addEventListener("click", () => {
      const k = th.dataset.key;
      if (state.projSort.key === k) state.projSort.dir *= -1;
      else state.projSort = { key: k, dir: k === "name" ? 1 : -1 };
      renderProjectsTable();
    }),
  );
  document
    .querySelector("#tbl-projects tbody")
    .addEventListener("click", (e) => {
      const ic = e.target.closest(".ticon.copyable[data-chat-id]");
      if (ic && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        copyText(ic.getAttribute("data-chat-id"));
        return;
      }
      const tr = e.target.closest("tr[data-expand]");
      if (!tr) return;
      const k = tr.getAttribute("data-expand");
      if (state.projExpanded.has(k)) state.projExpanded.delete(k);
      else state.projExpanded.add(k);
      renderProjectsTable();
    });
  document.getElementById("hourly-date").addEventListener("change", (e) => {
    if (e.target.value) renderHourly(e.target.value);
  });
  document.getElementById("heat").addEventListener("click", (e) => {
    const cell = e.target.closest(".cell");
    if (cell && cell.dataset.date && !cell.dataset.empty)
      openHourly(cell.dataset.date);
  });
  document.getElementById("heat-metric").addEventListener("change", (e) => {
    setHeatMetric(e.target.value);
  });
  document.getElementById("proj-toggle").addEventListener("click", () => {
    state.projListOpen = !state.projListOpen;
    toggleProjList();
  });
  document.getElementById("theme-toggle").addEventListener("click", () => {
    switchTheme(state.theme === "dark" ? "light" : "dark");
    writeParams();
  });

  document.getElementById("btn-reset").addEventListener("click", () => {
    state.range = LATEST
      ? { mode: "cycle", cycle: ymd(cycleStart(LATEST, state.billingDay)) }
      : { mode: "all" };
    state.models = new Set(DEFAULT_MODELS);
    state.sources = new Set(DEFAULT_SOURCES);
    state.sort = { key: "cost", dir: -1 };
    state.projSort = { key: "cost", dir: -1 };
    state.projExpanded.clear();
    state.projListOpen = false;
    syncRangeControls();
    buildSourceChips();
    buildChips();
    renderAll();
    writeParams();
  });
}
