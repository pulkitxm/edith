import { readThemeColors } from "./charts.js";
import {
  applyTheme,
  buildChips,
  buildCycleSelect,
  buildMonthSelect,
  buildSourceChips,
  syncRangeControls,
  wireControls,
} from "./controls.js";
import { cycleStart } from "./cycles.js";
import { DAILY, LATEST } from "./data.js";
import { ymd } from "./format.js";
import { initLimitsCard } from "./limitsChart.js";
import { setPalette } from "./palette.js";
import { readParams } from "./params.js";
import {
  latestDayWithHours,
  renderAll,
  renderHourly,
  renderHourlyAll,
  renderMeta,
} from "./render.js";
import { wireShareButtons } from "./share.js";
import { state } from "./state.js";

const HAS_DATA = DAILY.length > 0;
if (!HAS_DATA) {
  document.getElementById("empty").style.display = "block";
  const m = document.getElementById("meta-row");
  if (m) m.textContent = "Awaiting first snapshot.";
} else {
  document.getElementById("dash").classList.remove("hidden");
}

if (HAS_DATA) {
  wireControls();
  readParams();
  applyTheme(state.theme);
  setPalette(state.theme);
  readThemeColors();
  buildMonthSelect();
  buildCycleSelect();
  let _hasRangeParam = false;
  try {
    _hasRangeParam = new URLSearchParams(location.search).has("range");
  } catch (_e) {}
  if (!_hasRangeParam && state.range.mode === "all" && LATEST) {
    state.range = {
      mode: "cycle",
      cycle: ymd(cycleStart(LATEST, state.billingDay)),
    };
  }
  syncRangeControls();
  renderMeta();
  buildSourceChips();
  buildChips();
  renderAll();
  wireShareButtons();
  (function initHourly() {
    const inp = document.getElementById("hourly-date");
    const def = latestDayWithHours();
    if (inp) {
      inp.value = def;
      inp.min = DAILY[0] ? DAILY[0].period : def;
      inp.max = ymd(LATEST);
    }
    renderHourly(def);
  })();
  renderHourlyAll();
}

initLimitsCard();
