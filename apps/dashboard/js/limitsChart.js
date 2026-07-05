import { resetMarkers, sliceRange } from "../limits.mjs";
import { baseTooltip, GRIDC, mount } from "./charts.js";

const WARN = 60,
  CRIT = 85;
const SESSION_C = "#d97757",
  WEEKLY_C = "#c89b3c";
const RANGES = { "24h": 864e5, "7d": 7 * 864e5, "30d": 30 * 864e5, all: null };
let range = "24h";
let LP = [];

const markerPlugin = {
  id: "limitResets",
  afterDatasetsDraw(chart, _args, opts) {
    const marks = (opts && opts.markers) || [];
    const { ctx, chartArea, scales } = chart;
    ctx.save();
    ctx.setLineDash([2, 3]);
    ctx.lineWidth = 1;
    for (const m of marks) {
      const x = scales.x.getPixelForValue(m.t);
      if (x < chartArea.left || x > chartArea.right) continue;
      ctx.strokeStyle =
        m.kind === "session" ? "rgba(217,119,87,.30)" : "rgba(200,155,60,.55)";
      ctx.beginPath();
      ctx.moveTo(x, chartArea.top);
      ctx.lineTo(x, chartArea.bottom);
      ctx.stroke();
    }
    ctx.restore();
  },
};

const thresholdPlugin = {
  id: "limitThresholds",
  afterDatasetsDraw(chart) {
    const { ctx, chartArea, scales } = chart;
    ctx.save();
    ctx.setLineDash([4, 4]);
    ctx.lineWidth = 1;
    for (const [v, color] of [
      [WARN, "rgba(230,140,60,.5)"],
      [CRIT, "rgba(200,60,50,.5)"],
    ]) {
      const y = scales.y.getPixelForValue(v);
      ctx.strokeStyle = color;
      ctx.beginPath();
      ctx.moveTo(chartArea.left, y);
      ctx.lineTo(chartArea.right, y);
      ctx.stroke();
    }
    ctx.restore();
  },
};

export function initLimitsCard() {
  const card = document.getElementById("limits-card");
  if (!card) return;
  try {
    LP =
      JSON.parse(document.getElementById("limits-data")?.textContent || "{}")
        .points || [];
  } catch (_e) {
    LP = [];
  }
  if (!LP.length) {
    card.style.display = "none";
    return;
  }
  document.querySelectorAll("#seg-limits button").forEach((b) =>
    b.addEventListener("click", () => {
      range = b.dataset.lr;
      syncPills();
      renderLimits();
    }),
  );
  syncPills();
  renderLimits();
}

function syncPills() {
  document
    .querySelectorAll("#seg-limits button")
    .forEach((b) =>
      b.setAttribute("aria-pressed", String(b.dataset.lr === range)),
    );
}

function fmtTick(v) {
  const d = new Date(v);
  if (range === "24h") return `${String(d.getHours()).padStart(2, "0")}:00`;
  return `${d.getMonth() + 1}/${d.getDate()}`;
}

function renderLimits() {
  const now = LP[LP.length - 1].t;
  const pts = sliceRange(LP, now, RANGES[range]);
  if (!pts.length) return;
  const marks = resetMarkers(pts).filter(
    (m) => m.kind === "weekly" || (RANGES[range] ?? Infinity) <= 7 * 864e5,
  );
  const ds = (key, label, color) => ({
    label,
    data: pts.filter((p) => p[key] != null).map((p) => ({ x: p.t, y: p[key] })),
    borderColor: color,
    backgroundColor: color,
    stepped: true,
    pointRadius: 0,
    borderWidth: 1.5,
  });
  mount("c-limits", {
    type: "line",
    data: {
      datasets: [
        ds("s", "Session (5h)", SESSION_C),
        ds("w", "Weekly", WEEKLY_C),
      ],
    },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      scales: {
        x: {
          type: "linear",
          min: pts[0].t,
          max: now,
          grid: { display: false },
          ticks: { maxTicksLimit: 10, callback: fmtTick },
        },
        y: {
          min: 0,
          max: 100,
          grid: { color: GRIDC },
          ticks: { callback: (v) => v + "%" },
        },
      },
      plugins: {
        legend: { display: true, labels: { boxWidth: 8, boxHeight: 8 } },
        tooltip: {
          ...baseTooltip,
          callbacks: {
            title: (items) => new Date(items[0].parsed.x).toLocaleString(),
            label: (item) =>
              ` ${item.dataset.label}: ${item.parsed.y.toFixed(1)}%`,
          },
        },
        limitResets: { markers: marks },
      },
    },
    plugins: [markerPlugin, thresholdPlugin],
  });
}
